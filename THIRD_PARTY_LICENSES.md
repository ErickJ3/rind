# Third-party licenses

The shipped `rind` binary is statically linked against the C libraries
listed below. rind's own source is Apache-2.0 (see `LICENSE`); this
file collects the upstream license texts and pinned versions for the
embedded code.

LGPL-2.1 §6 permits this static-link arrangement provided that an end
user can rebuild the combined binary against a modified version of the
LGPL component. rind satisfies §6(b) by:

1. Publishing source for rind, the pinned libcrun snapshot, and every
   LGPL transitive dep in this repository (or via pinned `build.zig.zon`
   archives).
2. Shipping the `zig build` recipe (`build.zig`) that links them
   together.
3. Bundling this `THIRD_PARTY_LICENSES.md` and the upstream
   `COPYING.libcrun` (LGPL-2.1) text alongside every release tarball.

## Pinned versions

| Component | Version / commit | Source URL |
|---|---|---|
| libcrun | _to be pinned in T17_ | https://github.com/containers/crun |
| libseccomp | _to be pinned in T17_ | https://github.com/seccomp/libseccomp |
| libcap | _to be pinned in T17_ | https://git.kernel.org/pub/scm/libs/libcap/libcap.git |
| yajl (or libcrun's embedded copy) | _to be pinned in T17_ | https://github.com/lloyd/yajl |
| argp-standalone | _to be pinned in T17_ | https://www.lysator.liu.se/~nisse/misc/ |
| musl libc | bundled by Zig 0.16.0 | https://musl.libc.org/ |

T17 fills in the exact tags / commits / SHA-256 archive hashes when the
build wiring lands, and updates the per-file LGPL audit notes below.

## Per-file LGPL audit (libcrun)

T17 is responsible for sweeping `vendor/crun/src/libcrun/*.{c,h}` and
recording any file whose header declares a license other than
LGPL-2.1-or-later (in particular GPL-2.0-only). Files outside
`src/libcrun/` (the CLI half under `src/` and any utilities) are not
linked into the rind binary.

Audit results land here:

| File | Declared license | Action |
|---|---|---|
| _populated by T17_ | | |

If any LGPL-incompatible files are discovered inside `src/libcrun/`,
T17 either patches them out via the libcrun build system or, failing
that, blocks libcrun adoption and triggers the youki-as-alternative
plan note recorded in the M2 plan file.

## Full license texts

Full upstream license texts (LGPL-2.1, BSD-3-Clause, ISC, MIT) are
included in release tarballs under `licenses/`. Source-only checkouts
can fetch them from each component's upstream repository at the pinned
revision.
