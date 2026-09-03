#!/bin/sh

set -eu

echo "[render] Starting OpenClaw Render entrypoint..."

# ============================================================
# Configuration
# ============================================================

BACKUP_TOOL=/app/deploy/fileslink-backup.sh

STATE_DIR="${OPENCLAW_STATE_DIR:-/tmp/.openclaw}"
PORT="${OPENCLAW_GATEWAY_PORT:-10000}"
RENDER_URL="${RENDER_EXTERNAL_URL:-}"

# ============================================================
# FilesLink / T Cloud restore
# ============================================================

echo "[render] Restoring OpenClaw state from T Cloud..."

if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
    "$BACKUP_TOOL" restore || \
        echo "[render] WARNING: FilesLink restore failed; continuing with current state." >&2
fi

# ============================================================
# Scheduled backup
# ============================================================

interval=${FILESLINK_BACKUP_INTERVAL_SECONDS:-86400}

case "$interval" in
    ''|*[!0-9]*)
        interval=86400
        ;;
esac

if [ "$interval" -gt 0 ] \
    && [ -x "$BACKUP_TOOL" ] \
    && [ -n "${FILESLINK_API_BASE_URL:-}" ]; then

    (
        while sleep "$interval"; do
            "$BACKUP_TOOL" backup || \
                echo "[render] WARNING: scheduled FilesLink backup failed." >&2
        done
    ) &
fi

# ============================================================
# Gateway authentication
# ============================================================

if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    echo "[render] ERROR: OPENCLAW_GATEWAY_TOKEN is not configured."
    exit 1
fi

echo "[render] Configuring gateway token authentication..."

# Configure token authentication in OpenClaw's persistent state.
node openclaw.mjs config set gateway.auth.mode token || true

node openclaw.mjs config set \
    gateway.auth.token \
    "$OPENCLAW_GATEWAY_TOKEN" || true

echo "[render] Gateway token authentication configured."

# ============================================================
# Render reverse proxy
# ============================================================

echo "[render] Configuring trusted Render proxy..."

# Render's public HTTPS proxy reaches the application locally.
# Keep this narrowly scoped to localhost.
node openclaw.mjs config set \
    gateway.trustedProxies \
    '["127.0.0.1"]' || true

# ============================================================
# Control UI origin
# ============================================================

if [ -n "$RENDER_URL" ]; then
    echo "[render] Configuring Control UI origin: $RENDER_URL"

    node openclaw.mjs config set \
        gateway.controlUi.allowedOrigins \
        "[\"$RENDER_URL\"]" || true
fi

# ============================================================
# Start Gateway
# ============================================================

echo "[render] Gateway port: $PORT"
echo "[render] Starting gateway..."

# The dockerCommand passes:
#
#   node openclaw.mjs gateway --bind lan --allow-unconfigured
#
# We add the token explicitly so the Gateway has authentication
# even on a completely fresh Render filesystem.

"$@" --token "$OPENCLAW_GATEWAY_TOKEN" &
GATEWAY_PID=$!

cleanup() {
    echo "[render] Stopping Gateway..."
    kill "$GATEWAY_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

# ============================================================
# Wait for Gateway
# ============================================================

echo "[render] Waiting for Gateway..."

READY=0

i=0
while [ "$i" -lt 90 ]; do

    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
        echo "[render] ERROR: Gateway process exited before becoming ready."
        wait "$GATEWAY_PID" || true
        exit 1
    fi

    # Try the local startup endpoint.
    if node -e '
        const http = require("http");
        const port = Number(process.env.OPENCLAW_GATEWAY_PORT || 10000);

        const req = http.get(
          {
            host: "127.0.0.1",
            port,
            path: "/startupz",
            timeout: 1500
          },
          res => {
            process.exit(res.statusCode >= 200 && res.statusCode < 500 ? 0 : 1);
          }
        );

        req.on("error", () => process.exit(1));
        req.on("timeout", () => {
          req.destroy();
          process.exit(1);
        });
    '; then
        READY=1
        break
    fi

    sleep 2
    i=$((i + 1))
done

if [ "$READY" -ne 1 ]; then
    echo "[render] WARNING: Gateway did not answer /startupz within the expected time."
    echo "[render] Continuing because the Gateway process is still running."
fi

echo "[render] Gateway is ready."

# ============================================================
# Generate owner dashboard handoff
# ============================================================

echo "[render] Generating one-time dashboard owner link..."

DASHBOARD_OUTPUT="$(node openclaw.mjs dashboard --json 2>&1 || true)"

# Do NOT print the complete JSON because it may contain
# authentication/bootstrap information.

BROWSER_URL="$(
    printf '%s\n' "$DASHBOARD_OUTPUT" |
    node -e '
        let input = "";

        process.stdin.on("data", chunk => {
            input += chunk;
        });

        process.stdin.on("end", () => {
            try {
                const obj = JSON.parse(input.trim());

                if (obj && obj.browserUrl) {
                    process.stdout.write(obj.browserUrl);
                }
            } catch (_) {
                // Ignore non-JSON output.
            }
        });
    ' 2>/dev/null || true
)"

if [ -n "$BROWSER_URL" ]; then

    echo ""
    echo "============================================================"
    echo " OPENCLAW ONE-TIME OWNER DASHBOARD URL"
    echo "============================================================"
    echo "$BROWSER_URL"
    echo "============================================================"
    echo ""
    echo "[render] IMPORTANT: Open this URL in the browser you want to pair."
    echo "[render] The URL is single-use and expires shortly."
    echo "[render] Do not share this URL with anyone."

else

    echo "[render] WARNING: Could not generate the owner dashboard URL."

    if printf '%s\n' "$DASHBOARD_OUTPUT" |
        grep -qi "not ready\|failed\|error"; then

        echo "[render] Dashboard command returned an error."
        echo "[render] Check Gateway startup and authentication."
    fi
fi

# ============================================================
# Keep Gateway in foreground
# ============================================================

echo "[render] OpenClaw Gateway process: $GATEWAY_PID"
echo "[render] Render service is running."

wait "$GATEWAY_PID"
