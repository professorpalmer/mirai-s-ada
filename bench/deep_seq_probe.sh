#!/usr/bin/env bash
# E24 (b): the product died on a 180k request after serving 0/16k/32k/48k/60k/120k in one session, but the bare test
# server survived 120k+180k (bench/deep_crash_probe.sh arm A, twice). Two differences remain: the request SEQUENCE
# (prefix-cache reuse across depths) and the product's harness flags (reasoning budget, which also turns backend
# sampling off). This replays the exact sequence:
#   product   against the running product (inner :18080); on death the product log tail is saved
#   harness   on the test server with the product flags + harness flags, stderr captured (the assert text survives)
#   bench/deep_seq_probe.sh product|harness [depths...]
# Output: receipts/mirai-port/deep_seq_probe.log
cd "$(dirname "$0")" && . ./lib.sh
LOG="$ROOT/receipts/mirai-port/deep_seq_probe.log"
MODE=${1:-product}; shift || true
DEPTHS=("$@"); [ ${#DEPTHS[@]} -eq 0 ] && DEPTHS=(0 16000 32000 48000 60000 120000 180000)
CELLS=${CELLS:-57856}
PF="-b 2048 -ub 1024 --kq-mask-packed --kv-vram-cells $CELLS --spec-type draft-mtp --spec-draft-n-max 2 -ctkd q8_0 -ctvd q8_0 --spec-draft-window 16384 --spec-draft-n-max-tail 2 --backend-sampling"
HARNESS="--reasoning-budget 20480 --reasoning-budget-message Answer. --reasoning-effort-allow medium --reasoning-effort-fallback medium --reasoning-max-tokens-floor 24576 -n 24576 --prio 2 --poll 100"
POOL="GGML_CUDA_SHARED_POOL=1 LLAMA_MTP_DRAFT_UBATCH=256"
Q4=$(cygpath -w "$ROOT/models/Qwen3.8-27B-S-mirai-mtpq4.gguf")
if [ "$MODE" = product ]; then
  URL="http://127.0.0.1:18080"; LABEL=product
  curl -s -m 3 "$URL/health" | grep -q ok || { echo "product not up" | tee -a "$LOG"; exit 2; }
  echo "=== E24b sequence on the PRODUCT $(date '+%F %H:%M') engine $(cd "$ROOT/engine" && git rev-parse --short HEAD); $(grep '^kv' "$ROOT/logs/product.launcher.log" | cut -c1-70)" | tee -a "$LOG"
else
  URL="$BASE"; LABEL=SEQH
  stop_server >/dev/null; powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tooling/stop.ps1" >/dev/null; sleep 3
  echo "=== E24b sequence on the test HARNESS + product harness flags $(date '+%F %H:%M') engine $(cd "$ROOT/engine" && git rev-parse --short HEAD); cells $CELLS" | tee -a "$LOG"
  MIRAI_MODEL="$Q4" MIRAI_CAPTURE_STDERR=1 start_server "$LABEL" 262144 "$PF $HARNESS" "GGML_MIRAI_PREFILL_PLANES=ffn $POOL" | tail -1 | tee -a "$LOG"
  curl -s -m 3 "$URL/health" | grep -q ok || { echo "$LABEL: not healthy at load" | tee -a "$LOG"; tail -5 "$ROOT/logs/$LABEL.stderr" "$ROOT/logs/$LABEL.log" 2>/dev/null | cut -c1-200 | tee -a "$LOG"; exit 2; }
fi
died=0
for d in "${DEPTHS[@]}"; do
  echo "$LABEL depth $d: $(PYTHONUTF8=1 python "$ROOT/bench/quick_tps.py" --base "$URL" --key-file "$ROOT/artifacts/api_key.txt" --depth "$d" 2>&1 | tail -1 | cut -c1-120); vram $(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -1)" | tee -a "$LOG"
  if ! curl -s -m 5 "$URL/health" 2>/dev/null | grep -q ok; then
    died=1; echo "$LABEL: SERVER DOWN after depth $d" | tee -a "$LOG"
    if [ "$MODE" = product ]; then
      cp "$ROOT/logs/product.log" "$ROOT/receipts/mirai-port/deep_crash_product_$(date '+%H%M').log"
      echo "-- product.log tail (saved as receipts/mirai-port/deep_crash_product_*.log):" | tee -a "$LOG"; grep -v "^$" "$ROOT/logs/product.log" | tail -8 | cut -c1-240 | tee -a "$LOG"
    else
      for f in "$ROOT/logs/$LABEL.stderr" "$ROOT/logs/$LABEL.log"; do echo "-- $(basename "$f"):" | tee -a "$LOG"; grep -v "^$" "$f" 2>/dev/null | tail -10 | cut -c1-240 | tee -a "$LOG"; done
    fi
    break
  fi
done
[ $died = 0 ] && echo "$LABEL: survived the whole sequence (${DEPTHS[*]})" | tee -a "$LOG"
if [ "$MODE" != product ]; then stop_server >/dev/null; sleep 3; fi
if [ $died = 1 ] || [ "$MODE" != product ]; then
  bash "$ROOT/bench/product_smoke.sh" --start-only > "$ROOT/logs/product_restore.log" 2>&1
  grep -E "inner health|layer health" "$ROOT/logs/product_restore.log" | tee -a "$LOG"
fi
echo "=== done $(date '+%H:%M')" | tee -a "$LOG"
exit $died
