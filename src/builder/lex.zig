//! Containerfile lexer.
//!
//! Tokenises a Containerfile byte slice into a flat token stream plus a
//! side-channel `Header` carrying parser directives (`# syntax=`,
//! `# escape=`). The grammar is the BuildKit dialect: 18 directive
//! keywords, line continuations via the active escape char, here-docs
//! (`<<TAG` and `<<-TAG`), JSON-array exec form, and shell-form
//! whitespace-split args with quote awareness.
//!
//! Token text fields are slices into the caller's `src` buffer, so
//! `tokenize` allocates only the `Token` array. Quote chars and escape
//! sequences are preserved verbatim in the token text; the parser
//! does interpretation. The lexer's job is to chunk bytes and surface
//! span info for accurate downstream diagnostics.
//!
//! Header rule: parser directives are recognised inside the leading
//! comment block (any contiguous run of comments and blank lines at the
//! top of the file). Once a directive line lands, subsequent
//! `#`-comments are plain comments. This is a slight simplification of
//! BuildKit's "first non-parser-directive comment closes the
//! header"-rule; close enough for build-time use.

const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

/// 1-based source position for a token. `offset`/`len` point into the
/// caller's `src`; `line`/`col` are derived for human-friendly error
/// formatting in the parser and downstream tools.
pub const Span = struct {
    offset: u32,
    len: u32,
    line: u32,
    col: u32,
};

/// Canonical directive tag. The original source casing is preserved on
/// the directive token's `text` field; this enum is what the parser
/// dispatches on.
pub const Directive = enum {
    from,
    run,
    copy,
    add,
    env,
    workdir,
    user,
    cmd,
    entrypoint,
    expose,
    label,
    arg,
    stopsignal,
    healthcheck,
    shell,
    volume,
    /// Deprecated by Docker; lexes successfully but the lexer also
    /// emits a `.deprecated_warn` token alongside it so the parser
    /// can surface a warning without re-lexing.
    maintainer,
    onbuild,
};

/// Token kinds emitted by `tokenize`. Line continuations are not
/// emitted; they are recognised and dropped, with payload tokens
/// covering whatever spans across the continuation.
pub const TokenKind = enum {
    /// One per logical instruction. `directive_tag` is set.
    directive,
    /// Shell-form arg or any whitespace-delimited bareword/quoted run
    /// in the payload. Quote chars are part of `text` when present.
    string,
    /// Raw `[ ... ]` exec-form literal. No JSON validation here.
    json_array,
    /// Body of a here-doc, with leading tabs stripped if the
    /// declarator was `<<-TAG`. Trailing newline before the delimiter
    /// line is included.
    heredoc_body,
    /// End of one logical instruction.
    newline,
    /// Co-emitted next to the canonical directive token when
    /// `MAINTAINER` is seen. `text` carries human-readable warning.
    deprecated_warn,
    /// End of file.
    eof,
};

/// One token in the stream. `text` is a slice into the caller's source
/// buffer (zero-copy); the only exception is `.deprecated_warn`, whose
/// `text` is a static string baked into the binary.
pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    span: Span,
    directive_tag: ?Directive = null,
};

/// Side-channel header recorded from parser-directive comments before
/// the first instruction. Carried alongside the token slice so the
/// parser gets it without re-scanning bytes.
pub const Header = struct {
    /// Value of `# syntax=...` if present; slice into source.
    syntax: ?[]const u8 = null,
    /// Active escape char. Default `\\`; toggled by `# escape=\``.
    escape: u8 = '\\',
};

/// Caller-owned bundle returned by `tokenize`. `tokens` is heap-
/// allocated via the same allocator passed in; free with `deinit`.
pub const Result = struct {
    header: Header,
    tokens: []Token,

    /// Release the token array. Header carries no owned memory.
    pub fn deinit(self: *Result, gpa: Allocator) void {
        gpa.free(self.tokens);
        self.* = undefined;
    }
};

