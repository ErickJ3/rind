#!/usr/bin/env bash
set -euo pipefail

if [[ "${RIND_E2E:-}" != "1" ]]; then
    echo "RIND_E2E=1 required; skipping isolation suite" >&2
    exit 0
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
fails=0
total=0
for name in namespaces pid cgroups seccomp mounts; do
    script="$DIR/$name.sh"
    [[ -x "$script" ]] || continue
    total=$((total+1))
    bash "$script" || fails=$((fails+1))
done

if (( fails > 0 )); then
    echo "isolation: $fails/$total checks failed" >&2
    exit 1
fi
echo "isolation: $total checks passed"
