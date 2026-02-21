#!/usr/bin/env bash
set -euo pipefail

PID="${1:?pid required}"
OUT="${2:?out csv required}"
MODE="${3:-gateway}" # gateway | wasmedge_sum

echo "ts_ms,rss_kb,cpu_pct" > "$OUT"

ts_ms() { python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
}

sample_gateway() {
  local rss cpu
  rss="$(ps -o rss= -p "$PID" 2>/dev/null | awk '{print $1}' || true)"
  cpu="$(ps -o %cpu= -p "$PID" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${rss}" && -n "${cpu}" ]] || return 0
  echo "$(ts_ms),${rss},${cpu}" >> "$OUT"
}

# Sum RSS/CPU for all wasmedge processes (best-effort)
sample_wasmedge_sum() {
  # rss in KB, cpu in %
  local rss_sum cpu_sum
  rss_sum="$(ps -Ao comm,rss | awk '$1 ~ /^wasmedge/ {s+=$2} END{print s+0}')"
  cpu_sum="$(ps -Ao comm,%cpu | awk '$1 ~ /^wasmedge/ {s+=$2} END{printf "%.2f\n", s+0}')"
  echo "$(ts_ms),${rss_sum},${cpu_sum}" >> "$OUT"
}

while kill -0 "$PID" >/dev/null 2>&1; do
  if [[ "$MODE" == "gateway" ]]; then
    sample_gateway
  else
    sample_wasmedge_sum
  fi
  sleep 0.2
done
