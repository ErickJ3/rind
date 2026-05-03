/*
 * Hand-authored configure.h for libseccomp 2.5.6 targeting
 * x86_64-linux-musl. Mirrors libseccomp's autoconf surface
 * (configure.h.in / configure.ac in the lazy tarball).
 *
 * The release tarball ships pre-generated arch-x86_64.h, syscalls.h,
 * syscalls.csv, and syscalls.perf.c, so no Python/gperf codegen is
 * needed at build time. Include path
 * `<libseccomp_root>/src/` resolves them.
 */

#ifndef RIND_LIBSECCOMP_CONFIGURE_H
#define RIND_LIBSECCOMP_CONFIGURE_H 1

#define VERSION_RELEASE "2.5.6"

#define HAVE_DLFCN_H        1
#define HAVE_INTTYPES_H     1
#define HAVE_LINUX_SECCOMP_H 1
#define HAVE_STDINT_H       1
#define HAVE_STDIO_H        1
#define HAVE_STDLIB_H       1
#define HAVE_STRINGS_H      1
#define HAVE_STRING_H       1
#define HAVE_SYS_STAT_H     1
#define HAVE_SYS_TYPES_H    1
#define HAVE_UNISTD_H       1
#define STDC_HEADERS        1

/* Python bindings deliberately disabled. */
#define ENABLE_PYTHON 0

#endif /* RIND_LIBSECCOMP_CONFIGURE_H */
