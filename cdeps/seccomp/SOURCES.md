# libseccomp compiled-source list (lazy archive)

`build.zig`'s `cSeccomp` helper feeds these `<libseccomp>/src/*.c` files
to a static `libseccomp.a`. The lazy `libseccomp` zon dep resolves the
upstream tarball hash — sources arrive on first `zig build`.

- `src/api.c`
- `src/arch.c`
- `src/arch-x86_64.c`         (the only arch we compile; rind targets x86_64-linux-musl)
- `src/db.c`
- `src/gen_bpf.c`
- `src/gen_pfc.c`
- `src/hash.c`
- `src/helper.c`
- `src/syscalls.c`
- `src/system.c`

The release tarball ships pre-generated `arch-x86_64.h`, `syscalls.h`,
`syscalls.csv`, and `syscalls.perf.c`. No Python/gperf codegen runs.

The audit script's BLOCKER check matches against this file.
