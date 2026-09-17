#!/bin/sh
set -eu

BIN_DIR="${CALLBRIDGE_BIN_DIR:-/var/jb/usr/local/bin}"
DATA_ROOT="${CALLBRIDGE_DATA_ROOT:-/var/mobile/CallBridgeResearch/runs}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$DATA_ROOT/$RUN_ID"

mkdir -p "$RUN_DIR"

"$BIN_DIR/call-monitor" >"$RUN_DIR/call-monitor.log" 2>&1 &
echo "$!" >"$RUN_DIR/call-monitor.pid"

"$BIN_DIR/call-recorder" speaker "$RUN_DIR/downlink-speaker.caf" \
  >"$RUN_DIR/downlink-speaker.log" 2>&1 &
echo "$!" >"$RUN_DIR/downlink-speaker.pid"

"$BIN_DIR/call-recorder" microphone "$RUN_DIR/uplink-microphone.caf" \
  >"$RUN_DIR/uplink-microphone.log" 2>&1 &
echo "$!" >"$RUN_DIR/uplink-microphone.pid"

printf '%s\n' "$RUN_DIR" >"$DATA_ROOT/current-run"
chmod 644 "$DATA_ROOT/current-run" "$RUN_DIR"/*.pid

sleep 2

echo "CallBridge duplex capture started"
echo "Run directory: $RUN_DIR"
echo "Processes:"
for pid_file in "$RUN_DIR"/*.pid; do
  pid="$(cat "$pid_file")"
  ps -p "$pid" -o pid=,user=,stat=,command= || true
done

