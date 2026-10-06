#!/usr/bin/env bash
# Second half of the one-plane (ffn) gate (DECISIONS 10:25): the suite's computation family, raw arm, same seeds as
# ML2, on the product serve started with GGML_MIRAI_PREFILL_PLANES=ffn. Output: bench/ML3-ffn-computation, log
# receipts/mirai-port/ffn_gate.log. Ends by restarting the product WITHOUT the flag (defaults). ~45 min.
cd "$(dirname "$0")" && . ./lib.sh
LOG="$ROOT/receipts/mirai-port/ffn_gate.log"
echo "=== ffn gate $(date '+%F %H:%M') engine $(cd "$ROOT/engine" && git rev-parse --short HEAD)" | tee -a "$LOG"
GGML_MIRAI_PREFILL_PLANES=ffn bash "$ROOT/bench/product_smoke.sh" --start-only > "$ROOT/logs/product_ffn.log" 2>&1
grep -E "inner health|layer health" "$ROOT/logs/product_ffn.log" | tee -a "$LOG"
PYTHONUTF8=1 python "$ROOT/suite/run_suite.py" --base http://127.0.0.1:18080 --key-file "$ROOT/artifacts/api_key.txt" --model mirai-s-27b \
    --plan "$ROOT/bench/plans/computation.json" --out "$ROOT/bench/ML3-ffn-computation" --label-a mirai-raw-ffn 2>&1 | tail -12 | tee -a "$LOG"
PYTHONUTF8=1 python - "$ROOT" <<'PY' | tee -a "$LOG"
import json, sys
ROOT = sys.argv[1]
ml2 = {(r['name'], r['seed']): r['ok'] for r in map(json.loads, open(ROOT + '/bench/ML2/results.jsonl', encoding='utf-8')) if r['family'] == 'computation' and r['arm'] == 'mirai-raw'}
ffn = {(r['name'], r['seed']): r['ok'] for r in map(json.loads, open(ROOT + '/bench/ML3-ffn-computation/results.jsonl', encoding='utf-8'))}
print("item            ML2 raw (two planes)   ffn one-plane")
lost = gained = 0
for k in sorted(ml2):
    a, b = ml2[k], ffn.get(k)
    lost += int(a and b is False); gained += int((not a) and b)
    print(f"{k[0]:10s} {k[1]:<4d} {'pass' if a else 'fail':22s} {'pass' if b else 'fail' if b is False else '-'}")
print(f"ML2 raw {sum(ml2.values())}/15 -> ffn {sum(1 for v in ffn.values() if v)}/{len(ffn)}; lost {lost}, gained {gained}")
PY
bash "$ROOT/bench/product_smoke.sh" --start-only > "$ROOT/logs/product_restore.log" 2>&1
grep -E "inner health|layer health" "$ROOT/logs/product_restore.log" | tee -a "$LOG"
echo "=== done $(date '+%H:%M'); product restored with defaults" | tee -a "$LOG"