/// Failure modes surfaced as a closed error set so callers can
/// pattern-match. Allocation failures are merged in.
pub const LexError = error{
    /// Here-doc declarator opened but the matching delimiter was never
    /// found before EOF.
    UnterminatedHeredoc,
    /// A `"`- or `'`-quoted run hit a newline or EOF before its
    /// closing quote.
    UnterminatedString,
    /// An escape sequence inside a `"`-quoted run referenced a char
    /// that the lexer does not recognise. Outside double quotes the
    /// escape char is treated as a passthrough; this error is
    /// reserved for the strictly-validated quoted-string path.
    BadEscape,
    /// The directive keyword on an instruction line did not match any
    /// of the 18 known directives.
    BadDirective,
} || Allocator.Error;

/// Lex `src`. The returned `Result` references slices into `src`, so
/// `src` must outlive the result.
pub fn tokenize(gpa: Allocator, src: []const u8) LexError!Result {
    var lex: Lexer = .{ .src = src };
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);

    try lex.parseHeader();
    while (true) {
        try lex.skipBlankAndComments();
        if (lex.atEof()) break;
        try lex.lexInstruction(gpa, &tokens);
    }
    try tokens.append(gpa, .{
        .kind = .eof,
        .text = "",
        .span = .{
            .offset = @intCast(lex.index),
            .len = 0,
            .line = lex.line,
            .col = lex.col,
        },
    });

    return .{
        .header = lex.header,
        .tokens = try tokens.toOwnedSlice(gpa),
    };
}

