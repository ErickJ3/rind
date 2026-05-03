/*
 * Stub git-version.h for libcrun 1.23 vendored at vendor/crun-1.23/.
 *
 * Upstream's autoconf wrapper writes this file from `git describe`
 * output. We're statically vendored to a tagged release (1.23), so
 * we hard-code the commit string. Used only by container.c at line
 * 4401 to populate the OCI annotation
 * `run.oci.crun.commit`.
 */

#ifndef RIND_LIBCRUN_GIT_VERSION_H
#define RIND_LIBCRUN_GIT_VERSION_H 1

#define GIT_VERSION "1.23-vendored"

#endif /* RIND_LIBCRUN_GIT_VERSION_H */
