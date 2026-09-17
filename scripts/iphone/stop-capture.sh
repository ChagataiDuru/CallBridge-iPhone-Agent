#!/bin/sh
set -eu

DATA_ROOT="${CALLBRIDGE_DATA_ROOT:-/var/mobile/CallBridgeResearch/runs}"
RUN_DIR="${1:-}"

if [ -z "$RUN_DIR" ]; then
  if [ ! -f "$DATA_ROOT/current-run" ]; then
    echo "No current run file: $DATA_ROOT/current-run" >&2
    exit 1
  fi
  RUN_DIR="$(cat "$DATA_ROOT/current-run")"
fi

if [ ! -d "$RUN_DIR" ]; then
  echo "Run directory does not exist: $RUN_DIR" >&2
  exit 1
fi

for pid_file in "$RUN_DIR"/*.pid; do
  [ -f "$pid_file" ] || continue
  pid="$(cat "$pid_file")"
  kill -INT "$pid" 2>/dev/null || true
done

sleep 4

echo "CallBridge capture stopped"
echo "Run directory: $RUN_DIR"
ls -lh "$RUN_DIR"

