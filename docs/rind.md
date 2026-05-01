# rind — MVP Specification

> *rind — the thin outer skin around a fruit. The minimum that holds the thing together. Because that's all a container should be: a thin skin around a process, not a daemon-managed planet around it.*

## What rind is

A daemonless OCI container builder and runtime, written in Zig, distributed as a single static binary. It pulls, builds, runs, and pushes OCI-compliant container images without a background service.

rind solves one specific pain: **the Docker stack is enormous and slow to start for what should be a thin namespace+cgroup wrapper.** On Linux, the kernel already does the hard part. The Docker Engine, BuildKit, containerd, the API daemon, and the desktop UI are all cost imposed on top. rind cuts that to: a binary you invoke, that pulls/builds/runs and exits.

It is the default container backend for **miru**, but stands on its own as a Docker substitute for the cases where you want to script container workflows without keeping a daemon alive.

## What rind is *not* (in the MVP)

- Not a Docker drop-in CLI — similar verbs, but not bug-for-bug compatible
- Not a Kubernetes runtime (no CRI shim in MVP)
- Not a daemon — no `rindd`, no socket server, no API
- Not a networking stack — host network and basic bridge only
- Not a registry — pulls from and pushes to existing registries (Docker Hub, GHCR, ECR, GAR, Quay)
- Not Buildx — single-platform builds only in MVP
- Not Podman — different design priorities (Podman is feature-complete; rind is minimal)
- Not a macOS-native runtime in MVP — Linux first

These are explicit non-goals to keep MVP shippable.

## Target user

The dev who has typed `docker system prune -a` in frustration this month. Specifically:

- Runs containers on Linux dev machines or CI runners where Docker Desktop is overkill
- Wants `docker build` and `docker run` semantics without the daemon
- Is using rind as miru's backend (primary path)
- Builds OCI images and pushes them to a registry as part of CI/CD
- Has tried Buildah/Podman and likes the daemonless model but wants something smaller and faster to install

## Success criteria for the MVP

The MVP is done when **the author and miru can stop depending on Docker on Linux for the build-run-push loop**. Concrete metrics:

- Build a typical 5-stage Node.js/Python Dockerfile end-to-end in under 1.5× BuildKit time on a cold cache
- Warm-cache rebuild of the same Dockerfile in under 0.3× BuildKit time
- Container start latency (image already pulled, runc-bound) under 80ms
- Pull a 250MB image with no overhead beyond network + disk I/O + 200ms
- Single binary install, no dependencies beyond `runc` or `crun` on the system
- Drives miru's container backend with no observable difference from Docker for supported features

---

## Architecture

### Single static binary, no daemon

rind is one Zig binary. Every invocation is a fresh process: parses arguments, does work, exits. State lives on disk in `~/.rind/`. There is no IPC, no socket, no service file.

### Components

**Image store** — content-addressable storage for blobs (layers, configs, manifests) at `~/.rind/store/`. Layout is OCI image layout spec compliant, so `~/.rind/store/blobs/sha256/<digest>` is portable to any OCI tool.

**Registry client** — HTTP client for OCI Distribution Spec. Handles Bearer token auth, manifest negotiation (`application/vnd.oci.image.manifest.v1+json` and Docker schema 2), layer download with concurrency, retry with backoff, and resume.

**Containerfile parser** — parses `Containerfile` / `Dockerfile`. Builds an in-memory build plan as a sequence of instructions. Validates ARG references and FROM stages.

**Builder** — executes the build plan. Each instruction produces a new layer (or reuses a cached one). Layer cache key is `hash(parent_layer_digest, instruction_text, context_files_hash)`. Layers are tar streams piped through gzip or zstd, then content-addressed.

**Bundle composer** — given an image config and unpacked layer dirs, builds an OCI runtime bundle: a directory with `config.json` (OCI runtime spec) and `rootfs/` (overlay or extracted). Hands the bundle path to the runtime.

**Runtime shim** — wraps `runc` (default) or `crun` (faster, opt-in). rind does not reimplement the OCI runtime spec in MVP. The shim does fork/exec, plumbs stdio, propagates signals, and reaps the child. Switching to `crun` is a config flag.

**CLI** — argument parser, subcommands, output formatting. Reads `~/.rind/config.toml` for defaults (registry mirrors, runtime choice, storage driver).

### Storage layout

```
~/.rind/
├── config.toml                           # user config
├── store/                                # OCI image layout
│   ├── oci-layout
│   ├── index.json                        # local images
│   └── blobs/sha256/<digest>             # all blobs (layers, configs, manifests)
├── overlays/<container-id>/              # ephemeral overlay dirs for running containers
│   ├── upper/
│   ├── work/
│   └── merged/                           # mountpoint
├── bundles/<container-id>/               # OCI runtime bundles
│   ├── config.json
│   └── rootfs -> ../overlays/<id>/merged
├── build-cache/                          # build layer cache index
│   └── cache.json                        # map of cache key → layer digest
└── auth.json                             # registry credentials (or use OS keyring)
```

