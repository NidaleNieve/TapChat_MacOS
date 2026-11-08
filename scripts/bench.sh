#!/bin/bash
# Measures TapChat: memory and CPU (idle, hidden and visible, CLI processes
# included), opening and scrolling a long chat, streaming a long answer, and
# removing attachments. Writes bench/<label>.json.
#
#   scripts/bench.sh <label>        e.g. scripts/bench.sh before
#
# It quits a running TapChat, launches /Applications/TapChat.app with
# --debug-hooks, and quits it again at the end. Your chats are not touched:
# the long benchmark chat is created, measured and deleted; the other
# scenarios use temporary chats.
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL="${1:?usage: scripts/bench.sh <label>}"
APP=/Applications/TapChat.app
OUT="bench/$LABEL.json"
TMP="$(mktemp -d)"
mkdir -p bench

# Sends a debug command to the app (DistributedNotification, see DebugHooks.swift).
cat > "$TMP/send.swift" <<'EOF'
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("local.tapchat.debug"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
EOF
swiftc -O "$TMP/send.swift" -o "$TMP/send" 2>/dev/null
send() { "$TMP/send" "$1"; }
# Waits until the app has written a result file.
wait_for() { for _ in $(seq 1 600); do [ -s "$1" ] && return 0; sleep 0.1; done; echo "timeout: $1" >&2; return 1; }

pid_of() { pgrep -x TapChat | head -1; }
# Memory as Activity Monitor counts it, in MB, for a process and its children (the CLIs).
footprint_mb() {
  local total=0
  for p in "$@"; do
    local v
    v=$(footprint -p "$p" 2>/dev/null | awk '/Footprint:/ { for (i=1;i<=NF;i++) if ($i=="Footprint:") { n=$(i+1); u=$(i+2); if (u=="KB") n/=1024; if (u=="GB") n*=1024; print n; exit } }')
    total=$(echo "$total + ${v:-0}" | bc -l)
  done
  printf "%.1f" "$total"
}
children() { pgrep -P "$1" | tr '\n' ' '; }
cpu_seconds() { ps -o time= -p "$1" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
# CPU used over an interval, as a percentage of one core.
cpu_percent() { local p=$1 s=$2 a b; a=$(cpu_seconds "$p"); sleep "$s"; b=$(cpu_seconds "$p"); echo "($b - $a) / $s * 100" | bc -l | xargs printf "%.2f"; }

osascript -e 'tell application id "local.tapchat" to quit' >/dev/null 2>&1 || true
pkill -x TapChat 2>/dev/null || true
sleep 1
open -a "$APP" --args --debug-hooks
sleep 3
PID=$(pid_of)
send hide; sleep 2

echo "measuring idle, hidden…"
HIDDEN_CPU=$(cpu_percent "$PID" 10)
HIDDEN_MB=$(footprint_mb "$PID")
HIDDEN_CHILDREN=$(children "$PID")

echo "measuring idle, visible (bar)…"
send show; send new; sleep 4
VIS_CPU=$(cpu_percent "$PID" 10)
KIDS=$(children "$PID")
VIS_APP_MB=$(footprint_mb "$PID")
VIS_TOTAL_MB=$(footprint_mb "$PID" $KIDS)
VIS_KIDS=$(echo $KIDS | wc -w | tr -d ' ')

echo "opening and scrolling a 300-message chat…"
send "bench-chat:150|$TMP/chat.json"; wait_for "$TMP/chat.json"
echo "streaming a long answer…"
send "bench-stream:12000|$TMP/stream.json"; wait_for "$TMP/stream.json"
echo "removing attachments…"
send "bench-attach:8|$TMP/attach.json"; wait_for "$TMP/attach.json"

echo "measuring idle, hidden, after use…"
send hide; sleep 4
AFTER_CPU=$(cpu_percent "$PID" 10)
AFTER_MB=$(footprint_mb "$PID")

python3 - "$OUT" "$TMP" <<EOF
import json, sys
out, tmp = sys.argv[1], sys.argv[2]
r = {
  "label": "$LABEL",
  "idleHidden": {"cpuPercent": $HIDDEN_CPU, "footprintMB": $HIDDEN_MB, "childProcesses": len("$HIDDEN_CHILDREN".split())},
  "idleVisible": {"cpuPercent": $VIS_CPU, "appFootprintMB": $VIS_APP_MB, "totalFootprintMB": $VIS_TOTAL_MB, "childProcesses": $VIS_KIDS},
  "idleHiddenAfterUse": {"cpuPercent": $AFTER_CPU, "footprintMB": $AFTER_MB},
}
for name in ("chat", "stream", "attach"):
    r[name] = json.load(open(f"{tmp}/{name}.json"))
json.dump(r, open(out, "w"), indent=2, sort_keys=True)
print(json.dumps(r, indent=2, sort_keys=True))
EOF

osascript -e 'tell application id "local.tapchat" to quit' >/dev/null 2>&1 || true
rm -rf "$TMP"
echo "→ $OUT"