const Lexer = struct {
    src: []const u8,
    index: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    header: Header = .{},

    fn atEof(self: *const Lexer) bool {
        return self.index >= self.src.len;
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.atEof()) return null;
        return self.src[self.index];
    }

    fn peekAt(self: *const Lexer, off: usize) ?u8 {
        if (self.index + off >= self.src.len) return null;
        return self.src[self.index + off];
    }

    fn advance(self: *Lexer) void {
        if (self.atEof()) return;
        const c = self.src[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
    }

    fn parseHeader(self: *Lexer) LexError!void {
        while (!self.atEof()) {
            const line_start_index = self.index;
            const line_start_line = self.line;
            const line_start_col = self.col;
            // Skip leading horizontal whitespace at start of physical line.
            while (!self.atEof()) {
                const c = self.src[self.index];
                if (c == ' ' or c == '\t') self.advance() else break;
            }
            if (self.atEof()) return;
            const ch = self.src[self.index];
            if (ch == '\n' or ch == '\r') {
                self.consumeOneEol();
                continue;
            }
            if (ch != '#') {
                self.index = line_start_index;
                self.line = line_start_line;
                self.col = line_start_col;
                return;
            }
            // We're at a `#`-comment.
            self.advance(); // consume '#'
            // Skip whitespace after `#`.
            while (!self.atEof()) {
                const c = self.src[self.index];
                if (c == ' ' or c == '\t') self.advance() else break;
            }
            const kw_start = self.index;
            while (!self.atEof()) {
                const c = self.src[self.index];
                if (c == '=' or c == '\n' or c == '\r' or c == ' ' or c == '\t') break;
                self.advance();
            }
            const kw = self.src[kw_start..self.index];
            if (self.peek() == @as(?u8, '=')) {
                self.advance();
                const val_start = self.index;
                while (!self.atEof() and self.src[self.index] != '\n' and self.src[self.index] != '\r') self.advance();
                const val = self.src[val_start..self.index];
                if (ascii.eqlIgnoreCase(kw, "syntax")) {
                    self.header.syntax = val;
                } else if (ascii.eqlIgnoreCase(kw, "escape")) {
                    if (val.len == 1 and (val[0] == '\\' or val[0] == '`')) {
                        self.header.escape = val[0];
                    }
                }
            } else {
                while (!self.atEof() and self.src[self.index] != '\n' and self.src[self.index] != '\r') self.advance();
            }
            self.consumeOneEol();
        }
    }

    fn consumeOneEol(self: *Lexer) void {
        if (self.peek() == @as(?u8, '\r')) self.advance();
        if (self.peek() == @as(?u8, '\n')) self.advance();
    }

    fn skipHWhitespace(self: *Lexer) void {
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (c == ' ' or c == '\t') self.advance() else break;
        }
    }

    fn skipBlankAndComments(self: *Lexer) LexError!void {
        while (!self.atEof()) {
            const ch = self.src[self.index];
            if (ch == ' ' or ch == '\t') {
                self.advance();
                continue;
            }
            if (ch == '\n' or ch == '\r') {
                self.consumeOneEol();
                continue;
            }
            if (ch == '#') {
                while (!self.atEof() and self.src[self.index] != '\n') self.advance();
                continue;
            }
            return;
        }
    }

    fn lexInstruction(self: *Lexer, gpa: Allocator, tokens: *std.ArrayList(Token)) LexError!void {
        const dir_start = self.index;
        const dir_line = self.line;
        const dir_col = self.col;
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (ascii.isAlphabetic(c)) self.advance() else break;
        }
        const dir_text = self.src[dir_start..self.index];
        if (dir_text.len == 0) return LexError.BadDirective;
        const tag = matchDirective(dir_text) orelse return LexError.BadDirective;

        try tokens.append(gpa, .{
            .kind = .directive,
            .text = dir_text,
            .span = .{
                .offset = @intCast(dir_start),
                .len = @intCast(dir_text.len),
                .line = dir_line,
                .col = dir_col,
            },
            .directive_tag = tag,
        });

        if (tag == .maintainer) {
            try tokens.append(gpa, .{
                .kind = .deprecated_warn,
                .text = "MAINTAINER directive is deprecated; use LABEL maintainer=...",
                .span = .{
                    .offset = @intCast(dir_start),
                    .len = @intCast(dir_text.len),
                    .line = dir_line,
                    .col = dir_col,
                },
            });
        }

        self.skipHWhitespace();

        if (self.peek() == @as(?u8, '[')) {
            try self.lexJsonArray(gpa, tokens);
        } else {
            try self.lexShellPayload(gpa, tokens);
        }
    }

    fn lexJsonArray(self: *Lexer, gpa: Allocator, tokens: *std.ArrayList(Token)) LexError!void {
        const start = self.index;
        const start_line = self.line;
        const start_col = self.col;
        var depth: usize = 0;
        var in_string = false;
        var str_escape = false;
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (in_string) {
                if (str_escape) {
                    str_escape = false;
                    self.advance();
                    continue;
                }
                if (c == '\\') {
                    str_escape = true;
                    self.advance();
                    continue;
                }
                if (c == '"') {
                    in_string = false;
                    self.advance();
                    continue;
                }
                if (c == '\n') return LexError.UnterminatedString;
                self.advance();
                continue;
            }
            if (c == '"') {
                in_string = true;
                self.advance();
                continue;
            }
            if (c == '[') {
                depth += 1;
                self.advance();
                continue;
            }
            if (c == ']') {
                self.advance();
                depth -= 1;
                if (depth == 0) break;
                continue;
            }
            if (c == '\n') return LexError.UnterminatedString;
            self.advance();
        }
        if (in_string) return LexError.UnterminatedString;
        if (depth != 0) return LexError.UnterminatedString;

        const text = self.src[start..self.index];
        try tokens.append(gpa, .{
            .kind = .json_array,
            .text = text,
            .span = .{
                .offset = @intCast(start),
                .len = @intCast(text.len),
                .line = start_line,
                .col = start_col,
            },
        });

        // Eat any trailing whitespace and the line terminator.
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (c == ' ' or c == '\t') {
                self.advance();
                continue;
            }
            break;
        }
        self.consumeOneEol();
        try tokens.append(gpa, .{
            .kind = .newline,
            .text = "",
            .span = .{
                .offset = @intCast(self.index),
                .len = 0,
                .line = self.line,
                .col = self.col,
            },
        });
    }

    fn lexShellPayload(self: *Lexer, gpa: Allocator, tokens: *std.ArrayList(Token)) LexError!void {
        var heredoc_delims: std.ArrayList([]const u8) = .empty;
        defer heredoc_delims.deinit(gpa);
        var heredoc_strip: std.ArrayList(bool) = .empty;
        defer heredoc_strip.deinit(gpa);

        while (!self.atEof()) {
            self.skipHWhitespace();
            if (self.atEof()) break;
            const c = self.src[self.index];
            if (c == '\n' or c == '\r') break;

            if (c == self.header.escape) {
                if (try self.tryConsumeContinuation()) continue;
            }

            if (self.at("<<")) {
                try self.lexHeredocDeclarator(gpa, tokens, &heredoc_delims, &heredoc_strip);
                continue;
            }

            try self.lexShellToken(gpa, tokens);
        }

        // Consume the physical EOL terminating the (last) line of the
        // logical instruction. Heredoc bodies start on the next physical
        // line, in declaration order.
        self.consumeOneEol();

        for (heredoc_delims.items, heredoc_strip.items) |delim, strip| {
            try self.collectHeredoc(gpa, tokens, delim, strip);
        }

        try tokens.append(gpa, .{
            .kind = .newline,
            .text = "",
            .span = .{
                .offset = @intCast(self.index),
                .len = 0,
                .line = self.line,
                .col = self.col,
            },
        });
    }

    fn at(self: *const Lexer, lit: []const u8) bool {
        if (self.index + lit.len > self.src.len) return false;
        return std.mem.eql(u8, self.src[self.index .. self.index + lit.len], lit);
    }

    /// True iff the cursor sat on the active escape char and it was
    /// followed (modulo horizontal whitespace) by `\n` or EOF; in that
    /// case the continuation, the EOL, and any subsequent blank or
    /// `#`-comment lines are consumed. Otherwise the cursor is left
    /// untouched.
    fn tryConsumeContinuation(self: *Lexer) LexError!bool {
        const saved_index = self.index;
        const saved_line = self.line;
        const saved_col = self.col;
        self.advance(); // candidate escape
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (c == ' ' or c == '\t') self.advance() else break;
        }
        const at_eol = self.atEof() or self.src[self.index] == '\n' or self.src[self.index] == '\r';
        if (!at_eol) {
            self.index = saved_index;
            self.line = saved_line;
            self.col = saved_col;
            return false;
        }
        self.consumeOneEol();
        // Skip blank lines and `#`-comments inside the continuation.
        while (!self.atEof()) {
            const before = self.index;
            // Probe leading whitespace without committing.
            var probe = self.index;
            while (probe < self.src.len) {
                const c = self.src[probe];
                if (c == ' ' or c == '\t') probe += 1 else break;
            }
            if (probe >= self.src.len) {
                self.index = probe;
                self.col += @intCast(probe - before);
                return true;
            }
            const c = self.src[probe];
            if (c == '\n' or c == '\r') {
                while (self.index < probe) self.advance();
                self.consumeOneEol();
                continue;
            }
            if (c == '#') {
                while (self.index < probe) self.advance();
                while (!self.atEof() and self.src[self.index] != '\n') self.advance();
                self.consumeOneEol();
                continue;
            }
            return true;
        }
        return true;
    }

    fn lexHeredocDeclarator(
        self: *Lexer,
        gpa: Allocator,
        tokens: *std.ArrayList(Token),
        delims: *std.ArrayList([]const u8),
        strip_flags: *std.ArrayList(bool),
    ) LexError!void {
        const tok_start = self.index;
        const tok_line = self.line;
        const tok_col = self.col;
        self.advance(); // '<'
        self.advance(); // '<'
        var strip = false;
        if (self.peek() == @as(?u8, '-')) {
            strip = true;
            self.advance();
        }
        var delim: []const u8 = undefined;
        if (self.peek() == @as(?u8, '"') or self.peek() == @as(?u8, '\'')) {
            const q = self.src[self.index];
            self.advance();
            const inner_start = self.index;
            while (!self.atEof() and self.src[self.index] != q) {
                if (self.src[self.index] == '\n') return LexError.UnterminatedString;
                self.advance();
            }
            if (self.atEof()) return LexError.UnterminatedString;
            delim = self.src[inner_start..self.index];
            self.advance(); // closing quote
        } else {
            const ds = self.index;
            while (!self.atEof()) {
                const c = self.src[self.index];
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
                self.advance();
            }
            delim = self.src[ds..self.index];
            if (delim.len == 0) return LexError.UnterminatedHeredoc;
        }

        const text = self.src[tok_start..self.index];
        try tokens.append(gpa, .{
            .kind = .string,
            .text = text,
            .span = .{
                .offset = @intCast(tok_start),
                .len = @intCast(text.len),
                .line = tok_line,
                .col = tok_col,
            },
        });
        try delims.append(gpa, delim);
        try strip_flags.append(gpa, strip);
    }

    fn lexShellToken(self: *Lexer, gpa: Allocator, tokens: *std.ArrayList(Token)) LexError!void {
        const start = self.index;
        const start_line = self.line;
        const start_col = self.col;
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            if (c == '"') {
                try self.consumeQuotedDouble();
                continue;
            }
            if (c == '\'') {
                try self.consumeQuotedSingle();
                continue;
            }
            if (c == self.header.escape) {
                // Mid-token escape: pass through together with the next
                // byte. `\<newline>` is handled at the top-level loop
                // before we entered here, so any `\<newline>` that
                // shows up here is a stray; emit it raw and let the
                // parser decide.
                self.advance();
                if (!self.atEof()) self.advance();
                continue;
            }
            self.advance();
        }
        const text = self.src[start..self.index];
        if (text.len == 0) return;
        try tokens.append(gpa, .{
            .kind = .string,
            .text = text,
            .span = .{
                .offset = @intCast(start),
                .len = @intCast(text.len),
                .line = start_line,
                .col = start_col,
            },
        });
    }

    fn consumeQuotedDouble(self: *Lexer) LexError!void {
        self.advance(); // opening '"'
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (c == '\n') return LexError.UnterminatedString;
            if (c == '"') {
                self.advance();
                return;
            }
            if (c == self.header.escape) {
                self.advance();
                const e = self.peek() orelse return LexError.UnterminatedString;
                switch (e) {
                    '\\', '`', '"', '\'', 'n', 'r', 't', '0', '$' => self.advance(),
                    else => return LexError.BadEscape,
                }
                continue;
            }
            self.advance();
        }
        return LexError.UnterminatedString;
    }

    fn consumeQuotedSingle(self: *Lexer) LexError!void {
        self.advance(); // opening '\''
        while (!self.atEof()) {
            const c = self.src[self.index];
            if (c == '\n') return LexError.UnterminatedString;
            if (c == '\'') {
                self.advance();
                return;
            }
            self.advance();
        }
        return LexError.UnterminatedString;
    }

    fn collectHeredoc(
        self: *Lexer,
        gpa: Allocator,
        tokens: *std.ArrayList(Token),
        delim: []const u8,
        strip: bool,
    ) LexError!void {
        const body_start = self.index;
        const body_line = self.line;
        const body_col = self.col;
        while (true) {
            if (self.atEof()) return LexError.UnterminatedHeredoc;
            const line_begin = self.index;
            var probe = line_begin;
            while (probe < self.src.len and self.src[probe] != '\n') probe += 1;
            const has_newline = probe < self.src.len;
            const phys_end = probe;

            var match_begin = line_begin;
            if (strip) while (match_begin < phys_end and self.src[match_begin] == '\t') {
                match_begin += 1;
            };
            var match_end = phys_end;
            if (match_end > match_begin and self.src[match_end - 1] == '\r') match_end -= 1;
            const candidate = self.src[match_begin..match_end];

            if (std.mem.eql(u8, candidate, delim)) {
                const body_text = self.src[body_start..line_begin];
                try tokens.append(gpa, .{
                    .kind = .heredoc_body,
                    .text = body_text,
                    .span = .{
                        .offset = @intCast(body_start),
                        .len = @intCast(body_text.len),
                        .line = body_line,
                        .col = body_col,
                    },
                });
                while (self.index < phys_end) self.advance();
                if (has_newline) self.advance();
                return;
            }
            while (self.index < phys_end) self.advance();
            if (has_newline) self.advance();
        }
    }
};

