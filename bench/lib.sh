# Shared helpers for rind benchmark scenarios.
# Source from any bench/scenarios/*.sh:  source "$(dirname "$0")/../lib.sh"

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"
RIND_BIN="$REPO_ROOT/zig-out/bin/rind"
ALPINE="alpine:3.19"

# Color
if [[ -t 2 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

log()   { echo "${C_B}[bench]${C_0} $*" >&2; }
warn()  { echo "${C_Y}[warn]${C_0}  $*" >&2; }
fatal() { echo "${C_R}[fatal]${C_0} $*" >&2; exit 1; }
ok()    { echo "${C_G}[ok]${C_0}    $*" >&2; }

require() {
    command -v "$1" >/dev/null 2>&1 || fatal "missing: $1 — install $1 first"
}

require_poop() {
    if ! command -v poop >/dev/null 2>&1; then
        fatal "poop not on PATH — install: zig build -Doptimize=ReleaseFast (see https://github.com/andrewrk/poop)"
    fi
}

# Build rind in ReleaseFast+strip. Always passes flags explicitly (don't trust defaults).
build_release() {
    log "zig build -Doptimize=ReleaseFast -Dstrip"
    (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseFast -Dstrip)
    [[ -x "$RIND_BIN" ]] || fatal "binary missing after build: $RIND_BIN"
    ensure_stripped "$RIND_BIN"
    local size
    size=$(stat -c %s "$RIND_BIN")
    ok "rind binary: $RIND_BIN ($((size/1024/1024))MB, stripped)"
}

# Refuse Debug or unstripped binary (would invalidate <80ms target).
ensure_stripped() {
    local bin="$1"
    if file "$bin" | grep -q "not stripped"; then
        fatal "binary is unstripped — bench must run against ReleaseFast+strip (see build.zig:28)"
    fi
}

have_docker() {
    command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1
}

have_podman() {
    command -v podman >/dev/null 2>&1
}

# Pre-pull alpine on every available runtime (warmup, keeps network out of the bench).
pre_pull_alpine() {
    log "pre-pulling $ALPINE on all runtimes"
    "$RIND_BIN" pull --quiet "$ALPINE" >/dev/null 2>&1 || warn "rind pull failed"
    if have_podman; then
        podman pull --quiet "$ALPINE" >/dev/null 2>&1 || warn "podman pull failed"
    fi
    if have_docker; then
        docker pull --quiet "$ALPINE" >/dev/null 2>&1 || warn "docker pull failed"
    fi
    ok "pre-pull done"
}

# Build the array of poop arguments based on which runtimes are available.
# Usage:
#   cmds=()
#   add_rind_cmd cmds "run --rm $ALPINE /bin/true"
#   add_podman_cmd cmds "run --rm $ALPINE /bin/true"
#   add_docker_cmd cmds "run --rm $ALPINE /bin/true"
#   poop "${POOP_FLAGS[@]}" "${cmds[@]}"
add_rind_cmd() {
    local -n arr="$1"; shift
    arr+=("$RIND_BIN $*")
}
add_podman_cmd() {
    local -n arr="$1"; shift
    have_podman && arr+=("podman $*") || true
}
add_docker_cmd() {
    local -n arr="$1"; shift
    have_docker && arr+=("docker $*") || true
}

# Run poop, capture raw stderr to a file, also tee to terminal so user sees progress.
# $1 = label (filename-safe), rest = poop args (commands)
# Exports: POOP_OUTPUT_FILE = path to captured raw output.
run_poop() {
    local label="$1"; shift
    local out="$BENCH_DIR/results/.raw/$label.txt"
    mkdir -p "$(dirname "$out")"
    log "poop $*"
    # poop prints results to stderr; capture both streams.
    poop --color never "$@" 2>&1 | tee "$out"
    POOP_OUTPUT_FILE="$out"
}

# Parse a single poop output file, emit a markdown table.
# Argument: path to poop raw output.
# Output: markdown table to stdout.
poop_to_markdown_table() {
    local raw="$1"
    awk '
        BEGIN {
            n = 0
        }
        /^Benchmark [0-9]+/ {
            # "Benchmark 1 (1234 runs): cmd here..."
            match($0, /\(([0-9,]+) runs?\):/, m)
            runs = m[1]
            sub(/^Benchmark [0-9]+ \([^)]+\): */, "")
            cmd[n] = $0
            cmdruns[n] = runs
            n++
            next
        }
        # poop reports "wall_time" with mean ± σ then "min … max" then outliers
        /wall_time/ {
            line = $0
            # Strip leading "  wall_time"
            sub(/^[ \t]*wall_time[ \t]*/, "", line)
            wall[n-1] = line
            next
        }
        END {
            print "| runtime | wall_time (mean ± σ, min … max) | runs |"
            print "|---------|---------------------------------|------|"
            for (i = 0; i < n; i++) {
                # First word of cmd is binary name; show short label.
                short = cmd[i]
                if (short ~ /\/rind /) tag = "rind"
                else if (short ~ /^docker /) tag = "docker"
                else if (short ~ /^podman /) tag = "podman"
                else tag = "?"
                gsub(/\|/, "\\|", wall[i])
                printf "| %s | `%s` | %s |\n", tag, wall[i], cmdruns[i]
            }
        }
    ' "$raw"
}

# Write a scenario block into results/latest.md.
# $1 = scenario heading, $2 = description line, $3 = path to raw poop output.
emit_scenario_block() {
    local heading="$1"
    local desc="$2"
    local raw="$3"
    local out="$BENCH_DIR/results/latest.md"
    {
        echo ""
        echo "## $heading"
        echo ""
        echo "$desc"
        echo ""
        poop_to_markdown_table "$raw"
        echo ""
        echo "<details><summary>raw poop output</summary>"
        echo ""
        echo '```'
        cat "$raw"
        echo '```'
        echo ""
        echo "</details>"
    } >> "$out"
}

# Cleanup helpers — bench scenarios pre-create state and must clean up after.
cleanup_rind_containers() {
    local prefix="${1:-bench-}"
    "$RIND_BIN" ps -a -q 2>/dev/null | while read -r id; do
        [[ -n "$id" ]] && "$RIND_BIN" rm -f "$id" >/dev/null 2>&1 || true
    done || true
}
cleanup_named_containers() {
    local prefix="$1"
    if have_podman; then
        podman ps -a --format '{{.Names}}' 2>/dev/null | grep "^$prefix" | xargs -r podman rm -f >/dev/null 2>&1 || true
    fi
    if have_docker; then
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^$prefix" | xargs -r docker rm -f >/dev/null 2>&1 || true
    fi
}

# Outer-loop microbench for non-idempotent commands (rm, pull-cold).
# poop has no setup hook, so we time each iter ourselves with /usr/bin/time.
# Args:
#   $1 = label (filename-safe)
#   $2 = number of iterations (N)
#   $3 = setup function name (called before each iter, takes $iter as arg)
#   $4 = command to time (uses $ITER env var for per-iter ids)
#   $5 = teardown function name (called after each iter, optional, "-" to skip)
# Writes raw timings to results/.raw/<label>-<runtime>.txt as one float per line (seconds).
outer_loop_bench() {
    local label="$1" n="$2" setup_fn="$3" cmd="$4" teardown_fn="${5:--}"
    local out="$BENCH_DIR/results/.raw/$label.txt"
    mkdir -p "$(dirname "$out")"
    : > "$out"
    log "outer-loop: $label ($n iters)"
    for ITER in $(seq 1 "$n"); do
        export ITER
        "$setup_fn" "$ITER" >/dev/null 2>&1 || { warn "setup failed iter $ITER"; continue; }
        local t
        t=$( { /usr/bin/time -f '%e' bash -c "$cmd" >/dev/null 2>&3; } 3>&2 2>&1 ) || { warn "cmd failed iter $ITER"; continue; }
        echo "$t" >> "$out"
        if [[ "$teardown_fn" != "-" ]]; then
            "$teardown_fn" "$ITER" >/dev/null 2>&1 || true
        fi
    done
    POOP_OUTPUT_FILE="$out"
}

# Compute mean / min / max / stddev from a file of float seconds.
# Echoes "mean min max stddev" in milliseconds.
stats_ms() {
    local file="$1"
    awk '
        { x = $1 * 1000; sum += x; sumsq += x*x; n++; if (n==1 || x<min) min=x; if (x>max) max=x }
        END {
            if (n == 0) { print "n/a n/a n/a n/a"; exit }
            mean = sum/n
            stddev = (n>1) ? sqrt((sumsq - n*mean*mean) / (n-1)) : 0
            printf "%.1f %.1f %.1f %.1f\n", mean, min, max, stddev
        }
    ' "$file"
}

# Compute p50 / p95 / p99 from a file of float seconds.
# Echoes "p50 p95 p99" in milliseconds. Linear interpolation between
# adjacent ranks; stable for n >= 1.
percentiles_ms() {
    local file="$1"
    sort -n "$file" | awk '
        { a[NR] = $1 * 1000 }
        END {
            n = NR
            if (n == 0) { print "n/a n/a n/a"; exit }
            for (i = 0; i < 3; i++) {
                p = (i == 0) ? 50 : ((i == 1) ? 95 : 99)
                if (n == 1) { v = a[1] }
                else {
                    rank = (p / 100.0) * (n - 1) + 1
                    lo = int(rank); hi = lo + 1
                    if (hi > n) hi = n
                    frac = rank - lo
                    v = a[lo] + (a[hi] - a[lo]) * frac
                }
                printf "%.1f%s", v, (i < 2 ? " " : "\n")
            }
        }
    '
}

# Render an outer-loop result table from labelled raw files.
# Args: heading, desc, then label=path pairs.
emit_outer_block() {
    local heading="$1" desc="$2"; shift 2
    local out="$BENCH_DIR/results/latest.md"
    {
        echo ""
        echo "## $heading"
        echo ""
        echo "$desc"
        echo ""
        echo "| runtime | mean (ms) | min (ms) | max (ms) | stddev (ms) | n |"
        echo "|---------|-----------|----------|----------|-------------|---|"
        while [[ $# -gt 0 ]]; do
            local pair="$1"; shift
            local tag="${pair%%=*}"
            local file="${pair#*=}"
            if [[ -s "$file" ]]; then
                local stats
                stats=$(stats_ms "$file")
                local n
                n=$(wc -l < "$file")
                read -r mean min max stddev <<< "$stats"
                printf "| %s | %s | %s | %s | %s | %s |\n" "$tag" "$mean" "$min" "$max" "$stddev" "$n"
            else
                printf "| %s | n/a | n/a | n/a | n/a | 0 |\n" "$tag"
            fi
        done
        echo ""
    } >> "$out"
}

# Same as emit_outer_block but adds p50/p95/p99 columns. Use for
# warm-loop scenarios where tail latency matters more than mean.
emit_outer_block_pct() {
    local heading="$1" desc="$2"; shift 2
    local out="$BENCH_DIR/results/latest.md"
    {
        echo ""
        echo "## $heading"
        echo ""
        echo "$desc"
        echo ""
        echo "| runtime | mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | min (ms) | max (ms) | stddev (ms) | n |"
        echo "|---------|-----------|----------|----------|----------|----------|----------|-------------|---|"
        while [[ $# -gt 0 ]]; do
            local pair="$1"; shift
            local tag="${pair%%=*}"
            local file="${pair#*=}"
            if [[ -s "$file" ]]; then
                local stats pct
                stats=$(stats_ms "$file")
                pct=$(percentiles_ms "$file")
                local n
                n=$(wc -l < "$file")
                read -r mean min max stddev <<< "$stats"
                read -r p50 p95 p99 <<< "$pct"
                printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
                    "$tag" "$mean" "$p50" "$p95" "$p99" "$min" "$max" "$stddev" "$n"
            else
                printf "| %s | n/a | n/a | n/a | n/a | n/a | n/a | n/a | 0 |\n" "$tag"
            fi
        done
        echo ""
    } >> "$out"
}

# Initialize results/latest.md with the env fingerprint header.
init_results() {
    local out="$BENCH_DIR/results/latest.md"
    mkdir -p "$BENCH_DIR/results"
    {
        echo "# rind bench results"
        echo ""
        echo "- date: $(date -Iseconds)"
        echo "- git: $(cd "$REPO_ROOT" && git rev-parse --short HEAD) ($(cd "$REPO_ROOT" && git symbolic-ref --short HEAD 2>/dev/null || echo detached))"
        echo "- kernel: $(uname -r)"
        echo "- cpu: $(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
        echo "- mem: $(awk '/MemTotal/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)"
        echo "- zig: $(zig version)"
        echo "- build: zig build -Doptimize=ReleaseFast -Dstrip"
        echo "- rind: $(stat -c '%s bytes' "$RIND_BIN")"
        echo "- runtimes: rind$(have_podman && echo " / podman" || true)$(have_docker && echo " / docker" || true)"
        echo ""
    } > "$out"
}
