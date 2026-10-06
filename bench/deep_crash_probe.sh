#!/usr/bin/env bash
# E24 (DECISIONS 2026-10-06 15:50): the product died (ucrtbase fail-fast 0xc0000409 = abort, 15:34) on a 180k-token
# request on the new defaults (shared pool, MTP block at Q4_0, 57,856 cells). Reproduce on the test server with raw
# stderr captured (MIRAI_CAPTURE_STDERR=1, so a GGML_ASSERT text lands in the log), then toggle one lever at a time:
#   A  product config: mtpq4 file, pool on                (expected to reproduce)
#   B  mtpq4 file, pool OFF                               (is it the shared pool?)
#   C  published file, pool on                            (is it the Q4 draft block?)
#   D  published file, pool off, 57,856 cells             (is it the higher line itself?)
# Each arm: load, depth 120k then 180k (bench/quick_tps.py), health after each, last stderr lines on failure.
# Output: receipts/mirai-port/deep_crash_probe.log. Restores the product at the end (whatever the launcher's defaults are).
cd "$(dirname "$0")" && . ./lib.sh
LOG="$ROOT/receipts/mirai-port/deep_crash_probe.log"
CELLS=${CELLS:-57856}
PF="-b 2048 -ub 1024 --kq-mask-packed --kv-vram-cells $CELLS --spec-type draft-mtp --spec-draft-n-max 2 -ctkd q8_0 -ctvd q8_0 --spec-draft-window 16384 --spec-draft-n-max-tail 2 --backend-sampling"
Q4=$(cygpath -w "$ROOT/models/Qwen3.8-27B-S-mirai-mtpq4.gguf"); PUBF=$(cygpath -w "$ROOT/models/Qwen3.8-27B-S-mirai.gguf")
POOL="GGML_CUDA_SHARED_POOL=1 LLAMA_MTP_DRAFT_UBATCH=256"
stop_server >/dev/null; powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tooling/stop.ps1" >/dev/null; sleep 3
echo "=== E24 deep crash probe $(date '+%F %H:%M') engine $(cd "$ROOT/engine" && git rev-parse --short HEAD); cells $CELLS" | tee -a "$LOG"
run_arm() { # LABEL MODEL "ENV"
  local label=$1 model=$2 env=$3 d
  MIRAI_MODEL="$model" MIRAI_CAPTURE_STDERR=1 start_server "$label" 262144 "$PF" "GGML_MIRAI_PREFILL_PLANES=ffn $env" | tail -1 | tee -a "$LOG"
  curl -s -m 3 "$BASE/health" | grep -q ok || { echo "$label: not healthy at load" | tee -a "$LOG"; tail -5 "$ROOT/logs/$label.stderr" "$ROOT/logs/$label.log" 2>/dev/null | cut -c1-200 | tee -a "$LOG"; stop_server >/dev/null; return 2; }
  for d in 120000 180000; do
    echo "$label depth $d: $(PYTHONUTF8=1 python "$ROOT/bench/quick_tps.py" --base "$BASE" --key-file "$ROOT/artifacts/api_key.txt" --depth $d 2>&1 | tail -1 | cut -c1-120); vram $(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -1)" | tee -a "$LOG"
    if ! curl -s -m 5 "$BASE/health" 2>/dev/null | grep -q ok; then
      echo "$label: SERVER DOWN after depth $d; last stderr/log lines:" | tee -a "$LOG"
      for f in "$ROOT/logs/$label.stderr" "$ROOT/logs/$label.log"; do echo "-- $(basename "$f"):" | tee -a "$LOG"; grep -v "^$" "$f" 2>/dev/null | tail -10 | cut -c1-240 | tee -a "$LOG"; done
      stop_server >/dev/null; sleep 2; return 1
    fi
  done
  echo "$label: survived 120k and 180k" | tee -a "$LOG"; stop_server >/dev/null; sleep 3; return 0
}
run_arm A "$Q4"   "$POOL"; ra=$?
if [ $ra = 0 ]; then
  echo "A did not reproduce; running A once more" | tee -a "$LOG"; run_arm A2 "$Q4" "$POOL"; ra=$?
fi
if [ $ra != 0 ]; then
  run_arm B "$Q4"   "";      rb=$?
  run_arm C "$PUBF" "$POOL"; rc=$?
  [ $rb != 0 ] && [ $rc != 0 ] && { run_arm D "$PUBF" ""; rd=$?; echo "D (published file, pool off, $CELLS cells) -> $rd" | tee -a "$LOG"; }
  echo "verdict: A=$ra B(pool off)=$rb C(published file)=$rc  (0 survived, 1 died, 2 did not load)" | tee -a "$LOG"
fi
bash "$ROOT/bench/product_smoke.sh" --start-only > "$ROOT/logs/product_restore.log" 2>&1
grep -E "inner health|layer health" "$ROOT/logs/product_restore.log" | tee -a "$LOG"
echo "=== done $(date '+%H:%M'); product restored" | tee -a "$LOG"
