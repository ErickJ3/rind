# libseccomp generated headers — provenance

The libseccomp 2.5.6 release tarball ships pre-generated codegen
artifacts under `<archive>/src/`:

- `arch-x86_64.h`
- `syscalls.h`
- `syscalls.csv`
- `syscalls.perf.c` (gperf output)

`build.zig`'s `cSeccomp` helper points the include path at
`<archive>/src/` directly, so this directory is currently a placeholder.
If a future libseccomp tag drops these pre-generated files, the
codegen will need to be re-run via the upstream tooling and the
outputs committed here.

Upstream codegen (for reference, not run by rind):

```
make -C <archive>/src arch-syscall-validate
python3 <archive>/src/arch-gperf-generate <inputs>
gperf -L ANSI-C -t -E -k '*' src/syscalls.perf > src/syscalls.perf.c
```

Reproduction recipe lands here only if we ever ship a tarball without
pre-generated artifacts.
