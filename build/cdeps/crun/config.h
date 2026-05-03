/*
 * Hand-authored config.h for libcrun targeting x86_64-linux-musl.
 * Mirrors the autoconf surface from vendor/crun-1.23/config.h.in.
 *
 * Source of truth for HAVE_* values: vendor/crun-1.23/configure.ac
 * (AC_CHECK_FUNCS / AC_CHECK_HEADERS / AC_CHECK_DECLS) cross-checked
 * against Zig 0.16.0's bundled musl headers under
 * /home/redshit/.zvm/0.16.0/lib/libc/musl/include.
 *
 * Knobs flipped per T17 spec:
 *   --enable-embedded-yajl   → HAVE_YAJL 1 (yajl built from libocispec/yajl/)
 *   --disable-systemd        → HAVE_SYSTEMD 0
 *   --disable-criu           → HAVE_CRIU 0
 *   --disable-dl             → HAVE_DLOPEN 0; SHARED_LIBCRUN 0; DYNLOAD_LIBCRUN 0
 *   --disable-shared         → SHARED_LIBCRUN 0
 *   --enable-static          → linkage handled in build.zig
 */

#ifndef RIND_LIBCRUN_CONFIG_H
#define RIND_LIBCRUN_CONFIG_H 1

#define PACKAGE         "crun"
#define PACKAGE_NAME    "crun"
#define PACKAGE_TARNAME "crun"
#define PACKAGE_VERSION "1.23"
#define PACKAGE_STRING  "crun 1.23"
#define PACKAGE_BUGREPORT ""
#define PACKAGE_URL     ""
#define VERSION         "1.23"

#define LT_OBJDIR ".libs/"
#define STDC_HEADERS 1

/* Standard headers — all present in musl. */
#define HAVE_DLFCN_H     1
#define HAVE_INTTYPES_H  1
#define HAVE_MEMORY_H    1
#define HAVE_STDINT_H    1
#define HAVE_STDLIB_H    1
#define HAVE_STRING_H    1
#define HAVE_STRINGS_H   1
#define HAVE_SYS_STAT_H  1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H    1
#define HAVE_STDATOMIC_H 1
#define HAVE_ATOMIC_INT  1

/* Platform headers we provide via vendored libs / kernel UAPI. */
#define HAVE_SYS_CAPABILITY_H 1   /* libcap */
#define HAVE_SECCOMP_H        1   /* libseccomp */
#define HAVE_LINUX_BPF_H      1   /* kernel UAPI */
#define HAVE_LINUX_OPENAT2_H  1   /* kernel ≥ 5.6 */
#define HAVE_LINUX_IOPRIO_H   1
/* error.h is a glibc-only header; libcrun does not include it under our
 * compiled set. Leave undefined. */
#define HAVE_ERROR_H          0

/* Function checks. */
#define HAVE_EACCESS          1
#define HAVE_HSEARCH_R        1
#define HAVE_COPY_FILE_RANGE  1
#define HAVE_FGETXATTR        1
#define HAVE_STATX            1
#define HAVE_FGETPWENT_R      0   /* glibc extension; musl lacks it */
#define HAVE_ISSETUGID        1   /* musl provides it */
#define HAVE_MEMFD_CREATE     1
#define HAVE_LOG2             1
#define HAVE_SD_NOTIFY_BARRIER 0  /* no systemd */

/* mount API: musl exposes FSCONFIG_CMD_CREATE via linux/mount.h, not sys/mount.h. */
#define HAVE_FSCONFIG_CMD_CREATE_LINUX_MOUNT_H 1
/* HAVE_FSCONFIG_CMD_CREATE_SYS_MOUNT_H — leave undefined */

/* Feature toggles. */
#define HAVE_YAJL                    1
#define HAVE_CAP                     1
#define HAVE_SECCOMP                 1
#define SECCOMP_ARCH_RESOLVE_NAME    1
#define HAVE_SECCOMP_GET_NOTIF_SIZES 1
#define HAVE_EBPF                    1

/* Disabled feature toggles — explicitly 0 so #if HAVE_X compiles. */
#define HAVE_DLOPEN     0
#define HAVE_SYSTEMD    0
#define HAVE_CRIU       0
#define CRIU_JOIN_NS_SUPPORT       0
#define CRIU_PRE_DUMP_SUPPORT      0
#define CRIU_NETWORK_LOCK_SKIP_SUPPORT 0
#define HAVE_LIBKRUN    0
#define HAVE_MONO       0
#define HAVE_WASMER     0
#define HAVE_WASMTIME   0
#define HAVE_WASMEDGE   0
#define HAVE_WAMR       0
#define HAVE_SPIN       0

/* Linkage. */
#define SHARED_LIBCRUN  0
#define DYNLOAD_LIBCRUN 0
#define LIBCRUN_PUBLIC  __attribute__((visibility("default")))

#endif /* RIND_LIBCRUN_CONFIG_H */