### How a `rind run` works

1. Parse CLI args, resolve image reference (e.g., `alpine:3.19`).
2. Check store for image. If missing, pull via registry client.
3. For each layer, ensure it's extracted to a content-addressed dir under `~/.rind/store/extracted/<digest>/`.
4. Create overlay mount: lowerdirs are the extracted layer dirs, upperdir is fresh, merged is the rootfs.
5. Write OCI runtime `config.json` (env, command, mounts, namespaces, cgroups settings) into a new bundle dir.
6. Invoke `runc run <id>` with bundle path. Stream stdio.
7. On exit, unmount overlay, optionally clean up bundle.

There is no daemon involved at any step.

### How a `rind build` works

1. Parse `Containerfile` into instruction list.
2. For each FROM stage, resolve the base image (pull if needed).
3. Walk instructions in order. For each:
   - Compute cache key from parent layer + instruction + context hash.
   - If cache hit: reuse layer digest, advance.
   - If miss: spawn a build container from the parent layer, run the instruction inside (for `RUN`), or copy files (for `COPY`/`ADD`), or update config (for `ENV`/`LABEL`/`WORKDIR`/etc.). Capture the diff as a tar, compress, content-address, store.
4. Compose final image config + manifest, write to store, tag with the user's `-t` argument.

Build containers use the same `runc` path as `rind run`. There is no separate build engine.

---

## Feature coverage

### Containerfile instructions supported in MVP

| Instruction | MVP | Notes |
|---|---|---|
| `FROM` | ✅ | Multi-stage supported. `--platform` rejected (single-platform MVP). |
| `RUN` | ✅ | Shell form (`/bin/sh -c`) and exec form (JSON array). |
| `COPY` | ✅ | Local context only. `--from=<stage>` supported. `--chown` supported. |
| `ADD` | ✅ | Local files and tar auto-extraction. URL form not in MVP. |
| `ENV` | ✅ | |
| `ARG` | ✅ | Build-time args, scoped per stage. |
| `LABEL` | ✅ | |
| `WORKDIR` | ✅ | |
| `USER` | ✅ | Numeric and named. |
| `CMD` | ✅ | |
| `ENTRYPOINT` | ✅ | |
| `EXPOSE` | ✅ | Informational only; recorded in image config. |
| `VOLUME` | ✅ | Informational + anonymous volume on `run`. |
| `HEALTHCHECK` | ✅ | Recorded, not enforced at runtime in MVP. |
| `STOPSIGNAL` | ✅ | |
| `SHELL` | ⚠️ | Parsed; only default `["/bin/sh", "-c"]` honored in MVP. |
| `ONBUILD` | ❌ | Deferred to v0.2. |
| `RUN --mount=...` (BuildKit syntax) | ❌ | Deferred. Common cases (cache, bind) on roadmap. |
| Heredoc syntax | ❌ | Deferred. |

### OCI image format support

- Image Manifest v1 (`application/vnd.oci.image.manifest.v1+json`) — read and write
- Docker Image Manifest v2 schema 2 — read; write Docker-compatible only on push to registries that require it
- Image Index / Manifest List — read for platform selection on pull; write only single-platform manifests in MVP
- Layer media types: `tar+gzip`, `tar+zstd`
- Image config — full spec
- Annotations and labels — preserved

### Registry support

- Docker Hub, GHCR, ECR, GAR, Quay, Harbor, generic OCI registries
- Auth: basic, Bearer token (the standard Docker registry token flow)
- Credentials in `~/.rind/auth.json` (Docker-compatible format) or OS keyring
- HTTP/2 client with concurrent layer downloads (configurable concurrency)
- Resume support via Range requests
- No: registry mirrors fallback chain in MVP (single mirror), pull-through cache, signed images (cosign), OCI artifacts beyond images

### Runtime features

- Linux namespaces: pid, mount, net, uts, ipc, user (rootless mode)
- cgroups v2 (cgroups v1 deferred)
- seccomp default profile (Docker-compatible default)
- Capabilities drop (sane defaults)
- Bind mounts (`-v host:container`)
- tmpfs mounts
- Env from `-e` and `--env-file`
- Working directory override
- User override
- Network: host (`--net=host`), none (`--net=none`), bridge (default, simple veth + iptables NAT)
- Port publishing (`-p 8080:80`) — basic iptables rules, IPv4 only in MVP

