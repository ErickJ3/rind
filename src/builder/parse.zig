//! Containerfile parser.
//!
//! Consumes the token stream produced by `builder/lex.zig` and emits a
//! typed `Instruction` AST plus a side-channel `Diagnostic` list. The
//! parser is a pure library: no IO, no globals, output owned by the
//! arena allocator passed in by the caller.
//!
//! Scope decisions baked in here:
//!   * `FROM` first-arg is parsed through `image/ref.zig` when it looks
//!     like a registry reference and does not match a previously-
//!     declared stage alias. Refs that contain unresolved variable
//!     expansion (`${VAR}`, `$VAR`) are kept verbatim with `image =
//!     null`; the build state machine resolves them at execution time
//!     when the env stack is live.
//!   * Shell vs exec form for `RUN`/`CMD`/`ENTRYPOINT` is decided by the
//!     lexer's token kind (`.string` vs `.json_array`).
//!   * `ENV` and `LABEL` accept both legacy `K V V V` and the modern
//!     `K=V K2=V2` form. Distinguished by `=` presence in the first
//!     payload string.
//!   * Heredoc bodies that follow a `RUN <<TAG` declarator are paired
//!     in declaration order; the lexer guarantees the body tokens
//!     appear after the line's string tokens but before the trailing
//!     `.newline`.
//!   * Pre-FROM `ARG` instructions are flagged `is_global = true`; they
//!     are still appended to the instruction list in source order so
//!     downstream cache-key derivation sees them.
//!   * `ONBUILD` payloads are kept opaque (raw string tokens plus the
//!     recovered inner directive tag). Sub-parsing the deferred
//!     instruction is a child-build concern, not a parent-build one.
//!
//! Errors are split between fatal (`ParseError` returned from `parse`)
//! and non-fatal (`Diagnostic` accumulated in `ParseResult.diagnostics`).
//! Anything that prevents producing a valid AST node is fatal; deprecation
//! warnings and unresolvable-but-syntactically-fine constructs are diags.

const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const lex = @import("lex.zig");
const image_ref = @import("../image/ref.zig");

/// Failure modes surfaced as a closed error set so callers can dispatch
/// on the cause. Lexer failures are merged in so a single try in the
/// caller handles both phases.
pub const ParseError = error{
    /// Reached end of token stream while expecting more payload.
    UnexpectedEof,
    /// Directive token recovered with no matching tag (defensive; the
    /// lexer would normally have returned `LexError.BadDirective`
    /// first).
    UnknownDirective,
    /// JSON-array exec-form payload was syntactically invalid.
    BadJsonArray,
    /// `FROM` first-arg failed to parse as an image reference and did
    /// not contain a deferred-expansion marker (`$`).
    BadFromRef,
    /// Instruction required at least one payload token but the lexer
    /// produced none.
    EmptyArgs,
    /// `FROM ... AS x` declared an alias that an earlier stage already
    /// claimed.
    DuplicateStageAlias,
    /// `SHELL` directive was given as shell form; the OCI image config
    /// requires an exec-form (JSON array) value.
    ShellNotExec,
    /// `ONBUILD ONBUILD ...` is forbidden by BuildKit. Recovered when
    /// the inner directive token reads as `ONBUILD`.
    NestedOnBuild,
    /// HEALTHCHECK expected `NONE` or `CMD` keyword and got something
    /// else.
    BadHealthcheck,
} || lex.LexError || Allocator.Error;

/// Severity of a `Diagnostic`. Parse never aborts on warn-level issues.
pub const Severity = enum { warn, info };

/// One non-fatal observation made during parse. `message` is either a
/// static string or arena-owned; either way the caller releases the
/// arena to free.
pub const Diagnostic = struct {
    severity: Severity,
    span: lex.Span,
    message: []const u8,
};

/// Single key/value entry shared by `ENV` and `LABEL`.
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// `RUN <<TAG` body captured at lex time, paired with its declarator at
/// parse time. `tag` is the literal delimiter text (stripped of quotes
/// and leading `-`), `body` is the raw body bytes. `strip_tabs` is true
/// when the declarator was written `<<-TAG`.
pub const Heredoc = struct {
    tag: []const u8,
    body: []const u8,
    strip_tabs: bool,
};

/// `RUN`/`CMD`/`ENTRYPOINT` payload. Heredoc args appear in `heredocs`
/// in declaration order; the regular `args` slice still contains the
/// declarator strings (e.g. `<<EOF`) so consumers that only look at
/// `args` get the original surface form.
pub const Run = struct {
    span: lex.Span,
    form: Form,
    args: []const []const u8,
    heredocs: []const Heredoc,

    pub const Form = enum { shell, exec };
};

