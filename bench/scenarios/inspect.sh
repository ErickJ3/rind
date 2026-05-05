#!/usr/bin/env bash
# Read-only: dump image config JSON.
source "$(dirname "$0")/../lib.sh"

LABEL="inspect"
HEADING="inspect $ALPINE"
DESC="Dump image config JSON for a single local image (read-only)."

cmds=()
add_rind_cmd   cmds "inspect $ALPINE"
add_podman_cmd cmds "inspect $ALPINE"
add_docker_cmd cmds "inspect $ALPINE"

run_poop "$LABEL" "${cmds[@]}"
emit_scenario_block "$HEADING" "$DESC" "$POOP_OUTPUT_FILE"
