#!/bin/bash
# ============================================================
#  followerBot v2.0 — Setup completo del LXC
#  Asume: LXC creado con community-scripts/docker.sh modo Debian,
#         20GB disco, dentro de Proxmox VE.
#  Ejecutar UNA vez como root dentro del LXC.
# ============================================================
set -euo pipefail

# ---------- CONFIGURACIÓN ----------
# Estos valores se pueden sobreescribir por variables de entorno antes de ejecutar:
#   REGISTRY="registry.lan:5000" IMAGE_TAG="followerbot:1.0" ./setup-lxc.sh
REPO_SSH="${REPO_SSH:-git@github.com:alexpargon/followerBot.git}"
BRANCH="${BRANCH:-master}"
APP_DIR="${APP_DIR:-/opt/mi_trading_bot}"
BOT_CONFIG_DIR="${BOT_CONFIG_DIR:-/opt/bot-config}"
MT5_DATA_DIR="${MT5_DATA_DIR:-/opt/mt5-data}"
CONTAINER_NAME="${CONTAINER_NAME:-followerbot}"
VNC_PORT="${VNC_PORT:-3000}"
LOG_FILE="${LOG_FILE:-/var/log/followerbot-sync.log}"
REGISTRY="${REGISTRY:-}"      # ej. "registry.lan:5000" — vacío = build local
IMAGE_TAG="${IMAGE_TAG:-followerbot:latest}"

DEPLOY_REPO_HTTPS="${DEPLOY_REPO_HTTPS:-https://github.com/alexpargon/followerBot-deploy.git}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/followerbot-deploy}"
# -----------------------------------

echo "[*] followerBot v2.0 setup-lxc.sh"
echo "    REPO_SSH=$REPO_SSH"
echo "    DEPLOY_REPO=$DEPLOY_REPO_HTTPS"
echo "    REGISTRY=${REGISTRY:-<local build>}"
echo

# 1. Verificar entorno
command -v docker >/dev/null || { echo "[!] Docker no encontrado."; exit 1; }
. /etc/os-release
[[ "$ID" == "debian" || "$ID_LIKE" == *debian* ]] || { echo "[!] Requiere Debian (detectado: $ID)."; exit 1; }

echo "[*] Instalando utilidades base..."
apt-get update -qq
apt-get install -y -qq git cron openssh-client ca-certificates curl >/dev/null

# Permitir a root operar sobre repos cuyos archivos pertenecen a abc (UID 911).
# Necesario porque el watcher git corre como root y opera sobre /opt/mi_trading_bot
# que es propiedad de 911:911.
git config --global --add safe.directory '*' 2>/dev/null || true
git config --system --add safe.directory '*' 2>/dev/null || true

# 2. Directorios
mkdir -p "$APP_DIR" "$BOT_CONFIG_DIR" "$MT5_DATA_DIR"
chown -R 911:911 "$BOT_CONFIG_DIR" "$MT5_DATA_DIR"
mkdir -p /root/.ssh && chmod 700 /root/.ssh

# 3. Deploy key SSH (para clonar el repo PRIVADO del bot)
if [ ! -f /root/.ssh/id_ed25519 ]; then
    echo "[*] Generando deploy key ed25519..."
    ssh-keygen -t ed25519 -C "followerbot-lxc-$(hostname)" -N "" -f /root/.ssh/id_ed25519 >/dev/null
fi
ssh-keyscan -t ed25519,rsa github.com >> /root/.ssh/known_hosts 2>/dev/null
sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts
cat > /root/.ssh/config <<SSHCFG
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
SSHCFG
chmod 600 /root/.ssh/config /root/.ssh/id_ed25519

# 4. Clonar/actualizar el repo de deployment (público, sin auth)
if [ ! -d "$DEPLOY_DIR/.git" ]; then
    echo "[*] Clonando repo de deployment público..."
    git clone --branch "$DEPLOY_BRANCH" "$DEPLOY_REPO_HTTPS" "$DEPLOY_DIR"
else
    echo "[*] Actualizando repo de deployment..."
    (cd "$DEPLOY_DIR" && git fetch origin && git reset --hard "origin/$DEPLOY_BRANCH")
fi

# 5. Imagen Docker
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_TAG}"
    echo "[*] Configurando registry insecure: $REGISTRY"
    mkdir -p /etc/docker
    if [ ! -f /etc/docker/daemon.json ]; then
        echo '{}' > /etc/docker/daemon.json
    fi
    # Añadir registry como insecure (merge con jq)
    if ! command -v jq >/dev/null; then
        apt-get install -y -qq jq >/dev/null
    fi
    jq --arg r "$REGISTRY" '. + {"insecure-registries": ((.["insecure-registries"] // []) + [$r] | unique)}' \
        /etc/docker/daemon.json > /etc/docker/daemon.json.tmp
    mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    systemctl restart docker
    sleep 3
    echo "[*] Pulleando imagen $FULL_IMAGE..."
    if ! docker pull "$FULL_IMAGE" 2>/dev/null; then
        echo "[*] Pull falló. Probablemente necesita docker login en $REGISTRY."
        if docker login "$REGISTRY"; then
            docker pull "$FULL_IMAGE" || { echo "[!] Pull sigue fallando tras login."; exit 1; }
        else
            echo "[!] docker login canceló. Aborta."
            exit 1
        fi
    fi
