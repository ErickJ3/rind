# Shared helpers for rind isolation checks.
# Source from any tests/isolation/*.sh:
#   source "$(dirname "$0")/lib.sh"

set -euo pipefail

ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ISO_DIR/../.." && pwd)"
RIND_BIN="${RIND_BIN:-$REPO_ROOT/zig-out/bin/rind}"
ALPINE="${ALPINE:-alpine:3.19}"

if [[ -t 2 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

log()   { echo "${C_B}[isolation]${C_0} $*" >&2; }
warn()  { echo "${C_Y}[warn]${C_0}      $*" >&2; }
fatal() { echo "${C_R}[fail]${C_0}      $*" >&2; exit 1; }
ok()    { echo "${C_G}[ok]${C_0}        $*" >&2; }

require_bin() {
    [[ -x "$RIND_BIN" ]] || fatal "rind binary not built: $RIND_BIN (run: zig build)"
}

ensure_image_pulled() {
    "$RIND_BIN" inspect "$ALPINE" >/dev/null 2>&1 || \
        "$RIND_BIN" pull --quiet "$ALPINE" >/dev/null 2>&1 || \
        fatal "failed to pull $ALPINE — check network or pre-pull manually"
}
