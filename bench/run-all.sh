#!/usr/bin/env bash
# rind benchmark driver. Builds release binary, pre-pulls images, runs every
# scenario in dependency order, writes bench/results/latest.md.
#
# Flags:
#   --skip a,b,c    skip listed scenarios (csv)
#   --only a,b      only run listed scenarios (csv; overrides --skip)
#   --no-build      skip the zig build step (use existing binary)
#   --cleanup-docker  prune docker/podman after run (off by default; would trash dev images)

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BENCH_DIR/lib.sh"

SKIP=""
ONLY=""
NO_BUILD=0
CLEANUP_DOCKER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip)         SKIP="$2"; shift 2 ;;
        --only)         ONLY="$2"; shift 2 ;;
        --no-build)     NO_BUILD=1; shift ;;
        --cleanup-docker) CLEANUP_DOCKER=1; shift ;;
        -h|--help)
            sed -n '2,11p' "$0"; exit 0 ;;
        *) fatal "unknown flag: $1" ;;
    esac
done

# Default scenario order — pull-cold last, it nukes the store.
SCENARIOS=(pull-warm images inspect run run-perf ps rm pull-cold)

want() {
    local s="$1"
    if [[ -n "$ONLY" ]]; then
        [[ ",$ONLY," == *",$s,"* ]]
    else
        [[ ",$SKIP," != *",$s,"* ]]
    fi
}

require_poop
require zig
require git

if [[ $NO_BUILD -eq 0 ]]; then
    build_release
else
    [[ -x "$RIND_BIN" ]] || fatal "no binary at $RIND_BIN (--no-build given)"
    ensure_stripped "$RIND_BIN"
fi

pre_pull_alpine
init_results

# Snapshot the doc preamble so individual scenarios can append cleanly.
ok "scenarios: ${SCENARIOS[*]}"
echo "" >> "$BENCH_DIR/results/latest.md"
echo "## scenarios" >> "$BENCH_DIR/results/latest.md"

for s in "${SCENARIOS[@]}"; do
    if want "$s"; then
        log "=== $s ==="
        bash "$BENCH_DIR/scenarios/$s.sh" || warn "scenario $s failed"
    else
        log "(skip $s)"
    fi
done

# Final cleanup: any bench-* containers we may have leaked.
log "final cleanup"
"$RIND_BIN" ps -a -q 2>/dev/null | while read -r id; do
    [[ -n "$id" ]] && "$RIND_BIN" rm -f "$id" >/dev/null 2>&1 || true
done || true
cleanup_named_containers "bench-"

if [[ $CLEANUP_DOCKER -eq 1 ]]; then
    have_docker && docker system prune -f >/dev/null 2>&1 || true
    have_podman && podman system prune -f >/dev/null 2>&1 || true
fi

ok "results written to $BENCH_DIR/results/latest.md"