/// `FROM <ref> [AS <alias>] [--platform=<plat>]` instruction.
pub const From = struct {
    span: lex.Span,
    /// Original first-arg text (e.g. `"alpine:3.19"`, `"${BASE}"`,
    /// `"scratch"`, or a stage alias).
    raw: []const u8,
    /// Populated when `raw` parses as a registry reference and is not
    /// a known stage alias. Owned by the arena.
    image: ?image_ref.ImageRef,
    /// Populated when `raw` matches an alias declared by an earlier
    /// `FROM ... AS x`. Slice points into the arena.
    stage_ref: ?[]const u8,
    /// True when `raw` was the literal `scratch` keyword.
    is_scratch: bool,
    /// Stage alias declared by `AS <name>`, if any.
    alias: ?[]const u8,
    /// `--platform=<value>` payload, verbatim.
    platform: ?[]const u8,
};

/// Shared payload for `COPY` and `ADD`. `is_add` distinguishes the two.
pub const Copy = struct {
    span: lex.Span,
    sources: []const []const u8,
    dest: []const u8,
    /// `--from=<stage|image>`; resolution to stage vs image is the
    /// build state machine's job, not the parser's.
    from: ?[]const u8,
    /// `--chown=<user[:group]>`.
    chown: ?[]const u8,
    /// `--chmod=<octal>`.
    chmod: ?[]const u8,
    is_add: bool,
};

/// `ARG <name>[=<default>]`. `is_global` is true when the directive
/// appears before the first `FROM` in the file.
pub const Arg = struct {
    span: lex.Span,
    name: []const u8,
    default: ?[]const u8,
    is_global: bool,
};

/// `HEALTHCHECK NONE` clears the field; `HEALTHCHECK CMD ...` populates
/// the `cmd` variant. The optional flag values are kept verbatim
/// (e.g. `"30s"`, `"3"`); duration parsing is the runtime's job.
pub const Healthcheck = union(enum) {
    none,
    cmd: Cmd,

    pub const Cmd = struct {
        form: Run.Form,
        args: []const []const u8,
        interval: ?[]const u8,
        timeout: ?[]const u8,
        start_period: ?[]const u8,
        retries: ?[]const u8,
    };
};

/// Deferred trigger payload. Stored opaquely: the inner directive's
/// canonical tag plus the raw payload tokens. The build state machine
/// re-parses these when the parent image is later consumed by a child
/// build.
pub const OnBuild = struct {
    span: lex.Span,
    inner_directive: lex.Directive,
    raw_args: []const []const u8,
};

/// Tagged union with one variant per directive. Tag is the lexer's
/// `Directive` enum so the same tag space drives both layers.
pub const Instruction = union(lex.Directive) {
    from: From,
    run: Run,
    copy: Copy,
    add: Copy,
    env: Entries,
    workdir: Single,
    user: Single,
    cmd: Run,
    entrypoint: Run,
    expose: ManyStrings,
    label: Entries,
    arg: Arg,
    stopsignal: Single,
    healthcheck: HealthcheckPayload,
    shell: ManyStrings,
    volume: ManyStrings,
    maintainer: Single,
    onbuild: OnBuild,

    pub const Single = struct { span: lex.Span, value: []const u8 };
    pub const ManyStrings = struct { span: lex.Span, values: []const []const u8 };
    pub const Entries = struct { span: lex.Span, entries: []const KeyValue };
    pub const HealthcheckPayload = struct { span: lex.Span, value: Healthcheck };
};

/// Caller-owned bundle returned by `parse`. Memory lifetime is tied to
/// the arena allocator the caller passed in.
pub const ParseResult = struct {
    header: lex.Header,
    instructions: []const Instruction,
    diagnostics: []const Diagnostic,
};

