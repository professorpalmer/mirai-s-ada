#!/usr/bin/env bash
# Decode by depth on the RUNNING product serve (inner port), one line per depth, for the README table.
# Depths default to 0 16k 32k 48k 60k 120k 180k; pass others as arguments. Output: receipts/mirai-port/decode_by_depth.log
cd "$(dirname "$0")" && . ./lib.sh
LOG="$ROOT/receipts/mirai-port/decode_by_depth.log"; INNER="http://127.0.0.1:18080"
DEPTHS=("$@"); [ ${#DEPTHS[@]} -eq 0 ] && DEPTHS=(0 16000 32000 48000 60000 120000 180000)
curl -s -m 3 "$INNER/health" | grep -q ok || { echo "product not up"; exit 1; }
echo "=== decode by depth $(date '+%F %H:%M') engine $(cd "$ROOT/engine" && git rev-parse --short HEAD); $(grep '^kv' "$ROOT/logs/product.launcher.log" | cut -c1-80); $(grep '^model' "$ROOT/logs/product.launcher.log" | cut -c1-60)" | tee -a "$LOG"
for d in "${DEPTHS[@]}"; do
  echo "depth $d: $(PYTHONUTF8=1 python "$ROOT/bench/quick_tps.py" --base "$INNER" --key-file "$ROOT/artifacts/api_key.txt" --depth "$d" 2>&1 | tail -1); vram $(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -1)" | tee -a "$LOG"
done
echo "=== done $(date '+%H:%M')" | tee -a "$LOG"
