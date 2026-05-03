# argp-standalone compiled-source list (lazy archive)

`build.zig`'s `cArgpStandalone` helper feeds these files to a static
`libargp_standalone.a`:

- `argp-ba.c`
- `argp-eexst.c`
- `argp-fmtstream.c`
- `argp-help.c`
- `argp-parse.c`
- `argp-pv.c`
- `argp-pvh.c`

Replacement functions (musl provides upstream, but argp ships fallbacks):

- `mempcpy.c`     — skipped (`HAVE_MEMPCPY=1`)
- `strndup.c`     — skipped (`HAVE_STRNDUP=1`)
- `strchrnul.c`   — skipped (`HAVE_STRCHRNUL=1`)

License: LGPL-2.1-or-later (inherited from glibc's argp).
