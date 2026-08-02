# Instalación de followerBot v2.0

Guía paso a paso para desplegar el bot desde cero en Proxmox VE.

## Requisitos previos

- Proxmox VE 8.x funcionando.
- Un LXC del registry ya montado (ver más abajo).
- Imagen `followerbot:1.0` (o la versión actual) subida al registry.

## Arquitectura de volúmenes

### Volúmenes persistidos en el host

- `/opt/mi_trading_bot` → código del bot (clonado de github.com/alexpargon/followerBot, gestionado por el watcher git).
- `/opt/bot-config` → estado del bot (.env, sesión de Telegram, trades.db, logs).

> El wineprefix con Python 3.11 y las librerías del bot vive **dentro de la imagen Docker**, no se persiste en volumen del host. Al recrear el contenedor con una nueva imagen, hay que volver a hacer login manual en MT5 vía VNC. Esto es la operación normal de upgrade.

## Crear el LXC del Docker Registry (una sola vez)

En la shell de Proxmox VE:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)"
```

**Advanced**, plantilla **Debian**, disco **5 GB**, RAM **1 GB**, CPU **1**.

Entra al LXC y ejecuta:

```bash
pct enter <VMID-registry>
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/alexpargon/followerBot-deploy/main/setup-registry.sh -o /tmp/setup-registry.sh
chmod +x /tmp/setup-registry.sh
/tmp/setup-registry.sh <usuario> <password>
```

Anota la IP del LXC. Configura un hostname en tu DNS/router (recomendado: `registry.lan`).

## Construir y subir la imagen del bot

Desde tu máquina de desarrollo (o cualquier LXC con Docker):

```bash
git clone https://github.com/alexpargon/followerBot-deploy.git
cd followerBot-deploy

cat > /etc/docker/daemon.json <<'EOF'
{ "insecure-registries": ["registry.lan:5000"] }
EOF
systemctl restart docker && sleep 3

docker login registry.lan:5000 -u <usuario>
docker build -t followerbot:1.0 .
docker tag followerbot:1.0 registry.lan:5000/followerbot:1.0
docker push registry.lan:5000/followerbot:1.0
```

> El build tarda 10-20 min la primera vez.

## Instalación de un nuevo bot LXC

### Crear el LXC del bot

En la shell de Proxmox:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)"
```
Advanced → Debian → 15 GB disco → 1.5 GB RAM → 1 core → `nesting=1,keyctl=1`.

### Ejecutar el setup

```bash
pct enter <VMID>
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/alexpargon/followerBot-deploy/main/setup-lxc.sh -o /tmp/setup-lxc.sh
chmod +x /tmp/setup-lxc.sh
REGISTRY="registry.lan:5000" IMAGE_TAG="followerbot:1.0" /tmp/setup-lxc.sh
```

El script te guiará paso a paso:
1. Genera deploy key SSH e imprime para que la pegues en GitHub.
2. Si confirmas que la pegaste, clona el repo del bot.
3. Crea `/opt/bot-config/.env` desde la plantilla y abre `nano` para que lo rellenes.
4. Hace `docker pull` de la imagen (te pide login si falta).
5. Levanta el contenedor.
6. Te explica los dos pasos manuales restantes (MT5 vía VNC, Telegram vía `bot-cli`).

### Pasos manuales (ineludibles, ~5 minutos)

**MT5**: navegador → `http://<IP-LXC>:3000` → Login MT5 → Tools → Options → Expert Advisors → Allow algorithmic trading → botón AutoTrading verde.

**Telegram** (primer login):
```bash
bot-cli telegram-login
```
Pedirá phone → code (llega por Telegram) → password 2FA si la tienes.

### Verificación

```bash
bot-cli status
bot-cli bot-logs
```

## Operaciones del día a día

Todas las operaciones comunes se realizan con `bot-cli`. Ejecuta `bot-cli help` para la lista completa.

```bash
bot-cli status            # Estado general
bot-cli logs              # Logs contenedor
bot-cli bot-logs          # Logs bot Python
bot-cli restart           # Reinicio rápido
bot-cli pull-and-restart  # Actualizar código + reinicio
bot-cli env-edit          # Editar .env con permisos correctos
bot-cli rebuild-image     # Tras subir nueva imagen al registry
```
