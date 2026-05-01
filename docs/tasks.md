# rind — Tasks

Source of truth for active work. One milestone at a time. Future milestones live in `docs/rind.md` (roadmap section) until they are pulled here for execution.

## Active milestone

**Milestone 1 — Image store and puller** (3 weeks)

Deliver the read path of the OCI ecosystem: parse image refs, fetch manifests and blobs from any compliant registry, store them in an OCI image layout under `~/.rind/store/`, extract layers, and surface what's local through three CLI commands (`pull`, `images`, `inspect`).

By the end of M1, `rtk rind pull alpine:3.19 && rtk rind images && rtk rind inspect alpine:3.19` works end-to-end against Docker Hub.

## Schema

Each task uses this shape:

```markdown
## T## — <imperative title>

**Status:** pending | in-progress | done
**Depends on:** T## (or "none")

### Deliverable

One sentence describing the observable thing this task produces.

### Scope

- What this task includes.
- What this task explicitly excludes (deferred to a later T).

### Acceptance criteria

- [ ] TDD: each test that must exist and pass.
- [ ] E2E: each end-to-end check (or "none — pure library task").
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set (no `anyerror` outside `main.zig`).

### Notes

Specific rule references, constraints, or gotchas.
```

Run everything through RTK (`rtk zig build`, `rtk zig build test`, `rtk zig fmt`) per `CLAUDE.md`.

---

## T01 — Parse image references

**Status:** done
**Depends on:** none

### Deliverable

A `src/image/ref.zig` module exposing `parse(text: []const u8) !ImageRef` that decomposes references like `alpine:3.19`, `ghcr.io/foo/bar:latest`, `docker.io/library/alpine@sha256:...` into `{ registry, repository, tag, digest }`.

### Scope

- All reference forms in the OCI Distribution Spec naming grammar.
- Default registry (`docker.io`) and namespace (`library/`) expansion when omitted.
- Validate tag charset and digest hex length.
- Excludes: credential resolution (T04), normalization beyond the parse step.

### Acceptance criteria

- [ ] TDD: short refs, registry-prefixed refs, digest-only refs, mixed tag+digest, malformed refs (bad digest length, illegal chars, empty), default expansion.
- [ ] E2E: none — pure library task.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set (`ParseError`); no `anyerror` outside `main.zig`.

### Notes

Match `docker pull` default expansion so users coming from Docker aren't surprised. Reference: OCI Distribution Spec § "Pulling Manifests".

---

## T02 — Digest utilities (sha256)

**Status:** done
**Depends on:** none

### Deliverable

A `src/image/digest.zig` module wrapping `std.crypto.hash.sha2.Sha256` with: `Digest` type (algo + 32-byte hex), `parse("sha256:<hex>")`, `format`, `Hasher` streaming wrapper that returns a `Digest` on `final`.

### Scope

- sha256 only (the only OCI-mandatory digest in MVP).
- Constant-time hex compare for `eql`.
- Excludes: sha512 / blake3 (only sha256 is required by the spec).

### Acceptance criteria

- [ ] TDD: parse roundtrip, malformed strings (wrong length, non-hex, missing `sha256:` prefix, wrong algo), `Hasher` matches one-shot `std.crypto.hash.sha2.Sha256` over fixtures, `eql` constant-time path.
- [ ] E2E: none — pure library task.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set (`DigestError`).

### Notes

`Hasher` is reused by T03 (blob writes) and T06 (blob downloads) to avoid double-hashing. Use `std.fmt.bytesToHex` for the hex view.

---

## T03 — OCI image layout on disk

**Status:** pending
**Depends on:** T02

### Deliverable

A `src/store/layout.zig` module that initializes and reads/writes an OCI image layout under a configurable root (default `~/.rind/store/`): the `oci-layout` marker file, `index.json`, and the content-addressable `blobs/sha256/<digest>` tree. Exposes `Store` with `init`, `putBlob` (atomic, digest-verified), `getBlob`, `hasBlob`, `readIndex`, `writeIndex`, `tag`, `untag`.

### Scope

- OCI image layout v1.0.0 compliance — `oci-layout` JSON with `imageLayoutVersion: "1.0.0"`.
- Atomic blob write: stream into `blobs/sha256/<tmp>`, hash on the fly via T02 `Hasher`, verify against expected digest, `rename` into final path. Fail loud on mismatch.
- Concurrent-safe `index.json` updates via `writev` to a temp file + `rename` (no lockfile in MVP).
- Excludes: garbage collection (`rind prune` is M4), zstd-specific concerns (T08 hands raw bytes to T03), auth file (`auth.json` is M4).

### Acceptance criteria

