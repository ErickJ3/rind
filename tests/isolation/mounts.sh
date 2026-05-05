#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_bin
ensure_image_pulled

log "05: minimum mount set + /sys read-only"

n=$("$RIND_BIN" run --rm "$ALPINE" sh -c 'wc -l < /proc/mounts' 2>&1 | tr -d '[:space:]')
[[ "$n" =~ ^[0-9]+$ ]] || fatal "expected integer mount count, got: '$n'"
(( n >= 4 )) || fatal "expected at least 4 mounts (rootfs/proc/sys/dev), got $n"

out=$("$RIND_BIN" run --rm "$ALPINE" sh -c 'touch /sys/foo 2>&1; echo done' 2>&1)
grep -qE 'Read-only|Permission denied' <<<"$out" || \
    fatal "/sys should be read-only; got:\n$out"

ok "mounts: $n entries in /proc/mounts, /sys read-only"