else
    FULL_IMAGE="$IMAGE_TAG"
    echo "[*] Modo build local (no registry)."
    if ! docker image inspect "$FULL_IMAGE" >/dev/null 2>&1; then
        echo "[*] Construyendo imagen $FULL_IMAGE desde $DEPLOY_DIR..."
        docker build -t "$FULL_IMAGE" "$DEPLOY_DIR"
    fi
fi

# 6. Watcher script
install -m 755 -D /dev/stdin /usr/local/bin/sync_and_deploy.sh <<SYNC_EOF
#!/bin/bash
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

APP_DIR="$APP_DIR"
BOT_CONFIG_DIR="$BOT_CONFIG_DIR"
MT5_DATA_DIR="$MT5_DATA_DIR"
CONTAINER_NAME="$CONTAINER_NAME"
IMAGE="$FULL_IMAGE"
VNC_PORT="$VNC_PORT"
APP_UID=911
APP_GID=911

fix_perms() {
    chown -R "\${APP_UID}:\${APP_GID}" "\$APP_DIR" 2>/dev/null || true
    chown -R "\${APP_UID}:\${APP_GID}" "\$BOT_CONFIG_DIR" 2>/dev/null || true
    chown -R "\${APP_UID}:\${APP_GID}" "\$MT5_DATA_DIR" 2>/dev/null || true
    [ -f "\$BOT_CONFIG_DIR/.env" ] && chmod 640 "\$BOT_CONFIG_DIR/.env" 2>/dev/null || true
}

run_container() {
    docker rm -f "\$CONTAINER_NAME" >/dev/null 2>&1 || true
    mkdir -p "\$MT5_DATA_DIR" && chown -R "\${APP_UID}:\${APP_GID}" "\$MT5_DATA_DIR"
    docker run -d \\
        --name "\$CONTAINER_NAME" \\
        --restart unless-stopped \\
        -p "\${VNC_PORT}:3000" \\
        -v "\$APP_DIR:/config/mi_trading_bot" \\
        -v "\$BOT_CONFIG_DIR:/config/bot-data" \\
        -v "\$MT5_DATA_DIR:/config/.wine/drive_c/users/abc/AppData/Roaming/MetaQuotes" \\
        "\$IMAGE"
    echo "[OK] Contenedor levantado: \$CONTAINER_NAME"
}

cd "\$APP_DIR" 2>/dev/null || { echo "[!] \$APP_DIR no existe"; exit 1; }
[ -d ".git" ] || { echo "[!] Repo no clonado."; exit 0; }
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || { echo "[!] Sin upstream."; exit 0; }

git fetch origin >/dev/null 2>&1 || { echo "[!] git fetch falló"; exit 1; }
LOCAL=\$(git rev-parse @)
REMOTE=\$(git rev-parse @{u})

if [ "\$LOCAL" != "\$REMOTE" ]; then
    echo "[+] Cambios detectados, pull..."
    if git pull --ff-only; then
        fix_perms
        docker restart "\$CONTAINER_NAME" >/dev/null 2>&1 || run_container
    else
        echo "[!] git pull falló"; exit 1
    fi
else
    fix_perms
    if [ -z "\$(docker ps -q -f name=^\${CONTAINER_NAME}\$)" ]; then
        run_container
    fi
fi
SYNC_EOF

# 7. Watchdog script
install -m 755 -D /dev/stdin /usr/local/bin/watchdog.sh <<WD_EOF
#!/bin/bash
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONTAINER_NAME="$CONTAINER_NAME"

if [ -z "\$(docker ps -q -f name=^\${CONTAINER_NAME}\$)" ]; then
    echo "[\$(date -Iseconds)] Contenedor no running. Delegando..."
    /usr/local/bin/sync_and_deploy.sh
    exit 0
fi

if ! docker exec "\$CONTAINER_NAME" pgrep -f "main.py" >/dev/null 2>&1; then
    echo "[\$(date -Iseconds)] main.py no vivo. Restart..."
    docker restart "\$CONTAINER_NAME"
fi
WD_EOF

# 8. Crontab
(
    crontab -l 2>/dev/null | grep -vE "sync_and_deploy|watchdog" || true
    echo "* * * * * /usr/local/bin/sync_and_deploy.sh >> $LOG_FILE 2>&1"
    echo "*/15 * * * * /usr/local/bin/watchdog.sh >> $LOG_FILE 2>&1"
) | crontab -

systemctl enable --now cron >/dev/null 2>&1 || service cron start

# 9. bot-cli
install -m 755 "$DEPLOY_DIR/bot-cli" /usr/local/bin/bot-cli
echo "[*] bot-cli instalado. Usa 'bot-cli help' para ver comandos."

