#!/usr/bin/env bash
# Cold-cache pull: rind only (network variance + daemon-side caches make 3-way unfair).
# Outer-loop, 3 iters. Wipes RIND_ROOT_TMP between iters. Captures --timing breakdown.

source "$(dirname "$0")/../lib.sh"

LABEL="pull-cold"
HEADING="pull $ALPINE (cold cache, rind only)"
DESC="Network + handshake + extract. RIND_ROOT wiped between iters; 3 iters (network variance dominates). Phase breakdown via rind --timing flag."

N=3
TMPROOT="$(mktemp -d -t rind-bench-pull-XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

RAW="$BENCH_DIR/results/.raw/pull-cold-rind.txt"
TIMING_LOG="$BENCH_DIR/results/.raw/pull-cold-timing.txt"
mkdir -p "$(dirname "$RAW")"
: > "$RAW"
: > "$TIMING_LOG"

log "rind cold pull × $N (RIND_ROOT=$TMPROOT, wiped each iter)"
for i in $(seq 1 $N); do
    rm -rf "$TMPROOT"
    mkdir -p "$TMPROOT"
    # Capture wall + --timing phase split.
    {
        echo "--- iter $i ---"
        env RIND_ROOT="$TMPROOT" "$RIND_BIN" pull --timing "$ALPINE" 2>&1 | tail -20
    } >> "$TIMING_LOG"
    t=$( { /usr/bin/time -f '%e' env RIND_ROOT="$TMPROOT" "$RIND_BIN" pull "$ALPINE" >/dev/null 2>&3; } 3>&2 2>&1 ) || { warn "iter $i failed"; continue; }
    rm -rf "$TMPROOT"
    mkdir -p "$TMPROOT"
    echo "$t" >> "$RAW"
done

emit_outer_block "$HEADING" "$DESC" "rind=$RAW"

{
    echo ""
    echo "<details><summary>rind pull --timing phase breakdown (per iter)</summary>"
    echo ""
    echo '```'
    cat "$TIMING_LOG"
    echo '```'
    echo ""
    echo "</details>"
} >> "$BENCH_DIR/results/latest.md"