/// Parse `src` into an `Instruction` AST. `arena` MUST be a
/// `std.heap.ArenaAllocator.allocator()`; the parser allocates AST
/// payloads, child slices, and intermediate scratch from it without
/// per-node deinit. The returned `ParseResult`'s slices alias into both
/// `src` and arena-allocated buffers.
pub fn parse(arena: Allocator, src: []const u8) ParseError!ParseResult {
    const lex_result = try lex.tokenize(arena, src);
    // Tokens themselves were allocated from `arena`; arena reset frees them.
    // We deliberately do not `lex_result.deinit(arena)` because that would
    // hand the slice back to the gpa free list, which a fixed-buffer arena
    // ignores anyway and which a real arena handles in bulk.

    var p: Parser = .{
        .arena = arena,
        .src = src,
        .tokens = lex_result.tokens,
        .index = 0,
        .seen_from = false,
        .stage_aliases = .empty,
        .instructions = .empty,
        .diagnostics = .empty,
    };

    while (true) {
        const tok = p.peek() orelse return ParseError.UnexpectedEof;
        if (tok.kind == .eof) break;
        if (tok.kind == .newline) {
            p.index += 1;
            continue;
        }
        if (tok.kind != .directive) return ParseError.UnknownDirective;
        try p.parseInstruction();
    }

    return .{
        .header = lex_result.header,
        .instructions = try p.instructions.toOwnedSlice(arena),
        .diagnostics = try p.diagnostics.toOwnedSlice(arena),
    };
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    tokens: []const lex.Token,
    index: usize,
    seen_from: bool,
    stage_aliases: std.StringHashMapUnmanaged(void),
    instructions: std.ArrayList(Instruction),
    diagnostics: std.ArrayList(Diagnostic),

    fn peek(self: *const Parser) ?lex.Token {
        if (self.index >= self.tokens.len) return null;
        return self.tokens[self.index];
    }

    fn peekAt(self: *const Parser, off: usize) ?lex.Token {
        if (self.index + off >= self.tokens.len) return null;
        return self.tokens[self.index + off];
    }

    fn advance(self: *Parser) ?lex.Token {
        if (self.index >= self.tokens.len) return null;
        const t = self.tokens[self.index];
        self.index += 1;
        return t;
    }

    /// Consume the trailing `.newline` (or `.eof`) for the current
    /// instruction, plus any `.deprecated_warn` token that the lexer
    /// stamped in the same span.
    fn finishInstruction(self: *Parser) void {
        while (self.peek()) |t| {
            switch (t.kind) {
                .deprecated_warn => self.index += 1,
                .newline => {
                    self.index += 1;
                    return;
                },
                .eof => return,
                else => return,
            }
        }
    }

    /// Pull every payload string token on the current logical line into
    /// a slice. Heredoc bodies and warnings are skipped here because
    /// every directive that consumes them does so before calling this.
    fn collectStrings(self: *Parser) ParseError![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        while (self.peek()) |t| {
            switch (t.kind) {
                .string => {
                    try out.append(self.arena, t.text);
                    self.index += 1;
                },
                .deprecated_warn => self.index += 1,
                .heredoc_body, .newline, .eof => break,
                else => break,
            }
        }
        return try out.toOwnedSlice(self.arena);
    }

    /// Collect heredoc body tokens that immediately follow the string
    /// tokens of the current instruction. Pairing with declarators is
    /// done by the caller using the `<<TAG` strings already parsed.
    fn collectHeredocBodies(self: *Parser) ParseError![]const lex.Token {
        var out: std.ArrayList(lex.Token) = .empty;
        while (self.peek()) |t| {
            if (t.kind != .heredoc_body) break;
            try out.append(self.arena, t);
            self.index += 1;
        }
        return try out.toOwnedSlice(self.arena);
    }

    fn parseInstruction(self: *Parser) ParseError!void {
        const dir_tok = self.advance().?;
        std.debug.assert(dir_tok.kind == .directive);
        const tag = dir_tok.directive_tag orelse return ParseError.UnknownDirective;

        switch (tag) {
            .from => try self.parseFrom(dir_tok),
            .run => try self.parseRunLike(dir_tok, .run),
            .cmd => try self.parseRunLike(dir_tok, .cmd),
            .entrypoint => try self.parseRunLike(dir_tok, .entrypoint),
            .copy => try self.parseCopyLike(dir_tok, false),
            .add => try self.parseCopyLike(dir_tok, true),
            .env => try self.parseEntries(dir_tok, .env),
            .label => try self.parseEntries(dir_tok, .label),
            .workdir => try self.parseSingle(dir_tok, .workdir),
            .user => try self.parseSingle(dir_tok, .user),
            .stopsignal => try self.parseSingle(dir_tok, .stopsignal),
            .maintainer => try self.parseMaintainer(dir_tok),
            .expose => try self.parseManyStrings(dir_tok, .expose),
            .volume => try self.parseManyStrings(dir_tok, .volume),
            .shell => try self.parseShell(dir_tok),
            .arg => try self.parseArg(dir_tok),
            .healthcheck => try self.parseHealthcheck(dir_tok),
            .onbuild => try self.parseOnBuild(dir_tok),
        }
    }

    fn parseFrom(self: *Parser, dir_tok: lex.Token) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();

        if (strings.len == 0) return ParseError.EmptyArgs;

        var platform: ?[]const u8 = null;
        var rest: std.ArrayList([]const u8) = .empty;
        for (strings) |s| {
            if (parseFlagValue(s, "--platform=")) |v| {
                platform = v;
            } else {
                try rest.append(self.arena, s);
            }
        }
        const positional = try rest.toOwnedSlice(self.arena);
        if (positional.len == 0) return ParseError.EmptyArgs;

        const ref_text = positional[0];
        var alias: ?[]const u8 = null;
        if (positional.len >= 3) {
            if (ascii.eqlIgnoreCase(positional[1], "AS")) {
                alias = positional[2];
            }
        } else if (positional.len == 2) {
            // `FROM x AS` with no alias body is a user error; `FROM x y`
            // with `y` not equal to `AS` is also invalid. Both paths
            // surface as EmptyArgs (we reject silently rather than
            // overspecifying error names for v1).
            return ParseError.EmptyArgs;
        }

        var is_scratch = false;
        var stage_ref: ?[]const u8 = null;
        var img: ?image_ref.ImageRef = null;

        if (std.mem.eql(u8, ref_text, "scratch")) {
            is_scratch = true;
        } else if (self.stage_aliases.contains(ref_text)) {
            stage_ref = ref_text;
        } else if (containsExpansionMarker(ref_text)) {
            // Leave image=null; build state machine resolves at exec time.
        } else {
            img = image_ref.parse(self.arena, ref_text) catch return ParseError.BadFromRef;
        }

        if (alias) |a| {
            const gop = try self.stage_aliases.getOrPut(self.arena, a);
            if (gop.found_existing) return ParseError.DuplicateStageAlias;
        }

        try self.instructions.append(self.arena, .{ .from = .{
            .span = dir_tok.span,
            .raw = ref_text,
            .image = img,
            .stage_ref = stage_ref,
            .is_scratch = is_scratch,
            .alias = alias,
            .platform = platform,
        } });
        self.seen_from = true;
    }

    fn parseRunLike(self: *Parser, dir_tok: lex.Token, comptime which: lex.Directive) ParseError!void {
        const first = self.peek();
        if (first) |t| if (t.kind == .json_array) {
            self.index += 1;
            self.finishInstruction();
            const args = try parseJsonStringArray(self.arena, t.text);
            const run: Run = .{
                .span = dir_tok.span,
                .form = .exec,
                .args = args,
                .heredocs = &.{},
            };
            try self.appendRunLike(which, run);
            return;
        };

        const args = try self.collectStrings();
        const heredoc_bodies = try self.collectHeredocBodies();
        self.finishInstruction();

        const heredocs = try self.pairHeredocs(args, heredoc_bodies);
        const run: Run = .{
            .span = dir_tok.span,
            .form = .shell,
            .args = args,
            .heredocs = heredocs,
        };
        try self.appendRunLike(which, run);
    }

    fn appendRunLike(self: *Parser, comptime which: lex.Directive, run: Run) ParseError!void {
        switch (which) {
            .run => try self.instructions.append(self.arena, .{ .run = run }),
            .cmd => try self.instructions.append(self.arena, .{ .cmd = run }),
            .entrypoint => try self.instructions.append(self.arena, .{ .entrypoint = run }),
            else => unreachable,
        }
    }

    fn pairHeredocs(self: *Parser, args: []const []const u8, bodies: []const lex.Token) ParseError![]const Heredoc {
        var out: std.ArrayList(Heredoc) = .empty;
        var body_i: usize = 0;
        for (args) |s| {
            const declarator = parseHeredocDeclarator(s) orelse continue;
            if (body_i >= bodies.len) return ParseError.UnexpectedEof;
            try out.append(self.arena, .{
                .tag = declarator.tag,
                .body = bodies[body_i].text,
                .strip_tabs = declarator.strip_tabs,
            });
            body_i += 1;
        }
        return try out.toOwnedSlice(self.arena);
    }

    fn parseCopyLike(self: *Parser, dir_tok: lex.Token, is_add: bool) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();

        var from: ?[]const u8 = null;
        var chown: ?[]const u8 = null;
        var chmod: ?[]const u8 = null;
        var positional: std.ArrayList([]const u8) = .empty;
        for (strings) |s| {
            if (parseFlagValue(s, "--from=")) |v| {
                from = v;
            } else if (parseFlagValue(s, "--chown=")) |v| {
                chown = v;
            } else if (parseFlagValue(s, "--chmod=")) |v| {
                chmod = v;
            } else {
                try positional.append(self.arena, s);
            }
        }
        const pos = try positional.toOwnedSlice(self.arena);
        if (pos.len < 2) return ParseError.EmptyArgs;
        const dest = pos[pos.len - 1];
        const sources = pos[0 .. pos.len - 1];

        const payload: Copy = .{
            .span = dir_tok.span,
            .sources = sources,
            .dest = dest,
            .from = from,
            .chown = chown,
            .chmod = chmod,
            .is_add = is_add,
        };
        if (is_add) {
            try self.instructions.append(self.arena, .{ .add = payload });
        } else {
            try self.instructions.append(self.arena, .{ .copy = payload });
        }
    }

    fn parseEntries(self: *Parser, dir_tok: lex.Token, comptime which: lex.Directive) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();
        if (strings.len == 0) return ParseError.EmptyArgs;

        const entries = try splitKeyValues(self.arena, strings);
        const payload: Instruction.Entries = .{ .span = dir_tok.span, .entries = entries };
        switch (which) {
            .env => try self.instructions.append(self.arena, .{ .env = payload }),
            .label => try self.instructions.append(self.arena, .{ .label = payload }),
            else => unreachable,
        }
    }

    fn parseSingle(self: *Parser, dir_tok: lex.Token, comptime which: lex.Directive) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();
        if (strings.len == 0) return ParseError.EmptyArgs;
        const value = try joinSpaces(self.arena, strings);
        const payload: Instruction.Single = .{ .span = dir_tok.span, .value = value };
        switch (which) {
            .workdir => try self.instructions.append(self.arena, .{ .workdir = payload }),
            .user => try self.instructions.append(self.arena, .{ .user = payload }),
            .stopsignal => try self.instructions.append(self.arena, .{ .stopsignal = payload }),
            else => unreachable,
        }
    }

    fn parseMaintainer(self: *Parser, dir_tok: lex.Token) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();
        if (strings.len == 0) return ParseError.EmptyArgs;
        const value = try joinSpaces(self.arena, strings);
        try self.instructions.append(self.arena, .{ .maintainer = .{ .span = dir_tok.span, .value = value } });
        try self.diagnostics.append(self.arena, .{
            .severity = .warn,
            .span = dir_tok.span,
            .message = "MAINTAINER directive is deprecated; use LABEL maintainer=...",
        });
    }

    fn parseManyStrings(self: *Parser, dir_tok: lex.Token, comptime which: lex.Directive) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();
        if (strings.len == 0) return ParseError.EmptyArgs;
        const payload: Instruction.ManyStrings = .{ .span = dir_tok.span, .values = strings };
        switch (which) {
            .expose => try self.instructions.append(self.arena, .{ .expose = payload }),
            .volume => try self.instructions.append(self.arena, .{ .volume = payload }),
            else => unreachable,
        }
    }

    fn parseShell(self: *Parser, dir_tok: lex.Token) ParseError!void {
        const first = self.peek();
        if (first) |t| if (t.kind == .json_array) {
            self.index += 1;
            self.finishInstruction();
            const args = try parseJsonStringArray(self.arena, t.text);
            try self.instructions.append(self.arena, .{ .shell = .{
                .span = dir_tok.span,
                .values = args,
            } });
            return;
        };
        // Drain whatever the user wrote so the parser stays in sync.
        _ = try self.collectStrings();
        self.finishInstruction();
        return ParseError.ShellNotExec;
    }

    fn parseArg(self: *Parser, dir_tok: lex.Token) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();
        if (strings.len == 0) return ParseError.EmptyArgs;
        const first = strings[0];
        var name: []const u8 = first;
        var default: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, first, '=')) |eq| {
            name = first[0..eq];
            default = first[eq + 1 ..];
        }
        try self.instructions.append(self.arena, .{ .arg = .{
            .span = dir_tok.span,
            .name = name,
            .default = default,
            .is_global = !self.seen_from,
        } });
    }

    fn parseHealthcheck(self: *Parser, dir_tok: lex.Token) ParseError!void {
        const strings = try self.collectStrings();
        // HEALTHCHECK CMD ["..."] is also valid; capture json_array
        // BEFORE finishInstruction so we don't lose it.
        var json_arr: ?lex.Token = null;
        if (self.peek()) |t| if (t.kind == .json_array) {
            json_arr = t;
            self.index += 1;
        };
        self.finishInstruction();
        if (strings.len == 0) return ParseError.BadHealthcheck;

        var interval: ?[]const u8 = null;
        var timeout: ?[]const u8 = null;
        var start_period: ?[]const u8 = null;
        var retries: ?[]const u8 = null;
        var i: usize = 0;
        while (i < strings.len) : (i += 1) {
            const s = strings[i];
            if (parseFlagValue(s, "--interval=")) |v| {
                interval = v;
            } else if (parseFlagValue(s, "--timeout=")) |v| {
                timeout = v;
            } else if (parseFlagValue(s, "--start-period=")) |v| {
                start_period = v;
            } else if (parseFlagValue(s, "--retries=")) |v| {
                retries = v;
            } else {
                break;
            }
        }

        if (i >= strings.len) return ParseError.BadHealthcheck;
        const keyword = strings[i];

        if (ascii.eqlIgnoreCase(keyword, "NONE")) {
            try self.instructions.append(self.arena, .{ .healthcheck = .{
                .span = dir_tok.span,
                .value = .none,
            } });
            return;
        }

        if (!ascii.eqlIgnoreCase(keyword, "CMD")) return ParseError.BadHealthcheck;
        i += 1;

        const cmd_strings = strings[i..];

        var form: Run.Form = .shell;
        var args: []const []const u8 = cmd_strings;
        if (json_arr) |t| {
            form = .exec;
            args = try parseJsonStringArray(self.arena, t.text);
        } else if (cmd_strings.len == 0) {
            return ParseError.BadHealthcheck;
        }

        try self.instructions.append(self.arena, .{ .healthcheck = .{
            .span = dir_tok.span,
            .value = .{ .cmd = .{
                .form = form,
                .args = args,
                .interval = interval,
                .timeout = timeout,
                .start_period = start_period,
                .retries = retries,
            } },
        } });
    }

    fn parseOnBuild(self: *Parser, dir_tok: lex.Token) ParseError!void {
        const strings = try self.collectStrings();
        self.finishInstruction();
        if (strings.len == 0) return ParseError.EmptyArgs;
        const inner_text = strings[0];
        if (ascii.eqlIgnoreCase(inner_text, "ONBUILD")) return ParseError.NestedOnBuild;
        const inner_tag = matchDirective(inner_text) orelse return ParseError.UnknownDirective;
        try self.instructions.append(self.arena, .{ .onbuild = .{
            .span = dir_tok.span,
            .inner_directive = inner_tag,
            .raw_args = strings[1..],
        } });
    }
};

