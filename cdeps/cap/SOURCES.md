# libcap compiled-source list (lazy archive)

`build.zig`'s `cLibcap` helper feeds these files to a static `libcap.a`:

- `libcap/cap_alloc.c`
- `libcap/cap_extint.c`
- `libcap/cap_file.c`
- `libcap/cap_flag.c`
- `libcap/cap_proc.c`
- `libcap/cap_text.c`

Plus a one-off codegen step:

1. Compile `libcap/_makenames.c` → `_makenames` (needs `<linux/capability.h>` from kernel UAPI).
2. Run `_makenames > cdeps/cap/generated/cap_names.h`.
3. Re-run on `linux/capability.h` change.

License: BSD-3-Clause (selected from libcap's BSD/GPL dual-license offer).
See `vendor/.../libcap-2.76/License` in the lazy archive.
