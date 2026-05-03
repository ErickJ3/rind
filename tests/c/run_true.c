/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * T17 integration test — drive libcrun_container_run() against a
 * hand-built bundle that runs /bin/true. argv[1] is the absolute
 * path to the bundle directory.
 *
 * Exits 0 on success; non-zero codes are diagnostic (see returns
 * below). The acceptance criterion is exit 0; any other code is a
 * test failure.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* container.h + error.h live at vendor/crun-1.23/src/ in our build;
 * no `libcrun/` prefix because we don't use libcrun's installed
 * include layout. The Zig wrapper in T18 follows the same convention. */
#include "container.h"
#include "error.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <bundle-dir>\n", argv[0]);
        return 2;
    }

    /* libcrun_container_load_from_file resolves "config.json" relative
     * to cwd; the OCI runtime convention is to chdir to the bundle
     * before loading. */
    if (chdir(argv[1]) != 0) {
        perror("chdir");
        return 5;
    }

    libcrun_context_t ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.id                = "rind-t17-true";
    ctx.state_root        = "/tmp/rind-t17-state";
    ctx.bundle            = argv[1];
    ctx.fifo_exec_wait_fd = -1;
    ctx.preserve_fds      = 0;

    libcrun_error_t err = NULL;
    libcrun_container_t *cont =
        libcrun_container_load_from_file("config.json", &err);
    if (cont == NULL) {
        fprintf(stderr, "load: %s\n", err ? err->msg : "(null)");
        if (err) libcrun_error_release(&err);
        return 3;
    }

    int rc = libcrun_container_run(&ctx, cont, 0, &err);
    if (rc != 0) {
        fprintf(stderr, "run: rc=%d msg=%s\n",
                rc, err ? err->msg : "(null)");
        if (err) libcrun_error_release(&err);
        return 4;
    }

    /* libcrun_container_run returns the container's exit code; for
     * /bin/true that is 0, which is the test's success path. */
    return 0;
}