fn matchDirective(text: []const u8) ?lex.Directive {
    const table = [_]struct { name: []const u8, tag: lex.Directive }{
        .{ .name = "FROM", .tag = .from },
        .{ .name = "RUN", .tag = .run },
        .{ .name = "COPY", .tag = .copy },
        .{ .name = "ADD", .tag = .add },
        .{ .name = "ENV", .tag = .env },
        .{ .name = "WORKDIR", .tag = .workdir },
        .{ .name = "USER", .tag = .user },
        .{ .name = "CMD", .tag = .cmd },
        .{ .name = "ENTRYPOINT", .tag = .entrypoint },
        .{ .name = "EXPOSE", .tag = .expose },
        .{ .name = "LABEL", .tag = .label },
        .{ .name = "ARG", .tag = .arg },
        .{ .name = "STOPSIGNAL", .tag = .stopsignal },
        .{ .name = "HEALTHCHECK", .tag = .healthcheck },
        .{ .name = "SHELL", .tag = .shell },
        .{ .name = "VOLUME", .tag = .volume },
        .{ .name = "MAINTAINER", .tag = .maintainer },
        .{ .name = "ONBUILD", .tag = .onbuild },
    };
    for (table) |row| if (ascii.eqlIgnoreCase(row.name, text)) return row.tag;
    return null;
}

