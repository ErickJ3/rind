#!/usr/bin/env bash
# Cold-cache pull, repeated. Measures the bearer-token + TLS handshake
# critical path. Each iteration wipes the manifest cache + extracted +
# blob store, so every pull pays the full auth dance + first-byte
# latency. PR2's prefetch handle should collapse the σ.
#
# Network-bound — set RIND_BENCH_NETWORK=1 to opt in. CI never runs it.
# Defaults to 15 iters because cold runs hit real registries with
# higher variance than warm-loop scenarios.

source "$(dirname "$0")/../lib.sh"

LABEL="pull-cold-once"
HEADING="pull $ALPINE (cold cache, ${RIND_BENCH_ITERS:-15}x loop, p50/p95/p99/σ)"
DESC="Manifest cache + blob store wiped between iterations. Tracks auth+manifest critical path. Target σ < 100 ms (PR2 prefetch handle)."

ITERS="${RIND_BENCH_ITERS:-15}"

if [[ "${RIND_BENCH_NETWORK:-0}" != "1" ]]; then
    log "skipping $LABEL — set RIND_BENCH_NETWORK=1 to run network-bound bench"
    exit 0
fi

# rind store layout: $RIND_ROOT/store/{cache,blobs,extracted}.
# Default RIND_ROOT = $HOME/.rind (cli/root.zig:42).
RIND_ROOT="${RIND_ROOT:-$HOME/.rind}"
RIND_STORE="$RIND_ROOT/store"

wipe_rind_cache() {
    rm -rf "$RIND_STORE/cache/manifests" \
           "$RIND_STORE/blobs/sha256" \
           "$RIND_STORE/extracted" 2>/dev/null || true
}

wipe_podman_cache() {
    podman rmi -f "$ALPINE" >/dev/null 2>&1 || true
}

wipe_docker_cache() {
    docker rmi -f "$ALPINE" >/dev/null 2>&1 || true
}

timed_loop() {
    local out="$1" runtime="$2" wipe_fn="$3" cmd="$4"
    : > "$out"
    log "outer-loop: $LABEL $runtime ($ITERS iters)"
    for i in $(seq 1 "$ITERS"); do
        "$wipe_fn"
        local start_ns end_ns
        start_ns=$(date +%s%N)
        eval "$cmd >/dev/null 2>&1" || { warn "$runtime iter $i failed"; continue; }
        end_ns=$(date +%s%N)
        awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.6f\n", (e - s) / 1e9 }' >> "$out"
    done
}

rind_out="$BENCH_DIR/results/.raw/${LABEL}-rind.txt"
mkdir -p "$(dirname "$rind_out")"
timed_loop "$rind_out" "rind" wipe_rind_cache "$RIND_BIN pull --quiet $ALPINE"

pairs=( "rind=$rind_out" )

if have_podman; then
    pman_out="$BENCH_DIR/results/.raw/${LABEL}-podman.txt"
    timed_loop "$pman_out" "podman" wipe_podman_cache "podman pull --quiet $ALPINE"
    pairs+=( "podman=$pman_out" )
fi

if have_docker; then
    dckr_out="$BENCH_DIR/results/.raw/${LABEL}-docker.txt"
    timed_loop "$dckr_out" "docker" wipe_docker_cache "docker pull --quiet $ALPINE"
    pairs+=( "docker=$dckr_out" )
fi

emit_outer_block_pct "$HEADING" "$DESC" "${pairs[@]}"
