#!/bin/sh
set -eu

BACKUP_TOOL=/app/deploy/fileslink-backup.sh

echo "[render] Starting OpenClaw Render entrypoint..."

# ------------------------------------------------------------
# 1. Restore persistent state
# ------------------------------------------------------------

if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
    echo "[render] Restoring OpenClaw state from T Cloud..."

    "$BACKUP_TOOL" restore || \
        echo "[render] WARNING: FilesLink restore failed; continuing with ephemeral state." >&2
fi

# ------------------------------------------------------------
# 2. Configure Render reverse proxy
# ------------------------------------------------------------

echo "[render] Configuring trusted Render proxy..."

node openclaw.mjs config set \
    gateway.trustedProxies \
    '["127.0.0.1","::1"]' || \
    echo "[render] WARNING: Could not configure trustedProxies." >&2

# Keep normal token authentication.
# Do NOT configure gateway.auth.mode as trusted-proxy.

# ------------------------------------------------------------
# 3. Configure Control UI origin
# ------------------------------------------------------------

if [ -n "${RENDER_EXTERNAL_URL:-}" ]; then
    echo "[render] Configuring Control UI origin: $RENDER_EXTERNAL_URL"

    node openclaw.mjs config set \
        gateway.controlUi.allowedOrigins \
        "[\"${RENDER_EXTERNAL_URL}\"]" || \
        echo "[render] WARNING: Could not configure Control UI origin." >&2
fi

# ------------------------------------------------------------
# 4. Render port
# ------------------------------------------------------------

PORT_VALUE="${PORT:-10000}"

echo "[render] Gateway port: $PORT_VALUE"

# ------------------------------------------------------------
# 5. Start Gateway
# ------------------------------------------------------------

echo "[render] Starting gateway..."

if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    echo "[render] ERROR: OPENCLAW_GATEWAY_TOKEN is not set." >&2
    exit 1
fi

"$@" \
    --port "$PORT_VALUE" \
    --token "$OPENCLAW_GATEWAY_TOKEN" &

GATEWAY_PID=$!

# ------------------------------------------------------------
# 6. Wait for Gateway
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
# 7. Optional dashboard owner URL
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
            echo ""
        fi
    fi
fi

# ------------------------------------------------------------
# 8. Periodic FilesLink backup
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
# 9. Keep Gateway as main process
# ------------------------------------------------------------

wait "$GATEWAY_PID"