fn parseFlagValue(s: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (s.len < prefix.len) return null;
    if (!std.mem.eql(u8, s[0..prefix.len], prefix)) return null;
    return s[prefix.len..];
}

fn containsExpansionMarker(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '$') != null;
}

const HeredocDecl = struct { tag: []const u8, strip_tabs: bool };

fn parseHeredocDeclarator(s: []const u8) ?HeredocDecl {
    if (s.len < 3) return null;
    if (s[0] != '<' or s[1] != '<') return null;
    var i: usize = 2;
    var strip = false;
    if (i < s.len and s[i] == '-') {
        strip = true;
        i += 1;
    }
    if (i >= s.len) return null;
    if (s[i] == '"' or s[i] == '\'') {
        const q = s[i];
        i += 1;
        const start = i;
        while (i < s.len and s[i] != q) : (i += 1) {}
        if (i >= s.len) return null;
        return .{ .tag = s[start..i], .strip_tabs = strip };
    }
    return .{ .tag = s[i..], .strip_tabs = strip };
}

fn parseJsonStringArray(arena: Allocator, text: []const u8) ParseError![]const []const u8 {
    return std.json.parseFromSliceLeaky([]const []const u8, arena, text, .{}) catch return ParseError.BadJsonArray;
}

fn splitKeyValues(arena: Allocator, strings: []const []const u8) ParseError![]const KeyValue {
    if (strings.len == 0) return ParseError.EmptyArgs;
    const first_has_eq = std.mem.indexOfScalar(u8, strings[0], '=') != null;
    if (!first_has_eq) {
        // Legacy form: `K V V V` collapses to one entry whose value is
        // the rest joined with spaces.
        if (strings.len < 2) return ParseError.EmptyArgs;
        const key = strings[0];
        const value = try joinSpaces(arena, strings[1..]);
        const out = try arena.alloc(KeyValue, 1);
        out[0] = .{ .key = key, .value = unquote(value) };
        return out;
    }
    var out: std.ArrayList(KeyValue) = .empty;
    for (strings) |s| {
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse return ParseError.EmptyArgs;
        try out.append(arena, .{ .key = s[0..eq], .value = unquote(s[eq + 1 ..]) });
    }
    return try out.toOwnedSlice(arena);
}

