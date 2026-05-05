#!/usr/bin/env bash
# Warm-cache pull: image already present, measures manifest re-validation +
# blob existence checks + store walk. Target: <100ms.

source "$(dirname "$0")/../lib.sh"

LABEL="pull-warm"
HEADING="pull $ALPINE (warm cache)"
DESC="Image pre-pulled on every runtime, measures warm path (manifest re-validate, blob existence). Target: <100ms warm."

# Make sure caches are warm.
pre_pull_alpine

cmds=()
add_rind_cmd   cmds "pull $ALPINE"
add_podman_cmd cmds "pull $ALPINE"
add_docker_cmd cmds "pull $ALPINE"

run_poop "$LABEL" --duration 3000 "${cmds[@]}"
emit_scenario_block "$HEADING" "$DESC" "$POOP_OUTPUT_FILE"
