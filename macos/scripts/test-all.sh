#!/bin/bash
# Runs every macos/scripts/test-*.sh suite. Optional args filter by basename substring.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/macos/scripts/test-env.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CLOUDREVE_FP_STATE_ROOT="$WORK/state"
mkdir -p "$CLOUDREVE_FP_STATE_ROOT"

passed=0
failed=0

for script in "$ROOT"/macos/scripts/test-*.sh; do
    name="$(basename "$script")"
    [[ "$name" == "test-all.sh" || "$name" == "test-env.sh" ]] && continue
    if [[ $# -gt 0 ]]; then
        match=0
        for filter in "$@"; do
            [[ "$name" == *"$filter"* ]] && match=1
        done
        [[ $match -eq 1 ]] || continue
    fi
    log="$WORK/${name%.sh}.log"
    echo "==> $name"
    if bash "$script" >"$log" 2>&1; then
        echo "    PASS"
        passed=$((passed + 1))
    else
        echo "    FAIL"
        tail -n 40 "$log"
        failed=$((failed + 1))
    fi
done

echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]] || exit 1
