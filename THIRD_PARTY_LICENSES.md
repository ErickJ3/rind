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

| Component | Version / tag | Source URL | zon hash |
|---|---|---|---|
| libcrun | 1.23 | https://github.com/containers/crun/releases/tag/1.23 | _vendored in-tree at `vendor/crun-1.23/` (Zig 0.16 fetch rejects upstream tarball's hard-link entries inside `libocispec/yajl/`)_ |
| libseccomp | 2.5.6 | https://github.com/seccomp/libseccomp/releases/tag/v2.5.6 | `N-V-__8AADNXLABn1IPkz6WrmHcLR77iYxDEugG_cBs5lRGK` |
| libcap | 2.76 | https://git.kernel.org/pub/scm/libs/libcap/libcap.git/tag/?h=libcap-2.76 | `N-V-__8AADRrDADBj_5tSn-s-P6fgY7lp3bsUq-cB-ev24An` |
| argp-standalone | 1.5.0 | https://github.com/argp-standalone/argp-standalone/releases/tag/1.5.0 | `N-V-__8AABTDAwBuawEWBE-P-NIkZF5T4pwX9tRHsf0rRCkO` |
| yajl (embedded) | shipped under `vendor/crun-1.23/libocispec/yajl/` | https://github.com/lloyd/yajl | n/a — embedded |
| BLAKE3 (embedded) | shipped under `vendor/crun-1.23/src/blake3/` | https://github.com/BLAKE3-team/BLAKE3 | n/a — embedded |
| musl libc | bundled by Zig 0.16.0 | https://musl.libc.org/ | n/a — toolchain |

The libseccomp / libcap / argp-standalone hashes are produced by
`zig fetch <url>` and pinned in `build.zig.zon` with `lazy = true`. The
libcrun snapshot lives in-tree because Zig 0.16's tar reader refuses
type-1 (hard-link) entries that the upstream release tarball uses
inside `libocispec/yajl/`. When that limitation lifts, libcrun can be
moved back onto the lazy archive path without further audit work — the
content is bit-identical to the tagged release tarball.

## Per-file LGPL audit (libcrun)

`scripts/lgpl_audit.sh` walks `vendor/crun-1.23/src/` and reads the
SPDX header (or, when missing, the comment block) of every `*.c` /
`*.h` file. Re-run via `bash scripts/lgpl_audit.sh
vendor/crun-1.23/src` and paste the table below in full when the
vendored libcrun tag changes.

The CLI half (`vendor/crun-1.23/src/{crun,run,create,…}.c`) is **not**
vendored at all; only the library half (`src/libcrun/` content) sits
under `vendor/crun-1.23/src/` and is audited here. Compiled translation
units are listed in `build/cdeps/crun/SOURCES.md`; the audit script's
BLOCKER check is keyed off that file.

Audit run on libcrun 1.23 (no GPL-only files found; audit script exit 0):

