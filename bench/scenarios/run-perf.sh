#!/usr/bin/env bash
# perf-stat baseline for `rind run --rm <alpine> /bin/true`.
# Captures context-switches, instructions, cycles, page-faults, task-clock
# averaged over $RUNS iterations. Writes a markdown table next to other
# scenario outputs.
source "$(dirname "$0")/../lib.sh"

LABEL="run-perf"
HEADING="run startup (perf stat)"
DESC="rind run --rm $ALPINE /bin/true — perf stat over RUNS iterations. Tracks context-switches, instructions, cycles, page-faults, task-clock."

if ! command -v perf >/dev/null 2>&1; then
    warn "perf not on PATH — skipping run-perf scenario"
    exit 0
fi

RUNS="${RIND_PERF_RUNS:-30}"

raw_dir="$BENCH_DIR/results/.raw"
mkdir -p "$raw_dir"
raw="$raw_dir/$LABEL.txt"
: > "$raw"

log "perf stat -r $RUNS rind run --rm $ALPINE /bin/true"
perf stat -r "$RUNS" \
    -e context-switches,instructions,cycles,page-faults,task-clock \
    -o "$raw" --append \
    "$RIND_BIN" run --rm "$ALPINE" /bin/true >/dev/null 2>&1 || \
    warn "perf stat reported a non-zero exit — see $raw"

out="$BENCH_DIR/results/latest.md"
{
    echo ""
    echo "## $HEADING"
    echo ""
    echo "$DESC"
    echo ""
    echo "<details><summary>raw perf stat output ($RUNS runs)</summary>"
    echo ""
    echo '```'
    cat "$raw"
    echo '```'
    echo ""
    echo "</details>"
} >> "$out"

ok "run-perf written to $raw"