fn joinSpaces(arena: Allocator, strings: []const []const u8) ParseError![]const u8 {
    if (strings.len == 0) return "";
    var total: usize = 0;
    for (strings) |s| total += s.len;
    total += strings.len - 1;
    const buf = try arena.alloc(u8, total);
    var i: usize = 0;
    for (strings, 0..) |s, idx| {
        if (idx != 0) {
            buf[i] = ' ';
            i += 1;
        }
        @memcpy(buf[i .. i + s.len], s);
        i += s.len;
    }
    return buf;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const a = s[0];
        const b = s[s.len - 1];
        if ((a == '"' and b == '"') or (a == '\'' and b == '\'')) return s[1 .. s.len - 1];
    }
    return s;
}

const testing = std.testing;

fn parseString(src: []const u8) !struct { arena: std.heap.ArenaAllocator, result: ParseResult } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const result = try parse(arena.allocator(), src);
    return .{ .arena = arena, .result = result };
}

test "parse: bare FROM resolves through image ref parser" {
    var got = try parseString("FROM alpine:3.19\n");
    defer got.arena.deinit();
    try testing.expectEqual(@as(usize, 1), got.result.instructions.len);
    const f = got.result.instructions[0].from;
    try testing.expect(f.image != null);
    try testing.expectEqualStrings("alpine:3.19", f.raw);
    try testing.expect(!f.is_scratch);
}

test "parse: FROM scratch flagged" {
    var got = try parseString("FROM scratch\n");
    defer got.arena.deinit();
    const f = got.result.instructions[0].from;
    try testing.expect(f.is_scratch);
    try testing.expect(f.image == null);
}

