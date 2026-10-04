#!/bin/bash
# Watcher git: cada minuto, si hay commits nuevos en la rama de deploy, los
# despliega CON HEALTH GATE: tras el restart vigila el contenedor; si el bot
# entra en crash-loop (el circuit breaker de s6 abre = /run/fb-halt, o el
# contenedor muere), se REVIERTE automáticamente al último commit sano y el
# commit malo queda en cuarentena (no se vuelve a intentar hasta que la rama
# avance). Push a master ya no es "deploy sin red".
#
# Contexto: incidente 2026-10-01 — un commit roto en master hizo crash-loop al
# bot 762 veces quemando dinero porque el watcher solo hacía pull+restart.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Un despliegue a la vez (el health gate tarda minutos y cron corre cada 1 min).
exec 9>/var/lock/fb-deploy.lock
flock -n 9 || exit 0

APP_DIR="${APP_DIR:-/opt/mi_trading_bot}"
HEALTH_WAIT="${HEALTH_WAIT:-300}"   # s de observación post-deploy
HEALTH_POLL=15
BOT_CONFIG_DIR="${BOT_CONFIG_DIR:-/opt/bot-config}"
MT5_DATA_DIR="${MT5_DATA_DIR:-/opt/mt5-data}"
CONTAINER_NAME="${CONTAINER_NAME:-followerbot}"
IMAGE="${IMAGE:-localhost:5000/followerbot:latest}"
VNC_PORT="${VNC_PORT:-3000}"
APP_UID=911
APP_GID=911

fix_perms() {
    chown -R "${APP_UID}:${APP_GID}" "$APP_DIR" 2>/dev/null || true
    chown -R "${APP_UID}:${APP_GID}" "$BOT_CONFIG_DIR" 2>/dev/null || true
    chown -R "${APP_UID}:${APP_GID}" "$MT5_DATA_DIR" 2>/dev/null || true
    [ -f "$BOT_CONFIG_DIR/.env" ] && chmod 640 "$BOT_CONFIG_DIR/.env" 2>/dev/null || true
}

run_container() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    mkdir -p "$MT5_DATA_DIR" && chown -R "${APP_UID}:${APP_GID}" "$MT5_DATA_DIR"
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${VNC_PORT}:3000" \
        -v "$APP_DIR:/config/mi_trading_bot" \
        -v "$BOT_CONFIG_DIR:/config/bot-data" \
        -v "$MT5_DATA_DIR:/config/.wine/drive_c/users/abc/AppData/Roaming/MetaQuotes" \
        "$IMAGE"
    echo "[OK] Contenedor levantado: $CONTAINER_NAME"
}

cd "$APP_DIR" 2>/dev/null || { echo "[!] $APP_DIR no existe"; exit 1; }

if [ ! -d ".git" ]; then
    echo "[!] Repo aún no clonado."
    exit 0
fi

# Rama de deploy: la rama actual, o DEPLOY_BRANCH si estamos en detached HEAD
# (estado normal tras un rollback).
BRANCH=$(git symbolic-ref --short -q HEAD || echo "${DEPLOY_BRANCH:-master}")
BAD_FILE="${BOT_CONFIG_DIR}/.fb-bad-commit"

git fetch origin >/dev/null 2>&1 || { echo "[!] git fetch falló"; exit 1; }
REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null) || { echo "[!] origin/$BRANCH no existe"; exit 1; }
HEAD_SHA=$(git rev-parse HEAD)
BAD=$(cat "$BAD_FILE" 2>/dev/null || echo "")

container_up() { [ -n "$(docker ps -q -f name=^${CONTAINER_NAME}$)" ]; }

# El bot tarda ~40-60s en arrancar (espera MT5) y un crash-loop abre el breaker
# en ~2-3 min. Observar HEALTH_WAIT s: contenedor vivo y sin /run/fb-halt.
health_gate() {
    local deadline=$(( $(date +%s) + HEALTH_WAIT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep "$HEALTH_POLL"
        if ! container_up; then
            echo "[!!!] health-gate: el contenedor murió durante la observación."
            return 1
        fi
        if docker exec "$CONTAINER_NAME" test -f /run/fb-halt 2>/dev/null; then
            echo "[!!!] health-gate: circuit breaker abierto (/run/fb-halt) → crash-loop."
            return 1
        fi
    done
    return 0
}

alert() {
    echo "[ALERTA] $*"
    if [ -n "${LOG_SERVER_ALERT_URL:-}" ]; then
        curl -m 5 -s -o /dev/null "${LOG_SERVER_ALERT_URL}" 2>/dev/null || true
    fi
}

if [ "$HEAD_SHA" = "$REMOTE" ]; then
    fix_perms
    container_up || { echo "[!] Contenedor caído, levantando..."; run_container; }
    exit 0
fi

# El watcher llega aquí con HEAD != origin/$BRANCH. Casos:
# 1) origin/$BRANCH == BAD_COMMIT (mismo commit que ya reventó) -> NO redeployar.
# 2) La rama avanzó más allá del commit malo -> intentar de nuevo.
# 3) HEAD == BAD_COMMIT con la rama avanzada -> el caso 2 lo cubre.
if [ -n "$BAD" ] && [ "$REMOTE" = "$BAD" ]; then
    echo "[x] origin/$BRANCH sigue en $BAD (commit en cuarentena por crash-loop). Sin redeploy."
    fix_perms
    container_up || run_container
    exit 0
fi

OLD="$HEAD_SHA"
echo "[+] Cambios detectados, deploy $OLD -> $REMOTE (detach)"
if ! git checkout --detach "$REMOTE" >/dev/null 2>&1; then
    echo "[!] git checkout $REMOTE falló."
    exit 1
fi
fix_perms
echo "[+] Reiniciando contenedor con código nuevo..."
docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || run_container

if health_gate; then
    echo "[OK] Health gate pasado: $REMOTE estable durante ${HEALTH_WAIT}s."
    [ -n "$BAD" ] && rm -f "$BAD_FILE"
else
    echo "[!!!] Health gate FALLIDO: $REMOTE hace crash-loop. Rollback a $OLD"
    echo "$REMOTE" > "$BAD_FILE"
    if git checkout --detach "$OLD" >/dev/null 2>&1; then
        fix_perms
        docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || run_container
        alert "followerBot: deploy ${REMOTE:0:7} rechazado por health-gate, revertido a ${OLD:0:7}. Cuarentena en $BAD_FILE."
    else
        alert "followerBot: CRÍTICO — health gate falló Y el rollback a ${OLD:0:7} falló. Intervención manual."
        exit 1
    fi
fi
