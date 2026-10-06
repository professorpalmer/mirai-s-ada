# Shared helpers for the bash bench drivers. Servers start hidden with logs under logs\ (tooling\serve.ps1) and
# stop with tooling\stop.ps1; nothing leaves a console window behind.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"   # the repo, Windows-style path under Git Bash
PORT="${MIRAI_PORT:-18081}"
BASE="http://127.0.0.1:$PORT"
mkdir -p "$ROOT/artifacts" "$ROOT/logs"
key() { tr -d '\r\n' < "$ROOT/artifacts/api_key.txt"; }

stop_server() { powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tooling/stop.ps1" | tail -1; }

# start_server LABEL CTX "EXTRA FLAGS" ["SERVER ENV"]  -> waits for /health (up to 7 min), prints VRAM used
start_server() {
  stop_server >/dev/null; sleep 4
  MIRAI_LABEL="$1" MIRAI_CTX="$2" MIRAI_EXTRA="$3" MIRAI_SERVER_ENV="${4:-}" MIRAI_PORT="$PORT" \
    powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tooling/serve.ps1"
  local ok=0 i
  for i in $(seq 1 140); do
    sleep 3
    if curl -s -m 3 "$BASE/health" 2>/dev/null | grep -q '"ok"'; then ok=1; break; fi
    # the PID file holds llama-server's PID, or cmd.exe's with MIRAI_CAPTURE_STDERR: give up when it is gone
    if [ -f "$ROOT/logs/$1.pid" ] && ! tasklist //FI "PID eq $(cat "$ROOT/logs/$1.pid")" 2>/dev/null | grep -q -E "llama-server|cmd\.exe"; then break; fi
  done
  echo "$1 health=$ok vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -1)"
  [ $ok = 1 ] || { echo "--- last log lines:"; tail -5 "$ROOT/logs/$1.log"; }
  return $(( 1 - ok ))
}

# identity against a stock dump: prints "N of 5 identical"
greedy_identity() { # DUMP [--think]
  PYTHONUTF8=1 python "$ROOT/bench/compare_servers.py" --base "$BASE" --against "$ROOT/receipts/mirai-port/$1" --n 200 ${2:-} 2>&1 \
    | awk '/^SAME/{s++} /^DIFF/{d++} END{printf "%d of %d identical\n", s, s+d}'
}

# decode/prefill at a depth, from the server's own timings
tps_at() { PYTHONUTF8=1 python "$ROOT/bench/quick_tps.py" --base "$BASE" --key-file "$ROOT/artifacts/api_key.txt" --depth "$1" 2>&1 | tail -1; }