fn matchDirective(text: []const u8) ?Directive {
    const table = [_]struct { name: []const u8, tag: Directive }{
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
    for (table) |row| {
        if (ascii.eqlIgnoreCase(row.name, text)) return row.tag;
    }
    return null;
}

const testing = std.testing;

fn expectKinds(result: *Result, expected: []const TokenKind) !void {
    try testing.expectEqual(expected.len, result.tokens.len);
    for (expected, result.tokens) |want, got| {
        try testing.expectEqual(want, got.kind);
    }
}

test "single FROM smoke" {
    const src = "FROM alpine:3.19\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .string, .newline, .eof });
    try testing.expectEqual(Directive.from, r.tokens[0].directive_tag.?);
    try testing.expectEqualStrings("FROM", r.tokens[0].text);
    try testing.expectEqualStrings("alpine:3.19", r.tokens[1].text);
}

test "case-insensitive directive preserves source casing" {
    const src = "from alpine\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Directive.from, r.tokens[0].directive_tag.?);
    try testing.expectEqualStrings("from", r.tokens[0].text);
}

test "multi-line RUN with backslash continuation" {
    const src = "RUN apt-get update \\\n    && apt-get install -y curl\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .string, .string, .string, .string, .string, .string, .string, .newline, .eof });
    try testing.expectEqualStrings("apt-get", r.tokens[1].text);
    try testing.expectEqualStrings("update", r.tokens[2].text);
    try testing.expectEqualStrings("&&", r.tokens[3].text);
    try testing.expectEqualStrings("curl", r.tokens[7].text);
}

test "JSON-array CMD exec form" {
    const src = "CMD [\"sh\", \"-c\", \"echo hi\"]\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .json_array, .newline, .eof });
    try testing.expectEqualStrings("[\"sh\", \"-c\", \"echo hi\"]", r.tokens[1].text);
}

test "LABEL with quoted value containing escape" {
    const src = "LABEL desc=\"foo bar\\nbaz\"\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .string, .newline, .eof });
    try testing.expectEqualStrings("desc=\"foo bar\\nbaz\"", r.tokens[1].text);
}

test "here-doc EOF preserves body verbatim" {
    const src =
        \\RUN <<EOF
        \\echo hi
        \\echo bye
        \\EOF
        \\
    ;
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .string, .heredoc_body, .newline, .eof });
    try testing.expectEqualStrings("<<EOF", r.tokens[1].text);
    try testing.expectEqualStrings("echo hi\necho bye\n", r.tokens[2].text);
}

