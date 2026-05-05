#!/usr/bin/env bash
# Read-only: list local images.
source "$(dirname "$0")/../lib.sh"

LABEL="images"
HEADING="images"
DESC="List local images (read-only)."

cmds=()
add_rind_cmd   cmds "images"
add_podman_cmd cmds "images"
add_docker_cmd cmds "images"

run_poop "$LABEL" "${cmds[@]}"
emit_scenario_block "$HEADING" "$DESC" "$POOP_OUTPUT_FILE"
