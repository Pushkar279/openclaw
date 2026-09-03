#!/bin/sh

set -eu

echo "[render] Starting OpenClaw Render entrypoint..."

# ============================================================
# Configuration
# ============================================================

BACKUP_TOOL="/app/deploy/fileslink-backup.sh"

PORT="${OPENCLAW_GATEWAY_PORT:-10000}"
RENDER_URL="${RENDER_EXTERNAL_URL:-}"

# ============================================================
# Restore OpenClaw state
# ============================================================

echo "[render] Restoring OpenClaw state from T Cloud..."

if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
    "$BACKUP_TOOL" restore || \
        echo "[render] WARNING: FilesLink restore failed; continuing."
else
    echo "[render] No FilesLink restore configured."
fi

# ============================================================
# Background backup
# ============================================================

INTERVAL="${FILESLINK_BACKUP_INTERVAL_SECONDS:-86400}"

case "$INTERVAL" in
    ''|*[!0-9]*)
        INTERVAL=86400
        ;;
esac

if [ "$INTERVAL" -gt 0 ] \
    && [ -x "$BACKUP_TOOL" ] \
    && [ -n "${FILESLINK_API_BASE_URL:-}" ]; then

    (
        while sleep "$INTERVAL"; do
            echo "[render] Running scheduled T Cloud backup..."

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

node openclaw.mjs config set \
    gateway.auth.mode \
    token || true

node openclaw.mjs config set \
    gateway.auth.token \
    "$OPENCLAW_GATEWAY_TOKEN" || true

echo "[render] Gateway token authentication configured."

# ============================================================
# Render proxy
# ============================================================

echo "[render] Configuring trusted Render proxy..."

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
echo "[render] Waiting for gateway..."

"$@" --token "$OPENCLAW_GATEWAY_TOKEN" &

GATEWAY_PID=$!

cleanup() {
    echo "[render] Stopping Gateway..."

    if kill -0 "$GATEWAY_PID" 2>/dev/null; then
        kill "$GATEWAY_PID" 2>/dev/null || true
    fi
}

trap cleanup INT TERM EXIT

# ============================================================
# Wait for Gateway HTTP server
# ============================================================

GATEWAY_READY=0
i=0

while [ "$i" -lt 120 ]; do

    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
        echo "[render] ERROR: Gateway process exited."
        wait "$GATEWAY_PID" || true
        exit 1
    fi

    if node -e '
        const http = require("http");

        const port = Number(
            process.env.OPENCLAW_GATEWAY_PORT || 10000
        );

        const req = http.get(
            {
                host: "127.0.0.1",
                port: port,
                path: "/",
                timeout: 1500
            },
            res => {
                process.exit(
                    res.statusCode >= 200 &&
                    res.statusCode < 500
                        ? 0
                        : 1
                );
            }
        );

        req.on("error", () => process.exit(1));

        req.on("timeout", () => {
            req.destroy();
            process.exit(1);
        });
    '; then

        GATEWAY_READY=1
        break

    fi

    sleep 2
    i=$((i + 1))

done

if [ "$GATEWAY_READY" -eq 1 ]; then
    echo "[render] Gateway HTTP server is responding."
else
    echo "[render] WARNING: Gateway did not respond during startup check."
fi

echo "[render] Gateway is ready."

# ============================================================
# DEVICE PAIRING
# ============================================================
#
# OpenClaw requires a new browser/device to be paired.
#
# IMPORTANT:
# We DO NOT approve a request until it actually exists.
#
# The browser creates the pairing request when it attempts
# to connect. Therefore we poll for pending requests.
#
# We also approve the EXACT requestId instead of using
# "approve --latest", because newer OpenClaw versions can
# treat --latest as a selection/preview operation.
#
# ============================================================

echo "[render] Device pairing monitor started."

(
    # Give the Control UI/gateway a little time to finish startup.
    sleep 8

    ATTEMPTS=0

    while [ "$ATTEMPTS" -lt 180 ]; do

        # ----------------------------------------------------
        # Ask the local gateway for pending pairing requests.
        # ----------------------------------------------------

        PAIRING_OUTPUT="$(
            node openclaw.mjs devices list \
                --token "$OPENCLAW_GATEWAY_TOKEN" \
                --json 2>/dev/null || true
        )"

        if [ -n "$PAIRING_OUTPUT" ]; then

            # ------------------------------------------------
            # Extract the newest pending request ID.
            # ------------------------------------------------

            REQUEST_ID="$(
                printf '%s\n' "$PAIRING_OUTPUT" |
                node -e '
                    let input = "";

                    process.stdin.on("data", chunk => {
                        input += chunk;
                    });

                    process.stdin.on("end", () => {
                        try {
                            const data = JSON.parse(input.trim());

                            let pending =
                                data.pending ||
                                data.pendingRequests ||
                                data.requests ||
                                [];

                            if (!Array.isArray(pending)) {
                                pending = [];
                            }

                            if (pending.length === 0) {
                                process.exit(0);
                            }

                            /*
                             * Find the newest valid request.
                             * Prefer timestamp when available.
                             */

                            const valid = pending.filter(
                                item =>
                                    item &&
                                    typeof item.requestId === "string"
                            );

                            if (valid.length === 0) {
                                process.exit(0);
                            }

                            valid.sort((a, b) => {
                                const ta =
                                    Number(a.ts || a.createdAt || 0);

                                const tb =
                                    Number(b.ts || b.createdAt || 0);

                                return ta - tb;
                            });

                            const newest =
                                valid[valid.length - 1];

                            process.stdout.write(
                                newest.requestId
                            );

                        } catch (_) {
                            process.exit(0);
                        }
                    });
                ' 2>/dev/null || true
            )"

            # ------------------------------------------------
            # Approve exact request.
            # ------------------------------------------------

            if [ -n "$REQUEST_ID" ]; then

                echo "[render] Pending device pairing request detected."
                echo "[render] Approving current device..."

                APPROVE_OUTPUT="$(
                    node openclaw.mjs devices approve \
                        "$REQUEST_ID" \
                        --token "$OPENCLAW_GATEWAY_TOKEN" \
                        --json 2>&1 || true
                )"

                if printf '%s\n' "$APPROVE_OUTPUT" |
                    grep -qiE \
                    '"approved"[[:space:]]*:[[:space:]]*true|approved'; then

                    echo "[render] Device pairing approved."

                    # ------------------------------------------------
                    # Give the browser time to receive the approval.
                    # ------------------------------------------------

                    sleep 3

                else

                    echo "[render] Device approval did not succeed."
                    echo "[render] Waiting for the next pairing request."

                fi

            fi

        fi

        sleep 3
        ATTEMPTS=$((ATTEMPTS + 1))

    done

    echo "[render] Device pairing monitor finished."

) &

