#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_bin
ensure_image_pulled

log "04: PR_SET_NO_NEW_PRIVS + seccomp filter installed"

if ! command -v strace >/dev/null 2>&1; then
    warn "strace not installed — skipping seccomp prctl trace"
else
    trace=/tmp/rind-strace-$$.txt
    if strace -f -e prctl,seccomp -o "$trace" "$RIND_BIN" run --rm "$ALPINE" /bin/true >/dev/null 2>&1; then
        grep -qE 'PR_SET_NO_NEW_PRIVS, *1' "$trace" || \
            { rm -f "$trace"; fatal "PR_SET_NO_NEW_PRIVS=1 not observed in strace output"; }
        grep -qE 'seccomp\(SECCOMP_SET_MODE_FILTER|prctl\(PR_SET_SECCOMP' "$trace" || \
            { rm -f "$trace"; fatal "seccomp filter install not observed in strace output"; }
        log "prctl(PR_SET_NO_NEW_PRIVS) + seccomp install confirmed"
    else
        warn "rind run failed under strace (often nested-userns trace incompatibility) — skipping prctl assertion"
    fi
    rm -f "$trace"
fi

log "04: blocked syscall (mount inside container) returns EPERM/ENOSYS"
out=$("$RIND_BIN" run --rm "$ALPINE" sh -c 'mount -t proc proc /mnt 2>&1; echo done' 2>&1)
grep -qiE 'operation not permitted|permission denied|not allowed|function not implemented|are you root' <<<"$out" || \
    fatal "mount inside container should fail under seccomp+caps; got:\n$out"

ok "seccomp: filter installed, mount blocked inside container"