# 10. Clone del repo del bot (necesita deploy key en GitHub)
LXC_IP=$(hostname -I | awk '{print $1}')

if [ ! -d "$APP_DIR/.git" ]; then
    echo
    echo "============================================================"
    echo " DEPLOY KEY (pégala en GitHub si aún no lo has hecho):"
    echo " https://github.com/$(echo "$REPO_SSH" | sed -E 's|git@github.com:||; s|\.git$||')/settings/keys"
    echo " 'Allow write access' DESACTIVADO."
    echo "============================================================"
    cat /root/.ssh/id_ed25519.pub
    echo "============================================================"
    echo
    read -r -p "¿Has pegado ya la deploy key en GitHub? [s/N] " ANSWER
    if [[ "$ANSWER" =~ ^[sSyY]$ ]]; then
        echo "[*] Verificando conectividad SSH a GitHub..."
        # GitHub's SSH check always exits 1 even on a SUCCESSFUL auth (it
        # authenticates, then refuses shell access) — with `set -o pipefail`
        # active at the top of this script, piping straight into `grep -q`
        # makes the `if` see ssh's exit 1, not grep's exit 0, so it always
        # took the failure branch even when the key was already working.
        # Capture the output first (neutralizing ssh's own exit code with
        # `|| true`) and grep that instead.
        SSH_CHECK=$(ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
        if echo "$SSH_CHECK" | grep -q "successfully authenticated"; then
            echo "[*] Clonando $REPO_SSH en $APP_DIR..."
            git clone --branch "$BRANCH" "$REPO_SSH" "$APP_DIR"
            chown -R 911:911 "$APP_DIR"
            cd "$APP_DIR"
            git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
            echo "[OK] Repo clonado."
        else
            echo "[!] La deploy key no responde aún. Espera unos segundos y reintenta:"
            echo "      $0"
            exit 0
        fi
    else
        echo "[!] Pega la deploy key y vuelve a ejecutar: $0"
        exit 0
    fi
else
    echo "[*] Repo del bot ya clonado en $APP_DIR. Actualizando..."
    cd "$APP_DIR"
    git fetch origin
    git checkout "$BRANCH" 2>/dev/null || true
    git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
    chown -R 911:911 "$APP_DIR"
fi

# 11. Crear .env desde plantilla si no existe
ENV_FILE="$BOT_CONFIG_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$APP_DIR/.env.example" ]; then
        cp "$APP_DIR/.env.example" "$ENV_FILE"
    elif [ -f "$DEPLOY_DIR/.env.example" ]; then
        cp "$DEPLOY_DIR/.env.example" "$ENV_FILE"
    else
        cat > "$ENV_FILE" <<'ENVEOF'
# Rellenar con valores reales
TELEGRAM_API_ID=
TELEGRAM_API_HASH=
MT5_LOGIN=
MT5_PASSWORD=
MT5_SERVER=
ENVEOF
    fi
    chown 911:911 "$ENV_FILE"
    chmod 640 "$ENV_FILE"
    echo
    echo "[*] Se ha creado $ENV_FILE desde la plantilla."
    echo "[!] Edítalo con tus credenciales reales antes de continuar:"
    echo "      nano $ENV_FILE"
    echo
    read -r -p "¿Quieres editarlo ahora? [S/n] " ANSWER
    if [[ ! "$ANSWER" =~ ^[nN]$ ]]; then
        nano "$ENV_FILE"
    fi
else
    echo "[*] $ENV_FILE ya existe, no se sobreescribe."
    chown 911:911 "$ENV_FILE"
    chmod 640 "$ENV_FILE"
fi

# 12. Arranque
echo
echo "[*] Lanzando sync_and_deploy.sh para levantar el contenedor..."
/usr/local/bin/sync_and_deploy.sh

sleep 3

if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
    echo
    echo "============================================================"
    echo " SETUP COMPLETO."
    echo "============================================================"
    echo " Contenedor:    $CONTAINER_NAME (running)"
    echo " VNC:           http://${LXC_IP}:${VNC_PORT}"
    echo " Logs bot:      tail -f $BOT_CONFIG_DIR/bot.log"
    echo " Logs contenedor: docker logs -f $CONTAINER_NAME"
    echo
    echo " PRÓXIMOS PASOS MANUALES:"
    echo "   1. Acceder a VNC y hacer login en MT5 con tus credenciales."
    echo "      Activar 'Allow algorithmic trading' en Tools > Options > Expert Advisors."
    echo "      Pulsar el botón 'AutoTrading' (debe quedar verde)."
    echo
    echo "   2. Para el primer login de Telegram (te llegará un código):"
    echo "      bot-cli telegram-login"
    echo "============================================================"
else
    echo "[!] El contenedor no arrancó. Revisa:"
    echo "      tail -50 $LOG_FILE"
    echo "      docker logs $CONTAINER_NAME"
    exit 1
fi