Not in MVP:
- Compose-style multi-container orchestration (out of scope; that's a different tool)
- User-defined networks beyond bridge/host/none
- IPv6
- macvlan, ipvlan
- Container restart policies
- Health checks at runtime (parsed but not executed)

---

## CLI

Defaults to zero flags for the common case. Mirrors familiar Docker verbs where it doesn't cost much.

```
rind pull <image>                  # pull image into local store
rind build [-t name:tag] <path>    # build from Containerfile in <path>
rind run [opts] <image> [cmd]      # run a container
rind ps                            # list running containers (queries /proc, no daemon needed)
rind images                        # list local images
rind rm <container>                # remove a stopped container's bundle
rind rmi <image>                   # remove a local image
rind push <image>                  # push to registry
rind login <registry>              # store credentials
rind inspect <image|container>     # JSON output
rind logs <container>              # tail captured stdio (if --log-dir was used at run)
rind prune                         # garbage-collect unreferenced blobs
```

Subset of `docker` flags supported on `run`: `-it`, `-d`, `-v`, `-e`, `--env-file`, `-p`, `--name`, `--rm`, `--user`, `--workdir`, `--entrypoint`, `--net`, `--platform` (errors if not host).

### Output

`rind` defaults to terse human output on TTYs and structured output when piped. `--output json` for stable machine output (schema versioned). `RIND_LOG=rind=debug` for diagnostic logging on stderr; never pollutes stdout.

Build progress: per-step status, layer cache hit/miss, size deltas. Inspired by BuildKit's interface but kept simple — no fancy multi-line redraw in MVP.

---

## Integration with miru

miru and rind ship as two binaries but are designed to compose.

In miru's container backend, the Docker/`bollard` path is replaced by spawning `rind` as a subprocess for each operation:

- `rind run` for each step that uses a Linux runner image
- `rind pull` for fetching action images and the runner image
- `rind build` if a workflow declares a custom container image inline (deferred miru feature)

The interface between them is the **stable CLI plus JSON output** (`--output json`). No private IPC, no shared library coupling. This means:

- Either tool can be released independently
- miru users without rind can still use Docker as a backend
- rind users without miru get a useful Docker substitute

A future v0.2 may add a long-running `rind` mode for miru that keeps the image store mmap'd and amortizes some per-call cost — but only if profiling shows the per-call overhead matters. The default remains daemonless.

---

## Storage and security

### What's stored where

| Data | Location |
|---|---|
| Image blobs (layers, configs, manifests) | `~/.rind/store/blobs/sha256/` |
| Local image index | `~/.rind/store/index.json` |
| Build layer cache index | `~/.rind/build-cache/cache.json` |
| Container bundles | `~/.rind/bundles/<id>/` |
| Container overlay dirs | `~/.rind/overlays/<id>/` |
| Registry credentials | `~/.rind/auth.json` (or OS keyring if configured) |
| User config | `~/.rind/config.toml` |

### Security baseline

- Rootless by default — uses user namespaces, sub-uid/sub-gid mappings from `/etc/subuid` and `/etc/subgid`
- Sets up the same default capability drops, seccomp profile, and AppArmor profile (where available) as Docker
- No network listener anywhere — there is no surface to exploit by reaching rind
- TLS verification on by default for registry connections; opt-in `--tls-verify=false` only for local development registries
- Secrets passed via `--env-file` are never written to layer history or image config
- Build args are recorded in image history by default (matching Docker behavior); opt-in `--secret` syntax to pass secrets without recording (deferred to v0.2)
- No telemetry, no auto-update

---

## Performance targets

These are the numbers MVP should hit on a typical Linux laptop or CI runner (Linux x86_64, NVMe, decent network):

| Operation | Target |
|---|---|
| `rind` cold invocation overhead (no work) | < 5ms |
| Container start (image present, simple cmd) | < 80ms (mostly runc) |
| Pull 250MB image, cold cache | network-bound + < 200ms |
| Pull, warm cache (no changes) | < 100ms |
| Build a 5-stage Dockerfile, cold cache | < 1.5× BuildKit |
| Build, warm cache, no changes | < 0.3× BuildKit (skipping cached layers fast) |
| Build, warm cache, change at stage 3 | < 0.5× BuildKit |
| Push 100MB layer to registry | network-bound + < 100ms |

If rind can't beat Docker Engine on cold-invoke + simple-run by 5×+ at MVP, the MVP is not shipped.

---

## Out of scope (explicit non-goals for MVP)

- Compose-style multi-container orchestration
- Kubernetes CRI shim
- Docker Swarm or any clustering
- Windows containers
- macOS containers (Apple Silicon support deferred to v0.2 via Virtualization.framework bridge)
- BuildKit-grade dependency graph parallelism within a build (sequential MVP)
- Multi-platform / cross-arch builds (`docker buildx` semantics)
- Image signing (sigstore / cosign integration)
- OCI artifacts beyond images (Helm charts, etc.)
- Volume drivers beyond local
- Plugin system
- A daemon mode (any version of it)
- Auto-update

These are good ideas. They're not MVP.

---

## Tech stack

- **Language**: Zig (stable)
- **Runtime backend**: shells out to `runc` (default) or `crun` (opt-in via config). No reimplementation in MVP.
- **HTTP**: Zig `std.http` for the registry client; vendored TLS via BearSSL or BoringSSL bindings (the Zig ecosystem here is moving fast; pick the most maintained option at start of work)
- **Compression**: Zig `std.compress.gzip` for gzip, vendored zstd via `libzstd` (C ABI, trivial to link in Zig)
- **Tar**: Zig `std.tar` for read; custom writer for deterministic tar output (important for reproducible layer hashes)
- **JSON**: Zig `std.json`
- **TOML**: pick a small Zig TOML parser, or roll a minimal one for config
- **Hashing**: Zig `std.crypto.hash.sha2` for layer digests
- **Filesystem ops**: Zig `std.fs`, direct `mount(2)` and `unshare(2)` syscalls via `std.os.linux`
- **Build**: `zig build`. Cross-compilation comes for free.

Single artifact: one static binary per `(OS, arch)`. Linux x86_64 and Linux arm64 at launch. No glibc dependency (musl static link or Zig's bundled libc).

---

## Distribution

- GitHub Releases with checksummed static binaries
- `curl -fsSL https://rind.sh/install | sh` install script
- Homebrew tap (`brew install rind`) — even on macOS, where it'll just print "macOS support coming in v0.2" if invoked
- Distro packages (deb/rpm) — best-effort, not gating launch

No Docker image of rind (would be funny but pointless). No npm package.

---

## Roadmap to MVP

Estimated solo timeline. Adjust for available hours per week.

**Milestone 1 — Image store and puller (3 weeks)**
- OCI image layout on disk
- Registry client: Bearer auth, manifest GET, blob GET with concurrency
- Layer extraction
- CLI: `rind pull`, `rind images`, `rind inspect`

**Milestone 2 — Runner (3 weeks)**
- Bundle composition
- Overlay mount setup
- `runc` invocation, stdio plumbing, signal forwarding
- `--rm`, `-v`, `-e`, `--name`, `-it`, `-d`
- CLI: `rind run`, `rind ps`, `rind rm`

**Milestone 3 — Builder (4 weeks)**
- Containerfile parser
- Per-instruction execution via the runner from M2
- Layer caching with content-addressed cache keys
- Multi-stage builds
- CLI: `rind build`

**Milestone 4 — Push, networking, polish (3 weeks)**
- Registry push (manifest, layer upload, retry)
- Bridge networking + port publishing (the most-used `-p` cases)
- Rootless mode hardening
- `rind login`, `rind push`, `rind prune`
- Cross-compile for Linux arm64

**Milestone 5 — miru integration + ship (1 week)**
- JSON output stabilization
- miru backend swap
- Install script, Homebrew tap
- README, landing page at `rind.sh`
- Show HN

Total: roughly 14 weeks of focused solo work.

---

## Launch positioning

**One-liner**: *rind — a daemonless OCI container builder and runtime in Zig. The thin skin around your process.*

**Tagline alternatives**:
- *Containers without a daemon. Builds without BuildKit. A binary.*
- *The minimum that holds a process together.*
- *Docker without the iceberg.*

**Show HN headline**: *Show HN: rind – daemonless container builder and runtime, single static Zig binary*

**Comparison table for the README**:

| | rind | Docker | Podman | Buildah |
|---|---|---|---|---|
| Daemonless | ✅ | ❌ | ✅ | ✅ |
| Single static binary | ✅ | ❌ | ❌ | ❌ |
| Builds OCI images | ✅ | ✅ | ⚠️ (via Buildah) | ✅ |
| Runs containers | ✅ | ✅ | ✅ | ❌ |
| Rootless default | ✅ | ⚠️ | ✅ | ✅ |
| Cold-start overhead | < 5ms | seconds (daemon) | tens of ms | tens of ms |
| Install size | < 10MB | hundreds of MB | tens of MB | tens of MB |
| Linux | ✅ | ✅ | ✅ | ✅ |
| macOS | v0.2 | ✅ (heavy) | ⚠️ (via VM) | ❌ |

---

## Definition of done

The MVP ships when:

1. rind builds, runs, and pushes the author's own real-world images (at least 2 different repos with non-trivial Dockerfiles) end-to-end
2. miru uses rind as its container backend with no observable regression vs the Docker backend on supported workflows
3. All performance targets above are hit
4. Installation works on Linux x86_64 and Linux arm64
5. README has a 60-second getting-started that actually works for a new user
6. There's a clear "what's not supported" doc and a way to file issues

Nothing else gates launch.