| File | Declared license | Action |
|---|---|---|
| blake3/blake3.c | upstream BLAKE3 (CC0-1.0 OR Apache-2.0) | linked |
| blake3/blake3.h | upstream BLAKE3 (CC0-1.0 OR Apache-2.0) | linked |
| blake3/blake3_impl.h | upstream BLAKE3 (CC0-1.0 OR Apache-2.0) | linked |
| blake3/blake3_portable.c | upstream BLAKE3 (CC0-1.0 OR Apache-2.0) | linked |
| cgroup-cgroupfs.c | LGPL-2.1 (from comment) | linked |
| cgroup-cgroupfs.h | LGPL-2.1 (from comment) | linked |
| cgroup-internal.h | LGPL-2.1 (from comment) | linked |
| cgroup-resources.c | LGPL-2.1 (from comment) | linked |
| cgroup-resources.h | LGPL-2.1 (from comment) | linked |
| cgroup-setup.c | LGPL-2.1 (from comment) | linked |
| cgroup-setup.h | LGPL-2.1 (from comment) | linked |
| cgroup-systemd.c | LGPL-2.1 (from comment) | linked (`HAVE_SYSTEMD=0`) |
| cgroup-systemd.h | LGPL-2.1 (from comment) | linked |
| cgroup-utils.c | LGPL-2.1 (from comment) | linked |
| cgroup-utils.h | LGPL-2.1 (from comment) | linked |
| cgroup.c | LGPL-2.1 (from comment) | linked |
| cgroup.h | LGPL-2.1 (from comment) | linked |
| chroot_realpath.c | LGPL-2.1 (from comment) | linked |
| cloned_binary.c | Apache-2.0 OR LGPL-2.1-or-later | linked |
| container.c | LGPL-2.1 (from comment) | linked |
| container.h | LGPL-2.1 (from comment) | linked |
| criu.c | LGPL-2.1 (from comment) | linked (`HAVE_CRIU=0`) |
| criu.h | LGPL-2.1 (from comment) | linked |
| custom-handler.c | LGPL-2.1 (from comment) | linked |
| custom-handler.h | LGPL-2.1 (from comment) | linked |
| ebpf.c | LGPL-2.1 (from comment) | linked |
| ebpf.h | LGPL-2.1 (from comment) | linked |
| error.c | LGPL-2.1 (from comment) | linked |
| error.h | LGPL-2.1 (from comment) | linked |
| handlers/handler-utils.c | LGPL-2.1 (from comment) | linked |
| handlers/handler-utils.h | LGPL-2.1 (from comment) | linked |
| handlers/krun.c | LGPL-2.1 (from comment) | linked (`HAVE_LIBKRUN=0`) |
| handlers/mono.c | LGPL-2.1 (from comment) | linked (`HAVE_MONO=0`) |
| handlers/spin.c | LGPL-2.1 (from comment) | linked (`HAVE_SPIN=0`) |
| handlers/wamr.c | LGPL-2.1 (from comment) | linked (`HAVE_WAMR=0`) |
| handlers/wasmedge.c | LGPL-2.1 (from comment) | linked (`HAVE_WASMEDGE=0`) |
| handlers/wasmer.c | LGPL-2.1 (from comment) | linked (`HAVE_WASMER=0`) |
| handlers/wasmtime.c | LGPL-2.1 (from comment) | linked (`HAVE_WASMTIME=0`) |
| intelrdt.c | LGPL-2.1 (from comment) | linked |
| intelrdt.h | LGPL-2.1 (from comment) | linked |
| io_priority.c | LGPL-2.1 (from comment) | linked |
| io_priority.h | LGPL-2.1 (from comment) | linked |
| linux.c | LGPL-2.1 (from comment) | linked |
| linux.h | LGPL-2.1 (from comment) | linked |
| mount_flags.c | gperf output (LGPL-2.1 inherited from `mount_flags.perf`) | linked |
| mount_flags.h | LGPL-2.1 (from comment) | linked |
| net_device.c | LGPL-2.1 (from comment) | linked |
| net_device.h | LGPL-2.1 (from comment) | linked |
| ring_buffer.c | LGPL-2.1 (from comment) | linked |
| ring_buffer.h | LGPL-2.1 (from comment) | linked |
| scheduler.c | LGPL-2.1 (from comment) | linked |
| scheduler.h | LGPL-2.1 (from comment) | linked |
| seccomp.c | LGPL-2.1 (from comment) | linked |
| seccomp.h | LGPL-2.1 (from comment) | linked |
| seccomp_notify.c | LGPL-2.1 (from comment) | linked |
| seccomp_notify.h | LGPL-2.1 (from comment) | linked |
| seccomp_notify_plugin.h | LGPL-2.1 (from comment) | linked |
| signals.c | gperf output (LGPL-2.1 inherited from `signals.perf`) | linked |
| status.c | LGPL-2.1 (from comment) | linked |
| status.h | LGPL-2.1 (from comment) | linked |
| string_map.c | LGPL-2.1 (from comment) | linked |
| string_map.h | LGPL-2.1 (from comment) | linked |
| terminal.c | LGPL-2.1 (from comment) | linked |
| terminal.h | LGPL-2.1 (from comment) | linked |
| utils.c | LGPL-2.1 (from comment) | linked |
| utils.h | LGPL-2.1 (from comment) | linked |

Net result: every linked translation unit is LGPL-2.1 (or
LGPL-2.1-compatible: Apache-2.0, BLAKE3 dual). No GPL-only files were
found inside the vendored library half. The escape-hatch pivot to
youki described earlier is **not** triggered.

## Full license texts

Full upstream license texts (LGPL-2.1, BSD-3-Clause, ISC, MIT) are
included in release tarballs under `licenses/`. Source-only checkouts
can fetch them from each component's upstream repository at the pinned
revision.
