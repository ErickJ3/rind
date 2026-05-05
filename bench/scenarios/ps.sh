#!/usr/bin/env bash
# ps -a: read-only listing. Pre-creates 5 stopped containers per runtime so
# the /proc reconcile path in src/cli/ps.zig:129 has real state to walk.

source "$(dirname "$0")/../lib.sh"

LABEL="ps"
HEADING="ps -a"
DESC="List containers (5 stopped pre-created per runtime). Exercises /proc reconcile (src/cli/ps.zig:129)."

PREFIX="bench-ps-"

setup() {
    log "creating 5 stopped containers per runtime"
    for i in 1 2 3 4 5; do
        "$RIND_BIN" run --name "${PREFIX}rind-$i" "$ALPINE" /bin/true >/dev/null 2>&1 || warn "rind setup $i failed"
        if have_podman; then
            podman run --name "${PREFIX}pod-$i" "$ALPINE" /bin/true >/dev/null 2>&1 || warn "podman setup $i failed"
        fi
        if have_docker; then
            docker run --name "${PREFIX}docker-$i" "$ALPINE" /bin/true >/dev/null 2>&1 || warn "docker setup $i failed"
        fi
    done
}

teardown() {
    log "tearing down ps fixtures"
    for i in 1 2 3 4 5; do
        "$RIND_BIN" rm -f "${PREFIX}rind-$i" >/dev/null 2>&1 || true
    done
    cleanup_named_containers "$PREFIX"
}

trap teardown EXIT
setup

cmds=()
add_rind_cmd   cmds "ps -a"
add_podman_cmd cmds "ps -a"
add_docker_cmd cmds "ps -a"

run_poop "$LABEL" "${cmds[@]}"
emit_scenario_block "$HEADING" "$DESC" "$POOP_OUTPUT_FILE"