test "here-doc with leading-tab strip" {
    const src = "RUN <<-EOF\n\thello\n\tworld\n\tEOF\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .string, .heredoc_body, .newline, .eof });
    try testing.expectEqualStrings("<<-EOF", r.tokens[1].text);
    try testing.expectEqualStrings("\thello\n\tworld\n", r.tokens[2].text);
}

test "comment between continuation lines is skipped" {
    const src = "RUN echo a \\\n# inline comment\n  echo b\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .string, .string, .string, .string, .newline, .eof });
    try testing.expectEqualStrings("echo", r.tokens[1].text);
    try testing.expectEqualStrings("a", r.tokens[2].text);
    try testing.expectEqualStrings("echo", r.tokens[3].text);
    try testing.expectEqualStrings("b", r.tokens[4].text);
}

test "backtick escape directive toggles continuation char" {
    const src = "# escape=`\nRUN echo a `\n  echo b\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, '`'), r.header.escape);
    try expectKinds(&r, &.{ .directive, .string, .string, .string, .string, .newline, .eof });
    try testing.expectEqualStrings("b", r.tokens[4].text);
}

test "syntax parser-directive lands on header" {
    const src = "# syntax=docker/dockerfile:1.4\nFROM alpine\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("docker/dockerfile:1.4", r.header.syntax.?);
    try testing.expectEqual(Directive.from, r.tokens[0].directive_tag.?);
}