test "parse: FROM AS registers alias and second FROM resolves to it" {
    var got = try parseString(
        \\FROM alpine:3.19 AS builder
        \\FROM builder
        \\
    );
    defer got.arena.deinit();
    try testing.expectEqual(@as(usize, 2), got.result.instructions.len);
    try testing.expectEqualStrings("builder", got.result.instructions[0].from.alias.?);
    try testing.expect(got.result.instructions[1].from.stage_ref != null);
    try testing.expectEqualStrings("builder", got.result.instructions[1].from.stage_ref.?);
}

test "parse: duplicate stage alias errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parse(arena.allocator(),
        \\FROM alpine:3.19 AS x
        \\FROM debian:12 AS x
        \\
    );
    try testing.expectError(ParseError.DuplicateStageAlias, result);
}

test "parse: FROM with expansion marker keeps raw, image null" {
    var got = try parseString("FROM ${BASE}\n");
    defer got.arena.deinit();
    const f = got.result.instructions[0].from;
    try testing.expectEqualStrings("${BASE}", f.raw);
    try testing.expect(f.image == null);
    try testing.expect(!f.is_scratch);
}

test "parse: CMD exec form parses JSON array" {
    var got = try parseString("FROM scratch\nCMD [\"echo\",\"hi\"]\n");
    defer got.arena.deinit();
    const c = got.result.instructions[1].cmd;
    try testing.expectEqual(Run.Form.exec, c.form);
    try testing.expectEqual(@as(usize, 2), c.args.len);
    try testing.expectEqualStrings("echo", c.args[0]);
    try testing.expectEqualStrings("hi", c.args[1]);
}

test "parse: CMD shell form keeps tokens" {
    var got = try parseString("FROM scratch\nCMD echo hi\n");
    defer got.arena.deinit();
    const c = got.result.instructions[1].cmd;
    try testing.expectEqual(Run.Form.shell, c.form);
    try testing.expectEqual(@as(usize, 2), c.args.len);
}

test "parse: ENTRYPOINT exec and shell forms" {
    var got = try parseString("FROM scratch\nENTRYPOINT [\"/bin/sh\"]\n");
    defer got.arena.deinit();
    try testing.expectEqual(Run.Form.exec, got.result.instructions[1].entrypoint.form);

    var got2 = try parseString("FROM scratch\nENTRYPOINT bash -lc\n");
    defer got2.arena.deinit();
    try testing.expectEqual(Run.Form.shell, got2.result.instructions[1].entrypoint.form);
}

test "parse: RUN shell form" {
    var got = try parseString("FROM scratch\nRUN echo hi\n");
    defer got.arena.deinit();
    const r = got.result.instructions[1].run;
    try testing.expectEqual(Run.Form.shell, r.form);
}

test "parse: RUN heredoc captured" {
    const src =
        "FROM scratch\nRUN <<EOF\necho one\necho two\nEOF\n";
    var got = try parseString(src);
    defer got.arena.deinit();
    const r = got.result.instructions[1].run;
    try testing.expectEqual(@as(usize, 1), r.heredocs.len);
    try testing.expectEqualStrings("EOF", r.heredocs[0].tag);
    try testing.expectEqual(false, r.heredocs[0].strip_tabs);
}

test "parse: COPY --from --chown --chmod parsed" {
    var got = try parseString("FROM scratch\nCOPY --from=builder --chown=u:g --chmod=755 a b /dst\n");
    defer got.arena.deinit();
    const c = got.result.instructions[1].copy;
    try testing.expectEqualStrings("builder", c.from.?);
    try testing.expectEqualStrings("u:g", c.chown.?);
    try testing.expectEqualStrings("755", c.chmod.?);
    try testing.expectEqualStrings("/dst", c.dest);
    try testing.expectEqual(@as(usize, 2), c.sources.len);
    try testing.expectEqualStrings("a", c.sources[0]);
}

test "parse: ADD distinguished from COPY" {
    var got = try parseString("FROM scratch\nADD foo /bar\n");
    defer got.arena.deinit();
    try testing.expect(got.result.instructions[1] == .add);
    try testing.expect(got.result.instructions[1].add.is_add);
}

test "parse: ENV K=V form" {
    var got = try parseString("FROM scratch\nENV K=V K2=V2\n");
    defer got.arena.deinit();
    const e = got.result.instructions[1].env;
    try testing.expectEqual(@as(usize, 2), e.entries.len);
    try testing.expectEqualStrings("K", e.entries[0].key);
    try testing.expectEqualStrings("V", e.entries[0].value);
    try testing.expectEqualStrings("V2", e.entries[1].value);
}

test "parse: ENV legacy form collapses rest" {
    var got = try parseString("FROM scratch\nENV LANG en_US.UTF-8 some thing\n");
    defer got.arena.deinit();
    const e = got.result.instructions[1].env;
    try testing.expectEqual(@as(usize, 1), e.entries.len);
    try testing.expectEqualStrings("LANG", e.entries[0].key);
    try testing.expectEqualStrings("en_US.UTF-8 some thing", e.entries[0].value);
}

