#!/bin/sh
set -eu

BACKUP_TOOL=/app/deploy/fileslink-backup.sh

echo "[render] Starting OpenClaw..."

# Restore persistent state
if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
    echo "[render] Restoring state from T Cloud..."
    "$BACKUP_TOOL" restore || \
        echo "[render] WARNING: T Cloud restore failed; continuing." >&2
fi

# Render supplies the public port.
PORT_VALUE="${PORT:-10000}"

echo "[render] Gateway port: $PORT_VALUE"

# Start periodic backup without starting additional Node processes.
INTERVAL="${FILESLINK_BACKUP_INTERVAL_SECONDS:-86400}"

if [ -x "$BACKUP_TOOL" ] && \
   [ -n "${FILESLINK_API_BASE_URL:-}" ] && \
   [ "$INTERVAL" -gt 0 ]; then
    (
        while sleep "$INTERVAL"; do
            echo "[render] Running T Cloud backup..."
            "$BACKUP_TOOL" backup || \
                echo "[render] WARNING: backup failed." >&2
        done
    ) &
fi

echo "[render] Starting gateway..."

if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    exec "$@" \
        --port "$PORT_VALUE" \
        --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "[render] ERROR: OPENCLAW_GATEWAY_TOKEN is not set." >&2
    exit 1
fi