test "MAINTAINER emits deprecated_warn alongside directive" {
    const src = "MAINTAINER alice@example.com\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try expectKinds(&r, &.{ .directive, .deprecated_warn, .string, .newline, .eof });
    try testing.expectEqual(Directive.maintainer, r.tokens[0].directive_tag.?);
}

test "unknown directive rejected" {
    const src = "BORK something\n";
    try testing.expectError(LexError.BadDirective, tokenize(testing.allocator, src));
}

test "unterminated double-quoted string rejected" {
    const src = "LABEL k=\"unterminated\n";
    try testing.expectError(LexError.UnterminatedString, tokenize(testing.allocator, src));
}

test "unknown escape inside double-quoted string rejected" {
    const src = "LABEL k=\"a\\zb\"\n";
    try testing.expectError(LexError.BadEscape, tokenize(testing.allocator, src));
}

test "unterminated here-doc rejected" {
    const src = "RUN <<EOF\nhello\n";
    try testing.expectError(LexError.UnterminatedHeredoc, tokenize(testing.allocator, src));
}

test "spans line and column track multi-line input" {
    const src = "FROM alpine\nRUN echo hi\n";
    var r = try tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.tokens[0].span.line);
    try testing.expectEqual(@as(u32, 1), r.tokens[0].span.col);
    try testing.expectEqual(@as(u32, 2), r.tokens[3].span.line);
    try testing.expectEqual(@as(u32, 1), r.tokens[3].span.col);
}
