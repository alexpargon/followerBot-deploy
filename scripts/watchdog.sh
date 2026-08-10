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
    exit 0
fi

# 3. ¿El TraderControlEA sigue empujando?
# El EA reescribe su fichero de estado en CADA push correcto (15s). Si el mtime
# se queda atrás es que se ha desadjuntado del gráfico (pasa tras un
# auto-update de MT5 o un cierre sucio). Sin esto el fallo pasa desapercibido
# durante días.
BOT_CONFIG_DIR="${BOT_CONFIG_DIR:-/opt/bot-config}"
ENV_FILE="$BOT_CONFIG_DIR/.env"
EA_STALE_AFTER="${EA_STALE_AFTER:-300}"      # segundos sin heartbeat
EA_COOLDOWN="${EA_COOLDOWN:-3600}"           # no reiniciar más de 1 vez/hora
EA_COOLDOWN_FILE=/var/tmp/followerbot-ea-restart.stamp

ea_enabled=$(sed -n 's/^TRADERCONTROL_EA_ENABLED=//p' "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r')
case "$(printf '%s' "$ea_enabled" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) ;;
    *) exit 0 ;;
esac

hb_epoch=$(docker exec "$CONTAINER_NAME" sh -c \
    'find /config/.wine/drive_c/users -name "TraderControlEA_*.dat" -exec stat -c "%Y" {} \; 2>/dev/null | sort -n | tail -n 1' \
    | tr -d '\r')

[ -z "$hb_epoch" ] && exit 0   # EA aún no instalado/registrado: nada que vigilar

age=$(( $(date +%s) - hb_epoch ))
[ "$age" -le "$EA_STALE_AFTER" ] && exit 0

# Cooldown: si el servidor remoto está caído, los push fallan y el heartbeat se
# queda viejo aunque el EA esté sano. Reiniciar en bucle no arreglaría nada.
last=0
[ -f "$EA_COOLDOWN_FILE" ] && last=$(cat "$EA_COOLDOWN_FILE" 2>/dev/null || echo 0)
if [ $(( $(date +%s) - last )) -lt "$EA_COOLDOWN" ]; then
    echo "[$(date -Iseconds)] EA heartbeat viejo (${age}s) pero en cooldown. Sin acción."
    exit 0
fi

echo "[$(date -Iseconds)] EA heartbeat viejo (${age}s > ${EA_STALE_AFTER}s). Reiniciando contenedor..."
date +%s > "$EA_COOLDOWN_FILE"
docker restart "$CONTAINER_NAME"
