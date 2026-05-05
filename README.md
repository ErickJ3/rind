# rind

A container runtime that runs OCI images without a daemon. One static binary; state lives in `~/.rind/` and there's no background process.

It's for Linux machines where you want `docker pull` and `docker run` semantics but don't want Docker Desktop.

## Status

Shipped: `pull`, `images`, `inspect`, `run`, `ps`, `rm`. Works against Docker Hub, GHCR, and other OCI v2 registries. Linux x86_64 only. `build` and `push` are coming. Expect breakage on `main` until 1.0.

## Building

Needs Zig 0.16.0. libcrun, libseccomp, libcap, and zlib-ng are vendored or fetched by the build script.

```sh
zig build                              # debug build at zig-out/bin/rind
zig build -Doptimize=ReleaseFast       # release binary
zig build test                         # unit tests
```

A `justfile` has shortcuts: `just build`, `just test`, `just release`, `just bench`.

## Usage

```sh
rind pull alpine:3.19
rind run --rm alpine:3.19 echo hello
rind ps -a
rind images
```

`rind --help` for the rest.

## License

Apache-2.0. See [LICENSE](LICENSE).
