#!/usr/bin/env bash
# Smoke test of the PRODUCT launcher (start-server.ps1 with its defaults): starts it hidden (server log in
# logs/product.log, launcher output in logs/product.launcher.log), waits for the inner server (:18080) and the layer
# (:8080), then: (1) greedy identity on the inner port against the stock dump, (2) a layer round trip that needs the
# sandboxed tool (exact big arithmetic) with the trace shape, (3) decode at depth 0 and 16k on the inner port,
# (4) optionally the suite's paired smoke (--suite N = N items per family, both arms). Leaves the serve RUNNING.
#   bench/product_smoke.sh [--suite N] [--start-only]
# Only the launcher's stdout (its few config lines) is redirected; llama-server logs to stderr, which must NOT go
# through a Start-Process pipe (its reader dies with this script and the server would block once the pipe fills).
# The server's own log is logs/product.log via MIRAI_LOG_FILE.
cd "$(dirname "$0")" && . ./lib.sh
SUITE=0; START_ONLY=0
while [ $# -gt 0 ]; do case $1 in --suite) SUITE=$2; shift 2;; --start-only) START_ONLY=1; shift;; *) shift;; esac; done
OUT="$ROOT/receipts/mirai-port/product_smoke.log"
INNER="http://127.0.0.1:18080"; LAYER="http://127.0.0.1:8080"
stop_server >/dev/null; sleep 3
rm -f "$ROOT/logs/product.launcher.log"
MIRAI_LOG_FILE="logs/product.log" MIRAI_STDERR_FILE="logs/product.stderr" powershell -NoProfile -Command "Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$ROOT/start-server.ps1' -RedirectStandardOutput '$ROOT/logs/product.launcher.log'"
ok=0; for i in $(seq 1 140); do sleep 3; curl -s -m 3 "$INNER/health" 2>/dev/null | grep -q '"ok"' && { ok=1; break; }; done
echo "=== product $([ $START_ONLY = 1 ] && echo start || echo smoke) $(date '+%F %H:%M') engine $(cd "$ROOT/engine" && git rev-parse --short HEAD): inner health=$ok vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -1)" | tee -a "$OUT"
cat "$ROOT/logs/product.launcher.log" | tee -a "$OUT"
[ $ok = 1 ] || { tail -5 "$ROOT/logs/product.log"; exit 1; }
if [ $START_ONLY = 1 ]; then
  lok=0; for i in $(seq 1 20); do curl -s -m 3 "$LAYER/health" 2>/dev/null | grep -q -i "ok" && { lok=1; break; }; sleep 2; done
  echo "layer health=$lok; serve left running (layer :8080, llama-server 127.0.0.1:18080)" | tee -a "$OUT"; exit $(( 1 - lok ))
fi
lok=0; for i in $(seq 1 20); do curl -s -m 3 "$LAYER/health" 2>/dev/null | grep -q -i "ok" && { lok=1; break; }; sleep 2; done
echo "layer health=$lok" | tee -a "$OUT"
echo "--- (1) inner identity vs stock dump:" | tee -a "$OUT"
PYTHONUTF8=1 python "$ROOT/bench/compare_servers.py" --base "$INNER" --against "$ROOT/receipts/mirai-port/stock-greedy-nothink.json" --n 200 2>&1 | grep -E "^(SAME|DIFF)" | cut -c1-110 | tee -a "$OUT"
echo "--- (2) layer round trip (sandboxed tool expected):" | tee -a "$OUT"
PYTHONUTF8=1 python - "$(key)" "$LAYER" <<'PY' 2>&1 | tee -a "$OUT"
import json, urllib.request, sys
K, base = sys.argv[1], sys.argv[2]
body = {"model": "mirai-s-27b", "messages": [{"role": "user", "content": "What is 7919**23 exactly? Give the full integer and its digit count."}],
        "max_tokens": 4096, "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}
r = json.loads(urllib.request.urlopen(urllib.request.Request(base + "/v1/chat/completions", json.dumps(body).encode(),
    {"Authorization": "Bearer " + K, "Content-Type": "application/json"}), timeout=1800).read())
truth = str(7919 ** 23)
content = r["choices"][0]["message"].get("content") or ""
trace = r.get("interpreter_trace")
n_rounds = len(trace) if isinstance(trace, list) else (len(trace.get("rounds", [])) if isinstance(trace, dict) else 0)
tools = [t.get("name") or t.get("tool") for t in (trace if isinstance(trace, list) else [])][:6]
print(f"answer correct={truth in content} digits_claimed_ok={str(len(truth)) in content} usage={r.get('usage')} trace_rounds={n_rounds} tools={tools}")
print("content head:", content[:160].replace("\n", " "))
PY
echo "--- (3) inner decode by depth:" | tee -a "$OUT"
for d in 0 16000; do echo "depth $d: $(PYTHONUTF8=1 python "$ROOT/bench/quick_tps.py" --base "$INNER" --key-file "$ROOT/artifacts/api_key.txt" --depth $d 2>&1 | tail -1)" | tee -a "$OUT"; done
if [ "$SUITE" -gt 0 ]; then
  echo "--- (4) suite paired smoke, $SUITE item(s) per family, raw (:18080) vs layer (:8080) -> bench/ML2-smoke" | tee -a "$OUT"
  PYTHONUTF8=1 python "$ROOT/suite/run_suite.py" --base "$INNER" --base-b "$LAYER" --key-file "$ROOT/artifacts/api_key.txt" --model mirai-s-27b \
      --out "$ROOT/bench/ML2-smoke" --limit "$SUITE" --label-a mirai-raw --label-b mirai-layer 2>&1 | tail -25 | tee -a "$OUT"
fi
echo "=== smoke done $(date '+%H:%M'); the product serve is left running (layer :8080, llama-server 127.0.0.1:18080)" | tee -a "$OUT"
