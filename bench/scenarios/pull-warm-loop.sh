#!/usr/bin/env bash
# Warm-cache pull, repeated. Measures the manifest-cache fast path:
# a fresh entry should skip the network entirely and complete in
# < 100 ms (docs/rind.md:271 target).
#
# Runs 10 timed iterations of `rind pull` against an already-pulled
# image and reports p50/p95/p99 alongside mean/stddev. Tail latency
# is the relevant signal because the slow case (cache miss) dominates
# the mean even when most iterations are fast.

source "$(dirname "$0")/../lib.sh"

LABEL="pull-warm-loop"
HEADING="pull $ALPINE (warm cache, 10x loop, p50/p95/p99)"
DESC="Image pre-pulled, cache primed, then 10 timed iterations of \`rind pull\`. Tracks the manifest-cache fast path; target p50 < 100 ms."

ITERS="${RIND_BENCH_ITERS:-10}"

# Prime the cache with a single pull before timing. Without this, the
# first iteration would always be a cache miss and skew p99.
pre_pull_alpine

setup_noop() { :; }

teardown_noop() { :; }

timed_loop() {
    local out="$1" runtime="$2" cmd="$3"
    : > "$out"
    log "outer-loop: $LABEL $runtime ($ITERS iters)"
    for i in $(seq 1 "$ITERS"); do
        local start_ns end_ns
        start_ns=$(date +%s%N)
        eval "$cmd >/dev/null 2>&1" || { warn "$runtime iter $i failed"; continue; }
        end_ns=$(date +%s%N)
        # Print as fractional seconds with 6 decimals (microsecond resolution).
        awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.6f\n", (e - s) / 1e9 }' >> "$out"
    done
}

rind_out="$BENCH_DIR/results/.raw/${LABEL}-rind.txt"
mkdir -p "$(dirname "$rind_out")"
timed_loop "$rind_out" "rind" "$RIND_BIN pull --quiet $ALPINE"

pairs=( "rind=$rind_out" )

if have_podman; then
    pman_out="$BENCH_DIR/results/.raw/${LABEL}-podman.txt"
    timed_loop "$pman_out" "podman" "podman pull --quiet $ALPINE"
    pairs+=( "podman=$pman_out" )
fi

if have_docker; then
    dckr_out="$BENCH_DIR/results/.raw/${LABEL}-docker.txt"
    timed_loop "$dckr_out" "docker" "docker pull --quiet $ALPINE"
    pairs+=( "docker=$dckr_out" )
fi

emit_outer_block_pct "$HEADING" "$DESC" "${pairs[@]}"
