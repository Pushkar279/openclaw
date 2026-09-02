#!/bin/sh
set -eu

BACKUP_TOOL=/app/deploy/fileslink-backup.sh

if [ "${FILESLINK_RESTORE_ON_START:-true}" = "true" ] && [ -x "$BACKUP_TOOL" ]; then
  "$BACKUP_TOOL" restore || echo "WARNING: FilesLink restore failed; continuing with the current ephemeral state." >&2
fi

interval=${FILESLINK_BACKUP_INTERVAL_SECONDS:-86400}
case "$interval" in
  ''|*[!0-9]*) interval=86400 ;;
esac
if [ "$interval" -gt 0 ] && [ -x "$BACKUP_TOOL" ] && [ -n "${FILESLINK_API_BASE_URL:-}" ]; then
  (
    while sleep "$interval"; do
      "$BACKUP_TOOL" backup || echo "WARNING: scheduled FilesLink backup failed." >&2
    done
  ) &
fi

exec "$@"
