#!/bin/sh
set -eu

PHONE_HOST="${1:-192.168.1.109}"
PHONE_USER="${CALLBRIDGE_PHONE_USER:-mobile}"
REMOTE_ROOT="${CALLBRIDGE_REMOTE_ROOT:-/var/mobile/CallBridgeResearch/runs}"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
LOCAL_ROOT="$PROJECT_ROOT/evidence/private"

REMOTE_RUN="$(ssh "$PHONE_USER@$PHONE_HOST" "cat '$REMOTE_ROOT/current-run'")"
RUN_ID="$(basename "$REMOTE_RUN")"
LOCAL_RUN="$LOCAL_ROOT/$RUN_ID"

mkdir -p "$LOCAL_RUN"
scp -r "$PHONE_USER@$PHONE_HOST:$REMOTE_RUN/." "$LOCAL_RUN/"

if command -v shasum >/dev/null 2>&1; then
  (
    cd "$LOCAL_RUN"
    shasum -a 256 ./* >checksums.sha256
  )
fi

echo "Fetched: $LOCAL_RUN"
for audio_file in "$LOCAL_RUN"/*.caf; do
  [ -f "$audio_file" ] || continue
  afinfo "$audio_file" || true
done

