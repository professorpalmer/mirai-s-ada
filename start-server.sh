#!/usr/bin/env bash
# Linux launcher for the raw server (no layer): the same flags as start-server.ps1 writes, one llama-server process.
# Checked on Ubuntu 22.04 with an RTX 3090 (receipts/ubuntu-3090/). It does not size the VRAM line for you:
# set MIRAI_KV_VRAM_CELLS for your card (44000 is the 12 GB headless number of this repo).
#
#   ./start-server.sh                 # 262k q8_0 tiered window, MTP drafting, port 8080
#   MIRAI_CVEC=models/Qwen3.8-27B-S-mirai-refusal-direction.gguf ./start-server.sh     # abliterated (README)
#   MIRAI_MMPROJ=models/mmproj-Qwen3.8-27B-base-f16.gguf ./start-server.sh             # images, encoder on the CPU
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER="${MIRAI_SERVER:-$ROOT/build/bin/llama-server}"
MODEL="${MIRAI_MODEL:-$ROOT/models/Qwen3.8-27B-S-mirai.gguf}"
PORT="${MIRAI_PORT:-8080}"
HOST="${MIRAI_HOST:-127.0.0.1}"
CTX="${MIRAI_CTX:-262144}"
CTK="${MIRAI_CTK:-q8_0}"
CELLS="${MIRAI_KV_VRAM_CELLS:-44000}"
SPEC="${MIRAI_SPEC:-2}"
SPEC_DEEP="${MIRAI_SPEC_DEEP:-2}"
DRAFT_WINDOW="${MIRAI_DRAFT_WINDOW:-16384}"
EFFORT="${MIRAI_EFFORT:-medium}"
EFFORT_ALLOWED="${MIRAI_EFFORT_ALLOWED:-medium}"
THINK_BUDGET="${MIRAI_THINK_BUDGET:-20480}"
UBATCH="${MIRAI_UBATCH:-1024}"

[ -x "$SERVER" ] || { echo "no llama-server at $SERVER (build the engine first, see README)"; exit 1; }
[ -f "$MODEL" ] || { echo "no model at $MODEL (download it from alesha-pro/Qwen3.8-27B-S-mirai-GGUF)"; exit 1; }

export GGML_CUDA_BATCH_INVARIANT=1
export GGML_MIRAI_PREFILL_PLANES="${MIRAI_PREFILL_PLANES:-ffn}"
export GGML_MIRAI_LEVELS_MIB="${MIRAI_LEVELS_MIB:-128}"

args=(-m "$MODEL" -ngl 99 -fa on -c "$CTX" -np 1 -ctk "$CTK" -ctv "$CTK" -b 2048 -ub "$UBATCH"
      --reasoning-effort-allow "$EFFORT_ALLOWED" --reasoning-effort-fallback medium
      --reasoning-max-tokens-floor "$((THINK_BUDGET + 4096))" --reasoning-budget "$THINK_BUDGET"
      --backend-sampling --chat-template-file "$ROOT/templates/bonsai-template.jinja"
      --chat-template-kwargs "{\"reasoning_effort\":\"$EFFORT\"}" --jinja --alias mirai-s-27b --metrics
      --temp 1.0 --top-p 0.95 --top-k 20 --host "$HOST" --port "$PORT")
[ "${MIRAI_TIER:-1}" = 1 ] && args+=(--kv-vram-cells "$CELLS")
[ "${MIRAI_KQ_MASK_PACKED:-1}" = 1 ] && args+=(--kq-mask-packed)
if [ "$SPEC" != 0 ]; then
  args+=(--spec-type draft-mtp --spec-draft-n-max "$SPEC" --spec-draft-n-max-tail "$SPEC_DEEP"
         --spec-draft-window "$DRAFT_WINDOW" -ctkd q8_0 -ctvd q8_0)
fi
# the refusal direction, projected out of the residual stream at run time (needs --cvec-mode in the engine)
[ -n "${MIRAI_CVEC:-}" ] && args+=(--control-vector-scaled "$MIRAI_CVEC:${MIRAI_CVEC_SCALE:-1.0}" --cvec-mode project)
# images: the base model's encoder on the CPU, so it takes no VRAM from the cache
[ -n "${MIRAI_MMPROJ:-}" ] && args+=(--mmproj "$MIRAI_MMPROJ" --no-mmproj-offload -t "${MIRAI_THREADS:-$(nproc --all)}")
[ -n "${MIRAI_API_KEY:-}" ] && args+=(--api-key "$MIRAI_API_KEY")

echo "mirai-s-ada: ctx $CTX, K/V $CTK, VRAM cells $CELLS, draft $SPEC/$SPEC_DEEP, effort $EFFORT (allowed: $EFFORT_ALLOWED)," \
     "control vector ${MIRAI_CVEC:-none}, images ${MIRAI_MMPROJ:-off}, http://$HOST:$PORT/v1"
exec "$SERVER" "${args[@]}" "$@"
