#!/usr/bin/env bash
# E23 (DECISIONS 2026-10-06 15:20): the two free VRAM levers. Arms on the test server at the product flags, 40,960 cells:
#   BASE   today's product file, pool defaults off           (reference)
#   POOL   GGML_CUDA_SHARED_POOL=1 LLAMA_MTP_DRAFT_UBATCH=256
#   POOLQ4 the same plus the GGUF with its MTP block at Q4_0 (tooling/requant_mtp.py)
# Per arm: VRAM at load, greedy identity vs the dump, decode at 0 / 16k, acceptance. Restores the product (which now
# picks the Q4 file by default if present). Output: receipts/mirai-port/mtp_q4_probe.log
cd "$(dirname "$0")" && . ./lib.sh
LOG="$ROOT/receipts/mirai-port/mtp_q4_probe.log"
PF="-b 2048 -ub 1024 --kq-mask-packed --kv-vram-cells 40960 --spec-type draft-mtp --spec-draft-n-max 2 -ctkd q8_0 -ctvd q8_0 --spec-draft-window 16384 --spec-draft-n-max-tail 2 --backend-sampling"
Q4=$(cygpath -w "$ROOT/models/Qwen3.8-27B-S-mirai-mtpq4.gguf")
until [ -f "$ROOT/models/Qwen3.8-27B-S-mirai-mtpq4.gguf" ] && [ "$(stat -c %s "$ROOT/models/Qwen3.8-27B-S-mirai-mtpq4.gguf")" -gt 10900000000 ]; do sleep 20; done; sleep 10
stop_server >/dev/null; powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tooling/stop.ps1" >/dev/null; sleep 3
echo "=== E23 mtp q4 + pool $(date '+%F %H:%M') engine $(cd "$ROOT/engine" && git rev-parse --short HEAD)" | tee -a "$LOG"
run_arm() { # LABEL "ENV" "EXTRA FLAGS"
  local label=$1 env=$2 extra=$3
  start_server "$label" 262144 "$PF $extra" "GGML_MIRAI_PREFILL_PLANES=ffn $env" | tail -1 | tee -a "$LOG"
  curl -s -m 3 "$BASE/health" | grep -q ok || { echo "$label: not healthy" | tee -a "$LOG"; stop_server >/dev/null; return; }
  echo "$label vram at load: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -1)" | tee -a "$LOG"
  echo -n "$label identity vs greedy dump: " | tee -a "$LOG"; PYTHONUTF8=1 python "$ROOT/bench/long_identity.py" --base "$BASE" --against "$ROOT/artifacts/long-serial.json" 2>&1 | tail -1 | tee -a "$LOG"
  for d in 0 16000; do echo -n "$label decode at $d: " | tee -a "$LOG"; PYTHONUTF8=1 python "$ROOT/bench/quick_tps.py" --base "$BASE" --key-file "$ROOT/artifacts/api_key.txt" --depth $d 2>&1 | tail -1 | tee -a "$LOG"; done
  echo -n "$label acceptance: " | tee -a "$LOG"; PYTHONUTF8=1 python "$ROOT/bench/served_receipt.py" "$ROOT/logs/$label.log" 2>/dev/null | grep -E "pooled acceptance" | tee -a "$LOG"
  stop_server >/dev/null; sleep 3
}
run_arm BASE   "" ""
run_arm POOL   "GGML_CUDA_SHARED_POOL=1 LLAMA_MTP_DRAFT_UBATCH=256" ""
MIRAI_MODEL="$Q4" run_arm POOLQ4 "GGML_CUDA_SHARED_POOL=1 LLAMA_MTP_DRAFT_UBATCH=256" ""
bash "$ROOT/bench/product_smoke.sh" --start-only > "$ROOT/logs/product_restore.log" 2>&1
grep -E "inner health|layer health|^kv|^model" "$ROOT/logs/product_restore.log" "$ROOT/logs/product.launcher.log" 2>/dev/null | tail -3 | tee -a "$LOG"
echo "=== done $(date '+%H:%M')" | tee -a "$LOG"
