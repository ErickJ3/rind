#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_bin
ensure_image_pulled

log "01: namespaces present + UTS isolated"

ns_out=$("$RIND_BIN" run --rm "$ALPINE" ls /proc/1/ns 2>&1) || \
    fatal "rind run failed: $ns_out"

for ns in mnt pid net uts ipc user; do
    grep -qE "^$ns(\$|[[:space:]])" <<<"$ns_out" || \
        fatal "namespace '$ns' missing from /proc/1/ns:\n$ns_out"
done

host_hostname=$(hostname)
container_hostname=$("$RIND_BIN" run --rm "$ALPINE" hostname 2>&1 | tr -d '[:space:]')
[[ -n "$container_hostname" ]] || fatal "container hostname empty"
[[ "$host_hostname" != "$container_hostname" ]] || \
    fatal "UTS namespace not isolated — host and container share hostname: $host_hostname"

ok "namespaces (mnt/pid/net/uts/ipc/user) present + UTS isolated"
