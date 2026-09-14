#!/usr/bin/env bash
#
# check_regression.sh — run the zero bench harness and compare against the
# committed baseline (bench/baseline.json), replicating the regression gate that
# runs in .github/workflows/ci.yml (the "Compare against baseline" step).
#
# Usage:
#   bench/check_regression.sh                 # default: --target=all, 2s, levels 1,25,100
#   DURATION=2 LEVELS=1,25,100 TARGET=all bench/check_regression.sh
#
# Environment overrides:
#   DURATION   per-level seconds            (default 2)
#   LEVELS     comma list of concurrency     (default 1,25,100)
#   TARGET     --target csv or "all"         (default all)
#   ZIG        zig binary                    (default: zig on PATH)
#
# Exits 0 when no regression (and no leak); 1 on regression/leak or on failure.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

ZIG="${ZIG:-zig}"
# Tolerate ZIG pointing at the install *directory* (append /zig).
if [ -d "$ZIG" ]; then
    ZIG="$ZIG/zig"
fi
DURATION="${DURATION:-2}"
LEVELS="${LEVELS:-1,25,100}"
TARGET="${TARGET:-all}"

echo "==> building bench harness"
"$ZIG" build bench --summary all || { echo "build failed"; exit 1; }

REPORT="zig-out/bench/report.json"
mkdir -p "$(dirname "$REPORT")"

echo "==> running suite (target=$TARGET duration=$DURATION levels=$LEVELS)"
./zig-out/bin/bench --target="$TARGET" --json --duration="$DURATION" --levels="$LEVELS" || {
    echo "bench run failed"
    exit 1
}

echo "==> comparing against baseline (bench/baseline.json)"
jq empty "$REPORT" 2>/dev/null || { echo "no report.json produced"; exit 1; }

if [ ! -f bench/baseline.json ]; then
    echo "No baseline present; initializing baseline (skip regression)."
    cp "$REPORT" bench/baseline.json
    exit 0
fi
jq empty bench/baseline.json 2>/dev/null || { echo "baseline corrupt"; exit 1; }

ABS_THRESH=8   # MiB
REL_THRESH=0.15

fails=0
while IFS= read -r row; do
    name=$(echo "$row" | jq -r '.name')
    peak=$(echo "$row" | jq -r '.peak_rss_mib')
    leak=$(echo "$row" | jq -r '.leak')
    if [ "$leak" = "true" ]; then
        echo "LEAK detected in scenario: $name"
        fails=$((fails + 1))
        continue
    fi
    bpeak=$(jq -r --arg n "$name" '.scenarios[] | select(.name==$n) | .peak_rss_mib' bench/baseline.json)
    if [ -n "$bpeak" ] && [ "$bpeak" != "null" ]; then
        rel=$(awk -v p="$peak" -v b="$bpeak" 'BEGIN{printf "%.4f", (p-b)/b}')
        absmb=$(awk -v p="$peak" -v b="$bpeak" 'BEGIN{printf "%.4f", (p-b)}')
        echo "$name: baseline=${bpeak}MiB now=${peak}MiB (rel +${rel}, abs +${absmb}MiB)"
        rel_bad=$(awk -v g="$rel" 'BEGIN{print (g>'"$REL_THRESH"')?1:0}')
        abs_bad=$(awk -v a="$absmb" 'BEGIN{print (a>'"$ABS_THRESH"')?1:0}')
        if [ "$rel_bad" = "1" ] && [ "$abs_bad" = "1" ]; then
            echo "REGRESSION: $name peak RSS grew ${rel}% (>15%) and ${absmb}MiB (>8MiB)"
            fails=$((fails + 1))
        fi
    fi
done < <(jq -c '.scenarios[]' "$REPORT")

if [ "$fails" -gt 0 ]; then
    echo "Bench regression: $fails scenario(s) failed."
    exit 1
fi
echo "No bench regression."
