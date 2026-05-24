#!/bin/bash
# Watcher git: cada minuto, si hay commits nuevos, hace pull y reinicia el contenedor.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

APP_DIR="${APP_DIR:-/opt/mi_trading_bot}"
BOT_CONFIG_DIR="${BOT_CONFIG_DIR:-/opt/bot-config}"
CONTAINER_NAME="${CONTAINER_NAME:-followerbot}"
IMAGE="${IMAGE:-localhost:5000/followerbot:latest}"
VNC_PORT="${VNC_PORT:-3000}"
APP_UID=911
APP_GID=911

fix_perms() {
    chown -R "${APP_UID}:${APP_GID}" "$APP_DIR" 2>/dev/null || true
    chown -R "${APP_UID}:${APP_GID}" "$BOT_CONFIG_DIR" 2>/dev/null || true
    [ -f "$BOT_CONFIG_DIR/.env" ] && chmod 640 "$BOT_CONFIG_DIR/.env" 2>/dev/null || true
}

run_container() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${VNC_PORT}:3000" \
        -v "$APP_DIR:/config/mi_trading_bot" \
        -v "$BOT_CONFIG_DIR:/config/bot-data" \
        "$IMAGE"
    echo "[OK] Contenedor levantado: $CONTAINER_NAME"
}

cd "$APP_DIR" 2>/dev/null || { echo "[!] $APP_DIR no existe"; exit 1; }

if [ ! -d ".git" ]; then
    echo "[!] Repo aún no clonado."
    exit 0
fi

if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo "[!] Rama sin upstream."
    exit 0
fi

git fetch origin >/dev/null 2>&1 || { echo "[!] git fetch falló"; exit 1; }
LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse @{u})

if [ "$LOCAL" != "$REMOTE" ]; then
    echo "[+] Cambios detectados, pull..."
    if git pull --ff-only; then
        fix_perms
        echo "[+] Reiniciando contenedor con código nuevo..."
        docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || run_container
    else
        echo "[!] git pull falló."
        exit 1
    fi
else
    fix_perms
    if [ -z "$(docker ps -q -f name=^${CONTAINER_NAME}$)" ]; then
        echo "[!] Contenedor caído, levantando..."
        run_container
    fi
fi