PAIRING_MONITOR_PID=$!

# ============================================================
# Owner dashboard
# ============================================================

echo "[render] Generating one-time dashboard owner link..."

DASHBOARD_OUTPUT="$(
    node openclaw.mjs dashboard --json 2>&1 || true
)"

DASHBOARD_URL="$(
    printf '%s\n' "$DASHBOARD_OUTPUT" |
    node -e '
        let input = "";

        process.stdin.on("data", chunk => {
            input += chunk;
        });

        process.stdin.on("end", () => {
            try {
                const data = JSON.parse(input.trim());

                if (data && data.browserUrl) {
                    process.stdout.write(
                        String(data.browserUrl)
                    );
                    return;
                }

                if (data && data.url) {
                    process.stdout.write(
                        String(data.url)
                    );
                }

            } catch (_) {
                // Dashboard command may output non-JSON logs.
            }
        });
    ' 2>/dev/null || true
)"

if [ -n "$DASHBOARD_URL" ]; then

    echo ""
    echo "============================================================"
    echo " OPENCLAW ONE-TIME OWNER DASHBOARD"
    echo "============================================================"
    echo "$DASHBOARD_URL"
    echo "============================================================"
    echo ""
    echo "[render] Open this URL in your browser."
    echo "[render] Treat this URL like a secret."
    echo ""

else

    echo "[render] Owner dashboard URL was not returned."
    echo "[render] Use the Render URL with the configured gateway token."

fi

# ============================================================
# Final status
# ============================================================

echo "[render] Gateway process: $GATEWAY_PID"
echo "[render] Device pairing monitor: $PAIRING_MONITOR_PID"
echo "[render] Render service is running."

# ============================================================
# Keep container alive
# ============================================================

wait "$GATEWAY_PID"
    
echo "[render] ================================================"
echo "[render] DEVICE PAIRING DIAGNOSTIC"
echo "[render] ================================================"

echo "[render] Checking OpenClaw device CLI..."

node openclaw.mjs devices --help 2>&1 || true

echo "[render] Checking pending devices..."

node openclaw.mjs devices list \
    --token "$OPENCLAW_GATEWAY_TOKEN" \
    --json 2>&1 || true

echo "[render] ================================================"
echo "[render] END DEVICE PAIRING DIAGNOSTIC"
echo "[render] ================================================"