- [ ] TDD: init creates expected layout, `putBlob` is digest-verified (rejects tampered input), `getBlob` returns same bytes, `hasBlob` is true after put, `tag`/`untag` mutate `index.json` correctly, atomic write leaves no partial files on simulated failure.
- [ ] Integration: against a `std.testing.tmpDir` root, full put/tag/read cycle.
- [ ] E2E: none — exercised end-to-end via T09/T10.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set (`StoreError`).

### Notes

OCI image layout spec: <https://github.com/opencontainers/image-spec/blob/main/image-layout.md>. The `index.json` schema is `application/vnd.oci.image.index.v1+json`. Keep blob writes streaming — never buffer a whole layer in memory.

---

## T04 — Registry client: HTTP + Bearer auth

**Status:** pending
**Depends on:** T01

### Deliverable

A `src/registry/client.zig` module wrapping `std.http.Client` with Bearer token negotiation: on 401, parse `WWW-Authenticate`, GET the indicated token endpoint with the requested `service`/`scope`, cache the bearer per `(realm, service, scope)`, and retry the original request once.

### Scope

- `Bearer` and `Basic` schemes (Basic for fully-private registries that skip the token dance).
- Pluggable `Credentials` source (in-memory map for tests; file-backed `auth.json` deferred to M4).
- TLS via `std.crypto.tls` only (revisit BearSSL/BoringSSL only if a real registry breaks it).
- Excludes: HTTP/2 explicit negotiation (rely on `std.http`'s default), retry/backoff beyond the single auth retry (T06 owns transport retries), credential helpers (`docker-credential-*`).

### Acceptance criteria

- [ ] TDD: `WWW-Authenticate` parser handles realm/service/scope/charset combinations, anonymous-token flow, authenticated-token flow with HTTP basic auth header, scope re-request on 401, malformed challenge rejected.
- [ ] Integration: spin a hand-rolled mock HTTP server in a test thread that replays a real registry's challenge-response transcript; assert the client follows it.
- [ ] E2E: none in this task — exercised via T05/T06.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set (`RegistryError` covering `Unauthorized`, `BadChallenge`, `TokenEndpointFailed`, …).

### Notes

Docker registry token spec: <https://distribution.github.io/distribution/spec/auth/token/>. Cache tokens per scope to avoid hammering the token endpoint when fetching N layers in parallel.

---

## T05 — Registry client: manifest GET

**Status:** pending
**Depends on:** T04

### Deliverable

`Client.getManifest(ref) !ManifestResult` that issues `GET /v2/<repo>/manifests/<reference>` with an `Accept` header listing all manifest media types we support, returns the parsed manifest plus its digest and media type.

### Scope

- Accept: `application/vnd.oci.image.manifest.v1+json`, `application/vnd.oci.image.index.v1+json`, `application/vnd.docker.distribution.manifest.v2+json`, `application/vnd.docker.distribution.manifest.list.v2+json`.
- On image-index / manifest-list, pick the platform matching `linux/<host_arch>` (or an explicit override), then re-fetch the picked manifest by digest.
- JSON parse via `std.json` into typed structs (`Manifest`, `Index`, `Descriptor`).
- Excludes: HEAD-only fast path, signed manifests, OCI artifacts beyond images.

### Acceptance criteria

- [ ] TDD: parse fixtures for each of the four media types, platform selection picks `linux/amd64` from a multi-arch list, missing platform yields a typed error, content-type mismatch (server returns OCI but says Docker, etc.) is detected.
- [ ] Integration: mock-server flow returns an index, then the picked manifest, end-to-end through `getManifest`.
- [ ] E2E: none in this task — exercised via T09/T10.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set.

### Notes

Reuse the canonical fixtures from `opencontainers/image-spec` examples for tests. The picked manifest's digest is what we'll record in `index.json` (T03).

---

## T06 — Registry client: blob GET with concurrency + resume

**Status:** pending
**Depends on:** T03, T04

### Deliverable

`Client.getBlob(ref, digest, dest_writer) !void` plus a `Pool` that runs N concurrent `getBlob` calls. Each call streams to a temp file in the store, verifies the digest live (via T02 `Hasher`), and on partial-failure resumes from the recorded byte offset using `Range:` requests.

### Scope

- Streaming download — never holds a whole layer in memory.
- Configurable concurrency (default `min(host_cpus, 4)`); a single shared `Client` so token cache from T04 is reused.
- Resume on connection drop or non-fatal HTTP errors (5xx, network timeout) with bounded retries (default 3) and exponential backoff.
- Excludes: BitTorrent-style chunked parallel downloads of a single blob (out of MVP), pull-through mirror fallback.

### Acceptance criteria

- [ ] TDD: stream digest verification rejects truncation and tampering; `Range` resume after simulated mid-stream cut produces a byte-identical blob; backoff schedule honored; concurrency cap respected (no more than N inflight).
- [ ] Integration: mock server serves a blob with a flaky middle that cuts the connection once; client recovers and writes a digest-verified file.
- [ ] E2E: none in this task — exercised via T09/T10.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set.

### Notes

Use `std.Thread.Pool` for concurrency. The blob's final destination is whatever the caller's writer is (T09 hooks it to `Store.putBlob` from T03, which itself does atomic rename + final digest check). Don't double-hash: pass T02 `Hasher` through.

---

## T07 — Layer extraction: tar + gzip

**Status:** pending
**Depends on:** T03

### Deliverable

`src/image/extract.zig` exposing `extractGzip(blob_reader, dest_dir) !void` that pipes a `tar+gzip`-encoded blob through `std.compress.gzip` and `std.tar` to populate `~/.rind/store/extracted/<digest>/`.

### Scope

- Layer media type `application/vnd.oci.image.layer.v1.tar+gzip` (and the Docker schema-2 equivalent).
- OCI whiteout handling: `.wh.<name>` removes a file, `.wh..wh..opq` clears a directory's contents (per the image-spec layer doc).
- Hardlinks, symlinks, file modes, ownership preserved as far as the user namespace allows.
- Excludes: zstd (T08), in-place overlay merging (M2 territory).

### Acceptance criteria

- [ ] TDD: extract a hand-built fixture tarball, assert file tree and modes match; whiteout removes prior-layer file; opaque whiteout clears directory; absolute path traversal (`../../etc`) rejected; symlink-out-of-rootfs rejected.
- [ ] Integration: extract a real public alpine layer fixture (vendored under `tests/fixtures/`) into a tmp dir.
- [ ] E2E: none in this task — exercised via T09/T10.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set (`ExtractError`).

### Notes

OCI image-spec layer doc: <https://github.com/opencontainers/image-spec/blob/main/layer.md>. Path-traversal hardening is non-negotiable — a malicious layer must not write outside `dest_dir`.

---

## T08 — Layer extraction: tar + zstd

**Status:** pending
**Depends on:** T07

### Deliverable

`extractZstd(blob_reader, dest_dir) !void` mirroring T07 but for `application/vnd.oci.image.layer.v1.tar+zstd`. Adds a `libzstd` dependency wired through `build.zig` (Zig 0.16 `std.compress` does not ship a zstd decoder).

### Scope

- libzstd vendored as a system or git-submodule dep, linked statically; document the choice in `build.zig.zon`.
- Same whiteout / hardening rules as T07.
- Excludes: zstd encoding (push is M4), zstd dictionary support.

### Acceptance criteria

- [ ] TDD: hand-built `.tar.zst` fixture extracts identically to its `.tar.gz` twin from T07; truncated / corrupted streams produce typed errors.
- [ ] Integration: extract a real zstd-compressed layer fixture.
- [ ] E2E: none in this task — exercised via T09/T10 if a zstd-using image is in the test matrix.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set.

### Notes

If wiring libzstd proves heavier than expected, defer this task into a "T08-spike" sub-task; it is not gating M1 because all of Docker Hub's most-pulled images ship gzip layers. But OCI registries (e.g. zot, Harbor configured for zstd) need it for compliance.

---

## T09 — Pull orchestrator

**Status:** pending
**Depends on:** T01, T03, T05, T06, T07, T08

### Deliverable

`src/pull.zig` exposing `pullImage(ref_text, store, client, options) !PullResult`: parses the ref (T01), fetches the manifest (T05), fans out concurrent blob downloads (T06) for the config + each layer into the store (T03), extracts layers (T07/T08), and tags `index.json` with the user's reference.

### Scope

- Skips already-present blobs based on `Store.hasBlob` (warm-cache fast path).
- Reports progress via a callback (`PullEvent` enum: `manifest`, `blob_started`, `blob_progress`, `blob_done`, `extracted`, `done`) — UI is wired up in T10.
- Excludes: signature verification (cosign deferred), sub-image references with multi-platform fan-out beyond the single picked platform.

### Acceptance criteria

- [ ] TDD: orchestrator skips blobs already present, surfaces a typed error when a layer media type is unsupported (T08 not yet wired? still typed), aggregates progress events in order.
- [ ] Integration: against the mock registry from T04/T05/T06, pull a synthesized two-layer image into a tmp store; assert blob tree, `index.json`, and extracted dirs are correct.
- [ ] E2E: gated by `RIND_E2E=1`, run `pullImage("alpine:3.19", ...)` against Docker Hub and assert `rind images` lists alpine and `inspect` returns its config.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set.

### Notes

This is the integration boundary for everything below it; if T03–T08 keep their interfaces honest, this task is mostly glue.

---

## T10 — CLI: `rind pull`

**Status:** pending
**Depends on:** T09

### Deliverable

`rind pull <image>` wired in `src/main.zig` (or a dedicated `src/cli/pull.zig`). Default output is terse human (one line per layer with hit/miss + size); `--output json` emits a stable, schema-versioned event stream; `RIND_LOG=rind=debug` enables diagnostic logging on stderr.

### Scope

- Argparse minimal: positional `<image>`, `--output {human,json}`, `--quiet`, `--platform` (errors if not host — single-platform MVP).
- Exit codes: 0 success, 1 generic, 2 usage, 3 network, 4 verification.
- Excludes: progress bars / multi-line redraw (deferred to v0.2 polish), `--all-tags`, `--platform` actually doing cross-platform.

### Acceptance criteria

- [ ] TDD: argparse accepts/rejects expected flag combinations, JSON event shape matches a snapshot fixture.
- [ ] Integration: stub `pullImage` injected into the CLI handler; assert exit codes and output across success/failure paths.
- [ ] E2E: gated by `RIND_E2E=1`, `rtk rind pull alpine:3.19` succeeds end-to-end and the resulting tree on disk matches expectations.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set; `main.zig` is the only place that maps errors to exit codes.

### Notes

Stable JSON schema is the contract miru depends on (see `docs/rind.md` § "Integration with miru"). Bump a `schema_version` field if the shape ever changes.

---

## T11 — CLI: `rind images`

**Status:** pending
**Depends on:** T03

### Deliverable

`rind images` lists local images (refs from `index.json`, each with image digest, total size summed across unique layers, created-at from the image config). `--output json` for stable machine output.

### Scope

- Reads `index.json` (T03) and the referenced config blobs to compute size and created-at.
- Human output is a fixed-width table; JSON is an array of `{ ref, digest, size, created_at }`.
- Excludes: `--filter`, `--digests`, `--no-trunc` flags; dangling-image awareness (no GC in M1).

### Acceptance criteria

- [ ] TDD: rendering produces a stable human snapshot and a stable JSON snapshot for a fixture store.
- [ ] Integration: prepare a tmp store via T03 helpers, run `images` against it, assert output.
- [ ] E2E: after `rtk rind pull alpine:3.19`, `rtk rind images` lists alpine.
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set.

### Notes

"Total size" uses the sum of unique layer blob sizes belonging to that image (not the on-disk extracted size, which can differ).

---

## T12 — CLI: `rind inspect`

**Status:** pending
**Depends on:** T01, T03, T11

### Deliverable

`rind inspect <image>` dumps the image config JSON for a local image (resolved by ref or digest). Always JSON output (the command exists for machine consumption).

### Scope

- Image references only in M1. Container references are added in M2 when containers exist.
- Pretty-printed by default; `--output json-compact` for one-line.
- Excludes: format templating (`docker inspect --format`), partial-field projection.

### Acceptance criteria

- [ ] TDD: ref resolution finds the right config blob; missing image yields exit code 1 + a typed error message; output matches a snapshot.
- [ ] Integration: against a fixture store, inspect by tag and by digest both return the same config.
- [ ] E2E: after `rtk rind pull alpine:3.19`, `rtk rind inspect alpine:3.19` returns valid JSON whose `architecture` field is `amd64` (or host arch).
- [ ] `zig fmt --check src/`, `zig build`, `zig build test` all clean.
- [ ] Every `pub` item has a `///` doc comment.
- [ ] Every error path uses a typed error set.

### Notes

This task closes M1: with T10/T11/T12 working against the same `~/.rind/store/`, the read path is provably end-to-end.

---

## Dependency graph (M1)

```
T01 ──┐                                  ┌── T10 (rind pull)
      ├── T04 ── T05 ──┐                 │
T02 ──┴── T03 ─────────┼── T09 ──────────┤
              │        │                 ├── T11 (rind images)
              ├── T06 ─┤                 │
              ├── T07 ─┤                 └── T12 (rind inspect)
              └── T08 ─┘
```

## Definition of done — Milestone 1

All twelve tasks marked **done**. The smoke loop:

```
rtk rind pull alpine:3.19
rtk rind images
rtk rind inspect alpine:3.19
```

…runs against Docker Hub on a clean `~/.rind/`, produces sane output for human + JSON formats, and re-pull is fast (warm cache hits, no network for already-present blobs).