test "parse: LABEL K=V" {
    var got = try parseString("FROM scratch\nLABEL a=1 b=2\n");
    defer got.arena.deinit();
    const l = got.result.instructions[1].label;
    try testing.expectEqual(@as(usize, 2), l.entries.len);
}

test "parse: EXPOSE multi-port" {
    var got = try parseString("FROM scratch\nEXPOSE 8080 9090/tcp\n");
    defer got.arena.deinit();
    const e = got.result.instructions[1].expose;
    try testing.expectEqual(@as(usize, 2), e.values.len);
    try testing.expectEqualStrings("9090/tcp", e.values[1]);
}

test "parse: ARG before FROM is global" {
    var got = try parseString("ARG BASE=alpine\nFROM scratch\nARG INNER\n");
    defer got.arena.deinit();
    try testing.expect(got.result.instructions[0].arg.is_global);
    try testing.expect(!got.result.instructions[2].arg.is_global);
    try testing.expectEqualStrings("BASE", got.result.instructions[0].arg.name);
    try testing.expectEqualStrings("alpine", got.result.instructions[0].arg.default.?);
    try testing.expect(got.result.instructions[2].arg.default == null);
}

test "parse: HEALTHCHECK NONE clears" {
    var got = try parseString("FROM scratch\nHEALTHCHECK NONE\n");
    defer got.arena.deinit();
    try testing.expect(got.result.instructions[1].healthcheck.value == .none);
}

test "parse: HEALTHCHECK CMD with flags" {
    var got = try parseString("FROM scratch\nHEALTHCHECK --interval=30s --retries=3 CMD curl localhost\n");
    defer got.arena.deinit();
    const h = got.result.instructions[1].healthcheck.value.cmd;
    try testing.expectEqualStrings("30s", h.interval.?);
    try testing.expectEqualStrings("3", h.retries.?);
    try testing.expectEqual(Run.Form.shell, h.form);
    try testing.expectEqual(@as(usize, 2), h.args.len);
}

test "parse: SHELL must be exec form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parse(arena.allocator(), "FROM scratch\nSHELL bash -c\n");
    try testing.expectError(ParseError.ShellNotExec, result);
}

test "parse: SHELL exec form succeeds" {
    var got = try parseString("FROM scratch\nSHELL [\"/bin/bash\",\"-c\"]\n");
    defer got.arena.deinit();
    const s = got.result.instructions[1].shell;
    try testing.expectEqual(@as(usize, 2), s.values.len);
    try testing.expectEqualStrings("/bin/bash", s.values[0]);
}

test "parse: MAINTAINER produces diagnostic" {
    var got = try parseString("FROM scratch\nMAINTAINER alice@example.com\n");
    defer got.arena.deinit();
    try testing.expectEqualStrings("alice@example.com", got.result.instructions[1].maintainer.value);
    try testing.expectEqual(@as(usize, 1), got.result.diagnostics.len);
    try testing.expectEqual(Severity.warn, got.result.diagnostics[0].severity);
}

test "parse: ONBUILD wraps inner directive opaquely" {
    var got = try parseString("FROM scratch\nONBUILD COPY . /app\n");
    defer got.arena.deinit();
    const ob = got.result.instructions[1].onbuild;
    try testing.expectEqual(lex.Directive.copy, ob.inner_directive);
    try testing.expectEqual(@as(usize, 2), ob.raw_args.len);
    try testing.expectEqualStrings(".", ob.raw_args[0]);
    try testing.expectEqualStrings("/app", ob.raw_args[1]);
}

test "parse: nested ONBUILD rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parse(arena.allocator(), "FROM scratch\nONBUILD ONBUILD COPY . /\n");
    try testing.expectError(ParseError.NestedOnBuild, result);
}

test "parse: WORKDIR / USER / STOPSIGNAL single" {
    var got = try parseString("FROM scratch\nWORKDIR /work\nUSER 1000:1000\nSTOPSIGNAL SIGTERM\n");
    defer got.arena.deinit();
    try testing.expectEqualStrings("/work", got.result.instructions[1].workdir.value);
    try testing.expectEqualStrings("1000:1000", got.result.instructions[2].user.value);
    try testing.expectEqualStrings("SIGTERM", got.result.instructions[3].stopsignal.value);
}

test "parse: VOLUME multi" {
    var got = try parseString("FROM scratch\nVOLUME /a /b\n");
    defer got.arena.deinit();
    try testing.expectEqual(@as(usize, 2), got.result.instructions[1].volume.values.len);
}

test "parse: empty source is valid (no instructions)" {
    var got = try parseString("");
    defer got.arena.deinit();
    try testing.expectEqual(@as(usize, 0), got.result.instructions.len);
}

test "parse: parser-directive header passed through" {
    var got = try parseString("# syntax=docker/dockerfile:1.4\nFROM scratch\n");
    defer got.arena.deinit();
    try testing.expect(got.result.header.syntax != null);
    try testing.expectEqualStrings("docker/dockerfile:1.4", got.result.header.syntax.?);
}
