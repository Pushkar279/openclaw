#!/bin/sh
set -eu

BACKUP_TOOL=/app/deploy/fileslink-backup.sh

echo "[render] Starting OpenClaw Render entrypoint..."

# ------------------------------------------------------------
# 1. Restore persistent OpenClaw state from T Cloud
# ------------------------------------------------------------

if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
    echo "[render] Restoring OpenClaw state from T Cloud..."

    "$BACKUP_TOOL" restore || \
        echo "[render] WARNING: FilesLink restore failed; continuing with ephemeral state." >&2
fi

# ------------------------------------------------------------
# 2. Configure Gateway authentication
# ------------------------------------------------------------

if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    echo "[render] ERROR: OPENCLAW_GATEWAY_TOKEN is not set." >&2
    echo "[render] Add OPENCLAW_GATEWAY_TOKEN to the Render environment." >&2
    exit 1
fi

echo "[render] Configuring gateway token authentication..."

node openclaw.mjs config set \
    gateway.auth.mode \
    token

node openclaw.mjs config set \
    gateway.auth.token \
    "$OPENCLAW_GATEWAY_TOKEN"

echo "[render] Gateway token authentication configured."

# ------------------------------------------------------------
# 3. Configure Render reverse proxy
# ------------------------------------------------------------

echo "[render] Configuring trusted Render proxy..."

node openclaw.mjs config set \
    gateway.trustedProxies \
    '["127.0.0.1","::1"]' || \
    echo "[render] WARNING: Could not configure trustedProxies." >&2

# ------------------------------------------------------------
# 4. Configure Control UI origin
# ------------------------------------------------------------

if [ -n "${RENDER_EXTERNAL_URL:-}" ]; then
    echo "[render] Configuring Control UI origin: $RENDER_EXTERNAL_URL"

    node openclaw.mjs config set \
        gateway.controlUi.allowedOrigins \
        "[\"${RENDER_EXTERNAL_URL}\"]" || \
        echo "[render] WARNING: Could not configure Control UI origin." >&2
fi

# ------------------------------------------------------------
# 5. Render PORT
# ------------------------------------------------------------

PORT_VALUE="${PORT:-10000}"

echo "[render] Gateway port: $PORT_VALUE"

# ------------------------------------------------------------
# 6. Start Gateway
#
# Authentication is already configured above.
# We intentionally do NOT pass a second --token argument.
# ------------------------------------------------------------

echo "[render] Starting gateway..."

"$@" \
    --port "$PORT_VALUE" &

GATEWAY_PID=$!

# ------------------------------------------------------------
# 7. Wait for Gateway to become ready
# ------------------------------------------------------------

echo "[render] Waiting for gateway..."

READY=0

i=1

while [ "$i" -le 60 ]; do

    if curl -fsS \
        --connect-timeout 2 \
        --max-time 3 \
        "http://127.0.0.1:${PORT_VALUE}/startupz" >/dev/null 2>&1; then

        READY=1
        break
    fi

    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
        echo "[render] ERROR: Gateway exited during startup." >&2
        wait "$GATEWAY_PID"
        exit 1
    fi

    sleep 2

    i=$((i + 1))
done

if [ "$READY" -ne 1 ]; then
    echo "[render] WARNING: Gateway did not report ready within timeout." >&2
else
    echo "[render] Gateway is ready."
fi

# ------------------------------------------------------------
# 8. Generate one-time owner dashboard URL
#
# Enable with:
#
# OPENCLAW_RENDER_PRINT_DASHBOARD=true
#
# ------------------------------------------------------------

if [ "${OPENCLAW_RENDER_PRINT_DASHBOARD:-false}" = "true" ]; then

    echo "[render] Generating one-time dashboard owner link..."

    DASHBOARD_JSON=$(
        node openclaw.mjs dashboard --json 2>/dev/null || true
    )

    if [ -n "$DASHBOARD_JSON" ]; then

        DASHBOARD_URL=$(
            node --input-type=module - "$DASHBOARD_JSON" <<'NODE'
const raw = process.argv[2];

try {
    const data = JSON.parse(raw);

    if (data.ok === false) {
        process.exit(1);
    }

    process.stdout.write(data.browserUrl || "");
} catch {
    process.exit(1);
}
NODE
        )

        if [ -n "$DASHBOARD_URL" ]; then

            echo ""
            echo "============================================================"
            echo " OPENCLAW ONE-TIME OWNER DASHBOARD URL"
            echo "============================================================"
            echo "$DASHBOARD_URL"
            echo "============================================================"
            echo " Open this URL in your browser."
            echo " It is short-lived and intended for the owner only."
            echo "============================================================"
            echo ""

        else

            echo "[render] WARNING: dashboard --json did not return browserUrl." >&2
            echo "[render] Raw dashboard response:"
            echo "$DASHBOARD_JSON"

        fi

    else

        echo "[render] WARNING: Could not generate dashboard owner link." >&2

    fi
fi

# ------------------------------------------------------------
# 9. Periodic FilesLink / T Cloud backup
# ------------------------------------------------------------

interval=${FILESLINK_BACKUP_INTERVAL_SECONDS:-86400}

case "$interval" in
    ''|*[!0-9]*)
        interval=86400
        ;;
esac

if [ "$interval" -gt 0 ] && \
   [ -x "$BACKUP_TOOL" ] && \
   [ -n "${FILESLINK_API_BASE_URL:-}" ]; then

    (
        while sleep "$interval"; do

            echo "[render] Running scheduled T Cloud backup..."

            "$BACKUP_TOOL" backup || \
                echo "[render] WARNING: scheduled FilesLink backup failed." >&2

        done
    ) &
fi

# ------------------------------------------------------------
# 10. Keep Gateway as the main process
# ------------------------------------------------------------

wait "$GATEWAY_PID"
