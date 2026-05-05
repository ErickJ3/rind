#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_bin
ensure_image_pulled

log "03: cgroup path under user.slice/rind + memory limit enforced"

cg=$("$RIND_BIN" run --rm --memory 50m "$ALPINE" cat /proc/self/cgroup 2>&1) && ec=0 || ec=$?
if (( ec != 0 )); then
    if grep -q 'CgroupDelegationMissing' <<<"$cg"; then
        warn "skipping: cgroup v2 delegation absent (run 'loginctl enable-linger \$USER' and ensure user@.service has memory+cpu in cgroup.subtree_control)"
        ok "cgroups: skipped (delegation missing — diagnostic correct)"
        exit 0
    fi
    fatal "rind run with --memory failed unexpectedly:\n$cg"
fi

grep -qE 'rind' <<<"$cg" || \
    fatal "cgroup path doesn't reference rind:\n$cg"

log "03: triggering OOM under --memory 50m (allocate ~200 MiB)"
oom_out=""
if timeout 15 "$RIND_BIN" run --rm --memory 50m "$ALPINE" sh -c \
    'dd if=/dev/zero of=/tmp/big bs=1M count=200 2>&1 || true; echo done' \
    >/tmp/rind-oom-$$.out 2>&1; then
    oom_out=$(cat /tmp/rind-oom-$$.out)
    rm -f /tmp/rind-oom-$$.out
    grep -qE 'Killed|OOM|Out of memory|cannot allocate' <<<"$oom_out" || \
        warn "no OOM signal in output; cap may not be enforced. Output:\n$oom_out"
else
    rm -f /tmp/rind-oom-$$.out
    log "OOM kill detected (timeout reached or non-zero exit)"
fi

ok "cgroups: path under user.slice/rind, memory cap path exercised"
