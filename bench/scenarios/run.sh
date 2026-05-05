#!/usr/bin/env bash
# Flagship scenario: container start latency. Targets <80ms.
# Uses /bin/true to isolate startup cost (no stdio).

source "$(dirname "$0")/../lib.sh"

LABEL="run"
HEADING="run --rm $ALPINE /bin/true"
DESC="Container start + run + teardown round-trip. Target: <80ms"

cmds=()
add_rind_cmd   cmds "run --rm $ALPINE /bin/true"
add_podman_cmd cmds "run --rm $ALPINE /bin/true"
add_docker_cmd cmds "run --rm $ALPINE /bin/true"

# Warmup: one run per runtime to populate page cache.
log "warmup"
for c in "${cmds[@]}"; do
    eval "$c" >/dev/null 2>&1 || warn "warmup failed: $c"
done

run_poop "$LABEL" --duration 5000 "${cmds[@]}"
emit_scenario_block "$HEADING" "$DESC" "$POOP_OUTPUT_FILE"
