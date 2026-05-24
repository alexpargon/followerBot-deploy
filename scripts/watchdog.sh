#!/bin/bash
# Watchdog: cada 15 min comprueba que main.py está corriendo dentro del contenedor.
# Si no, fuerza restart del contenedor.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONTAINER_NAME="${CONTAINER_NAME:-followerbot}"

# 1. ¿Existe el contenedor y está running?
if [ -z "$(docker ps -q -f name=^${CONTAINER_NAME}$)" ]; then
    echo "[$(date -Iseconds)] Contenedor no running. Delegando a sync_and_deploy."
    /usr/local/bin/sync_and_deploy.sh
    exit 0
fi

# 2. ¿El proceso main.py está vivo dentro?
if ! docker exec "$CONTAINER_NAME" pgrep -f "main.py" >/dev/null 2>&1; then
    echo "[$(date -Iseconds)] main.py no vivo. Reiniciando contenedor..."
    docker restart "$CONTAINER_NAME"
else
    : # Todo OK, silencio
fi
