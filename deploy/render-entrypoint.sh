#!/bin/sh

set -eu

BACKUP_TOOL=/app/deploy/fileslink-backup.sh

echo "[render] Starting OpenClaw Render entrypoint..."

# ------------------------------------------------------------
# 1. Restore persistent state from T Cloud
# ------------------------------------------------------------

if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
    echo "[render] Restoring OpenClaw state from T Cloud..."

    "$BACKUP_TOOL" restore || \
        echo "[render] WARNING: FilesLink restore failed; continuing with current ephemeral state." >&2
fi

# ------------------------------------------------------------
# 2. Configure Render proxy handling
# ------------------------------------------------------------
#
# Render places the service behind its reverse proxy.
# OpenClaw therefore needs to trust the local proxy source
# so it can correctly attribute X-Forwarded-For.
#
# We use OpenClaw's config command rather than replacing
# openclaw.json, so existing T Cloud-restored configuration
# remains intact.
# ------------------------------------------------------------

echo "[render] Configuring trusted Render proxy..."

node openclaw.mjs config set gateway.trustedProxies '["127.0.0.1"]' || \
    echo "[render] WARNING: Could not configure trustedProxies automatically." >&2

# ------------------------------------------------------------
# 3. Allow the Render Control UI origin
# ------------------------------------------------------------
#
# Render supplies RENDER_EXTERNAL_URL automatically for web
# services. We add it to OpenClaw's Control UI allowed origins.
#
# This prevents the next common error:
# "origin not allowed"
# ------------------------------------------------------------

if [ -n "${RENDER_EXTERNAL_URL:-}" ]; then
    echo "[render] Configuring Control UI origin: $RENDER_EXTERNAL_URL"

    node openclaw.mjs config set \
        gateway.controlUi.allowedOrigins \
        "[\"${RENDER_EXTERNAL_URL}\"]" || \
        echo "[render] WARNING: Could not configure Control UI origin." >&2
fi

# ------------------------------------------------------------
# 4. Start the periodic T Cloud backup process
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
# 5. Use Render's PORT
# ------------------------------------------------------------
#
# Render expects a web service to listen on the PORT it assigns.
# If PORT isn't available for some reason, fall back to 10000.
# ------------------------------------------------------------

PORT_VALUE="${PORT:-10000}"

echo "[render] Gateway port: $PORT_VALUE"

# ------------------------------------------------------------
# 6. Start OpenClaw with authentication
# ------------------------------------------------------------

if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then

    echo "[render] Gateway token authentication enabled."

    exec "$@" \
        --port "$PORT_VALUE" \
        --token "$OPENCLAW_GATEWAY_TOKEN"

else

    echo "[render] WARNING: OPENCLAW_GATEWAY_TOKEN is not set." >&2

    exec "$@" \
        --port "$PORT_VALUE"

fi
