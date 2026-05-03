/*
 * Hand-authored config knobs for libcap 2.76 targeting x86_64-linux-musl.
 *
 * libcap is dual-licensed BSD-3-Clause / GPL-2.0-only. rind selects
 * BSD-3-Clause (NOTICE + THIRD_PARTY_LICENSES.md record this choice).
 *
 * libcap does not autoconf — it ships a single Makefile. The header
 * here only carries the version string and feature toggles libcap.h
 * looks for. The cap_names.h codegen step (build _makenames, run it)
 * is wired separately via build.zig — output lands at
 * build/cdeps/cap/generated/cap_names.h on first build.
 */

#ifndef RIND_LIBCAP_CONFIG_H
#define RIND_LIBCAP_CONFIG_H 1

#define VERSION_RELEASE "2.76"
#define LIBCAP_VERSION  "2.76"

/* Linux ≥ 4.3 ships PR_CAP_AMBIENT; Linux ≥ 5.4 ships LIBCAP_HAS_GETPROCATTR
 * via /proc/self/attr/current. Both are present on the kernel floor we
 * already require for runc-equivalent rootless overlay (kernel ≥ 5.11). */
#define LIBCAP_HAS_GETPROCATTR  1
#define LIBCAP_HAS_PR_CAP_AMBIENT 1

#endif /* RIND_LIBCAP_CONFIG_H */
