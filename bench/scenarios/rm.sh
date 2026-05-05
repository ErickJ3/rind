#!/usr/bin/env bash
# rm bench: outer-loop, not poop (rm needs fresh container each iter, poop has no setup hook).
# Pre-creates per-iter container with `<runtime> run --name <prefix>-N`, then times the rm.

source "$(dirname "$0")/../lib.sh"

LABEL="rm"
HEADING="rm <stopped-container>"
DESC="Remove a stopped container. Outer-loop bench (50 iters); poop unsuitable (rm is non-idempotent). Exercises src/cli/rm.zig:119 + recent skip-PidWatcher-on-rm win."

N=50
PREFIX="bench-rm"

# rind setup/teardown
setup_rind() {
    "$RIND_BIN" run --name "${PREFIX}-rind-$1" "$ALPINE" /bin/true >/dev/null 2>&1
}
teardown_rind() { :; }
RAW_RIND="$BENCH_DIR/results/.raw/rm-rind.txt"
mkdir -p "$(dirname "$RAW_RIND")"
: > "$RAW_RIND"
log "rind: pre-create + time rm × $N"
for i in $(seq 1 $N); do
    setup_rind "$i" || { warn "rind setup failed iter $i"; continue; }
    t=$( { /usr/bin/time -f '%e' "$RIND_BIN" rm "${PREFIX}-rind-$i" >/dev/null 2>&3; } 3>&2 2>&1 ) || { warn "rind rm failed iter $i"; continue; }
    echo "$t" >> "$RAW_RIND"
done

# podman
RAW_POD="$BENCH_DIR/results/.raw/rm-podman.txt"
: > "$RAW_POD"
if have_podman; then
    log "podman: pre-create + time rm × $N"
    for i in $(seq 1 $N); do
        podman run --name "${PREFIX}-pod-$i" "$ALPINE" /bin/true >/dev/null 2>&1 || { warn "podman setup $i failed"; continue; }
        t=$( { /usr/bin/time -f '%e' podman rm "${PREFIX}-pod-$i" >/dev/null 2>&3; } 3>&2 2>&1 ) || { warn "podman rm $i failed"; continue; }
        echo "$t" >> "$RAW_POD"
    done
fi

# docker
RAW_DOCKER="$BENCH_DIR/results/.raw/rm-docker.txt"
: > "$RAW_DOCKER"
if have_docker; then
    log "docker: pre-create + time rm × $N"
    for i in $(seq 1 $N); do
        docker run --name "${PREFIX}-docker-$i" "$ALPINE" /bin/true >/dev/null 2>&1 || { warn "docker setup $i failed"; continue; }
        t=$( { /usr/bin/time -f '%e' docker rm "${PREFIX}-docker-$i" >/dev/null 2>&3; } 3>&2 2>&1 ) || { warn "docker rm $i failed"; continue; }
        echo "$t" >> "$RAW_DOCKER"
    done
fi

emit_outer_block "$HEADING" "$DESC" \
    "rind=$RAW_RIND" \
    "podman=$RAW_POD" \
    "docker=$RAW_DOCKER"
