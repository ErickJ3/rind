#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_bin
ensure_image_pulled

log "02: container init runs as PID 1"

out=$("$RIND_BIN" run --rm "$ALPINE" sh -c 'echo $$' 2>&1 | tr -d '[:space:]')
[[ "$out" == "1" ]] || fatal "expected PID 1, got: '$out'"

ok "PID namespace isolated (sh runs as PID 1)"
