#!/bin/sh
set -eu

RUNTIME_DIR="${RUNTIME_DIR:-/app/runtime}"
export RUNTIME_DIR
export AUTH_STATE_DIR="${AUTH_STATE_DIR:-$RUNTIME_DIR/auth}"
export CONVERSATION_SNAPSHOT_DB="${CONVERSATION_SNAPSHOT_DB:-$RUNTIME_DIR/conversations/conversation_snapshots.db}"
export PYTHONPATH="${PYTHONPATH:-/app/src}"

: "${BROWSER_PASSWORD:?Set BROWSER_PASSWORD in Railway Variables}"
: "${VNC_PASSWORD:?Set VNC_PASSWORD in Railway Variables}"
BROWSER_USERNAME="${BROWSER_USERNAME:-admin}"

if [ "${#VNC_PASSWORD}" -ne 8 ]; then
    echo "VNC_PASSWORD must be exactly 8 characters for x11vnc." >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR/auth" "$RUNTIME_DIR/conversations" "$RUNTIME_DIR/cache" "$RUNTIME_DIR/vnc"

PW_UID="$(id -u pwuser)"
PW_GID="$(id -g pwuser)"
chown -R "$PW_UID:$PW_GID" "$RUNTIME_DIR" 2>/dev/null || true

# Protect the public noVNC page with HTTP Basic Auth.
rm -f /tmp/browser.htpasswd
printf '%s\n' "$BROWSER_PASSWORD" | htpasswd -B -i -c /tmp/browser.htpasswd "$BROWSER_USERNAME" >/dev/null
chmod 600 /tmp/browser.htpasswd

# x11vnc uses an 8-character VNC password. The HTTP Basic Auth above is the
# stronger outer gate; the VNC password is an additional defense in depth.
x11vnc -storepasswd "$VNC_PASSWORD" "$RUNTIME_DIR/vnc/passwd" >/dev/null
chmod 600 "$RUNTIME_DIR/vnc/passwd"
chown "$PW_UID:$PW_GID" "$RUNTIME_DIR/vnc/passwd"

DISPLAY="${DISPLAY:-:99}"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1920x1080x24 -ac +extension GLX +render -noreset >/tmp/xvfb.log 2>&1 &
XVFB_PID=$

fluxbox >/tmp/fluxbox.log 2>&1 &
FLUXBOX_PID=$

x11vnc -display "$DISPLAY" -localhost -forever -shared -rfbport 5900 -rfbauth "$RUNTIME_DIR/vnc/passwd" -noxdamage >/tmp/x11vnc.log 2>&1 &
VNC_PID=$

websockify --web=/usr/share/novnc 6080 127.0.0.1:5900 >/tmp/websockify.log 2>&1 &
WEBSOCKIFY_PID=$

PORT="${PORT:-8080}"
sed "s/__RAILWAY_PORT__/$PORT/" /app/nginx.conf >/tmp/nginx.conf
nginx -c /tmp/nginx.conf -g 'daemon off;' >/tmp/nginx.log 2>&1 &
NGINX_PID=$

cleanup() {
    kill "$APP_PID" "$BOOTSTRAP_PID" "$INPUT_KEEPALIVE_PID" "$NGINX_PID" "$WEBSOCKIFY_PID" "$VNC_PID" "$FLUXBOX_PID" "$XVFB_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# Keep verify_login.py's stdin open. This allows its background auto-save loop
# to remain alive without requiring a real terminal/ENTER key.
rm -f /tmp/gemini-login-stdin
mkfifo /tmp/gemini-login-stdin
(
    while :; do
        sleep 3600
    done
) >/tmp/gemini-login-stdin &
INPUT_KEEPALIVE_PID=$

su -s /bin/sh pwuser -c 'exec python verify_login.py' </tmp/gemini-login-stdin &
BOOTSTRAP_PID=$

su -s /bin/sh pwuser -c 'exec python src/run.py --host 0.0.0.0 --port 6969' &
APP_PID=$

wait "$APP_PID"
