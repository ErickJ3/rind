/*
 * Hand-authored config.h for argp-standalone 1.5.0 targeting
 * x86_64-linux-musl. Mirrors argp-standalone's acconfig.h plus the
 * AC_CHECK_HEADERS / AC_CHECK_FUNCS surface from configure.ac.
 *
 * argp is part of glibc but absent from musl. argp-standalone is a
 * portable extraction. rind statically links it after libcrun on the
 * link line so libcrun's argp_parse references resolve here.
 */

#ifndef RIND_ARGP_STANDALONE_CONFIG_H
#define RIND_ARGP_STANDALONE_CONFIG_H 1

#define PACKAGE         "argp-standalone"
#define PACKAGE_NAME    "argp-standalone"
#define PACKAGE_VERSION "1.5.0"
#define VERSION         "standalone-1.5.0"
#define STDC_HEADERS    1

/* Standard headers — present in musl. */
#define HAVE_LIMITS_H   1
#define HAVE_UNISTD_H   1
#define HAVE_LIBINTL_H  0   /* musl skips libintl by default */
#define HAVE_MALLOC_H   1

/* program_invocation_name / _short_name are glibc-only globals.
 * argp-standalone substitutes its own when these are not present. */
#define HAVE_PROGRAM_INVOCATION_NAME       0
#define HAVE_PROGRAM_INVOCATION_SHORT_NAME 0

/* Function checks. */
#define HAVE_STRERROR    1
#define HAVE_VPRINTF     1
#define HAVE_DECL_VASPRINTF 1
#define HAVE_DECL_FPUTS_UNLOCKED 0  /* musl lacks fputs_unlocked */
#define HAVE_DECL_PUTC_UNLOCKED 0

/* AC_REPLACE_FUNCS — musl provides all three. */
#define HAVE_MEMPCPY     1
#define HAVE_STRNDUP     1
#define HAVE_STRCHRNUL   1

/* GCC attribute checks. */
#define HAVE_GCC_ATTRIBUTE_PURE      1
#define HAVE_GCC_ATTRIBUTE_FORMAT    1

#endif /* RIND_ARGP_STANDALONE_CONFIG_H */
