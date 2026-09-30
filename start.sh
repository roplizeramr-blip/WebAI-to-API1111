#!/bin/sh
set -eu

RUNTIME_DIR="${RUNTIME_DIR:-/app/runtime}"

mkdir -p "$RUNTIME_DIR/auth" "$RUNTIME_DIR/conversations" "$RUNTIME_DIR/cache"

# Railway mounts Volumes as root. Prepare the persistent directory for the
# application's non-root Playwright user before dropping privileges.
PW_UID="$(id -u pwuser)"
PW_GID="$(id -g pwuser)"
chown -R "$PW_UID:$PW_GID" "$RUNTIME_DIR" 2>/dev/null || true

exec su -s /bin/sh pwuser -c 'exec python src/run.py --host 0.0.0.0 --port ${PORT:-6969}'
