#!/bin/bash
# Opt-in installer for the read-only log server (see log_server.py).
#
# Deliberately NOT wired into setup-lxc.sh: that script provisions prod
# LXCs too, and this server is meant for LXCs you explicitly want remote
# read access to (e.g. a dev/demo box), not a default on every deployment.
#
# Run this manually, once, from an already-cloned followerBot-deploy
# checkout on the LXC that should expose it (setup-lxc.sh clones this repo
# to /opt/followerbot-deploy already -- `git pull` there first to pick up
# log_server.py, then run this script from that directory):
#
#   cd /opt/followerbot-deploy && git pull && ./scripts/install-log-server.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
TOKEN_FILE="/etc/followerbot-logs.env"
SERVICE_NAME="followerbot-logs"

echo "[*] Installing followerBot log server from $DEPLOY_DIR..."

if [ ! -f "$SCRIPT_DIR/log_server.py" ]; then
    echo "[!] $SCRIPT_DIR/log_server.py not found -- run 'git pull' in $DEPLOY_DIR first."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[*] python3 not found, installing..."
    apt-get update -qq && apt-get install -y -qq python3
fi

if [ -f "$TOKEN_FILE" ]; then
    echo "[*] $TOKEN_FILE already exists, leaving token untouched."
else
    TOKEN=$(openssl rand -hex 32)
    cat > "$TOKEN_FILE" <<EOF
LOG_SERVER_TOKEN=$TOKEN
EOF
    chmod 600 "$TOKEN_FILE"
    echo "[+] Generated a new token in $TOKEN_FILE (chmod 600)."
    echo "    Save this now, it will not be printed again:"
    echo "    $TOKEN"
fi

# Service file references the script by its path inside DEPLOY_DIR, so
# install it verbatim only when DEPLOY_DIR is the expected default; warn
# otherwise instead of silently pointing at the wrong path.
if [ "$DEPLOY_DIR" != "/opt/followerbot-deploy" ]; then
    echo "[!] This checkout is at $DEPLOY_DIR, not the default /opt/followerbot-deploy."
    echo "    Edit ExecStart in $SCRIPT_DIR/followerbot-logs.service before continuing, then re-run."
    exit 1
fi

cp "$SCRIPT_DIR/followerbot-logs.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo "[OK] $SERVICE_NAME running. Check with:"
echo "    systemctl status $SERVICE_NAME"
echo "    curl http://localhost:8765/health"
