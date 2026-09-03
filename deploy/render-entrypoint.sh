#!/bin/sh

set -eu

BACKUP_TOOL=/app/deploy/fileslink-backup.sh

echo "[render] Starting OpenClaw Render entrypoint..."

# ============================================================
# T CLOUD / FILESLINK RESTORE
# ============================================================

echo "[render] Restoring OpenClaw state from T Cloud..."

if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
    "$BACKUP_TOOL" restore || \
        echo "[render] WARNING: FilesLink restore failed; continuing with current state." >&2
fi

# ============================================================
# T CLOUD / FILESLINK BACKUP LOOP
# ============================================================

interval=${FILESLINK_BACKUP_INTERVAL_SECONDS:-86400}

case "$interval" in
    ''|*[!0-9]*)
        interval=86400
        ;;
esac

if [ "$interval" -gt 0 ] &&
   [ -x "$BACKUP_TOOL" ] &&
   [ -n "${FILESLINK_API_BASE_URL:-}" ]; then

    (
        while sleep "$interval"; do
            "$BACKUP_TOOL" backup || \
                echo "[render] WARNING: scheduled FilesLink backup failed." >&2
        done
    ) &
fi

# ============================================================
# RENDER / OPENCLAW CONFIGURATION
# ============================================================

PORT="${OPENCLAW_GATEWAY_PORT:-10000}"

echo "[render] Gateway port: $PORT"

# OpenClaw requires authentication when binding to a non-loopback
# address. Render supplies OPENCLAW_GATEWAY_TOKEN through the
# Render environment.

if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    echo "[render] ERROR: OPENCLAW_GATEWAY_TOKEN is not set."
    echo "[render] Set OPENCLAW_GATEWAY_TOKEN in Render environment variables."
    exit 1
fi

# ============================================================
# START GATEWAY
# ============================================================

echo "[render] Starting gateway..."

"$@" \
    --token "$OPENCLAW_GATEWAY_TOKEN" \
    > /tmp/openclaw-gateway.log 2>&1 &

GATEWAY_PID=$!

echo "[render] Gateway PID: $GATEWAY_PID"
echo "[render] Waiting for gateway..."

# ============================================================
# WAIT FOR GATEWAY
# ============================================================

READY=0

i=0

while [ "$i" -lt 90 ]; do

    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
        echo "[render] ERROR: Gateway exited before becoming ready."
        echo "------------------------------------------------------------"
        cat /tmp/openclaw-gateway.log || true
        echo "------------------------------------------------------------"
        exit 1
    fi

    if grep -q "\[gateway\] ready" /tmp/openclaw-gateway.log 2>/dev/null; then
        READY=1
        break
    fi

    sleep 1
    i=$((i + 1))
done

if [ "$READY" -ne 1 ]; then
    echo "[render] WARNING: Gateway did not report ready within 90 seconds."
    echo "[render] Continuing because the process is still running."
fi

echo "[render] Gateway is ready."

# ============================================================
# DASHBOARD OWNER LINK
# ============================================================
#
# OpenClaw's supported remote-browser bootstrap is:
#
#     openclaw dashboard --json
#
# It creates a short-lived, single-use browser handoff.
# It is NOT the same thing as automatically approving every
# device.
#
# We print the result to Render logs so the owner can retrieve
# the current dashboard handoff after a deployment.
# ============================================================

if [ "${OPENCLAW_RENDER_PRINT_DASHBOARD:-true}" = "true" ]; then

    echo "[render] Generating dashboard owner link..."

    DASHBOARD_OUTPUT="$(
        node openclaw.mjs dashboard --json 2>&1 || true
    )"

    echo "============================================================"
    echo "[render] OPENCLAW DASHBOARD HANDOFF"
    echo "============================================================"
    echo "$DASHBOARD_OUTPUT"
    echo "============================================================"
    echo "[render] The browserUrl above is short-lived and intended"
    echo "[render] for the browser that will be paired."
    echo "============================================================"

fi

# ============================================================
# DEVICE PAIRING INFORMATION
# ============================================================
#
# We DO NOT automatically approve arbitrary browser requests.
# A pending browser must be explicitly approved with:
#
#   openclaw devices list
#   openclaw devices approve <requestId>
#
# This preserves OpenClaw's device-authentication security.
# ============================================================

echo "[render] Device pairing is enabled."
echo "[render] New Control UI browsers require one-time approval."
echo "[render] Use 'openclaw devices list' and approve the exact request."

# ============================================================
# FORWARD GATEWAY LOGS
# ============================================================

tail -F /tmp/openclaw-gateway.log &
LOG_PID=$!

cleanup() {
    echo "[render] Shutting down..."

    kill "$LOG_PID" 2>/dev/null || true
    kill "$GATEWAY_PID" 2>/dev/null || true

    wait "$GATEWAY_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

# Keep the Render service attached to the Gateway process.
wait "$GATEWAY_PID"
