# Instalación de followerBot v2.0

Guía paso a paso para desplegar el bot desde cero en Proxmox VE.

## Requisitos previos

- Proxmox VE 8.x funcionando.
- Cuenta de GitHub con acceso al repo privado `alexpargon/followerBot`.
- Credenciales MT5 + API de Telegram (api_id, api_hash).
- Móvil a mano para el código SMS de Telegram (solo primera vez).

## Arquitectura de volúmenes

### Volúmenes persistidos en el host

- `/opt/mi_trading_bot` → código del bot (clonado de github.com/alexpargon/followerBot, gestionado por el watcher git).
- `/opt/bot-config` → estado del bot (.env, sesión de Telegram, trades.db, logs).

> El wineprefix con Python 3.11 y las librerías del bot vive **dentro de la imagen Docker**, no se persiste en volumen del host. Al recrear el contenedor con una nueva imagen, hay que volver a hacer login manual en MT5 vía VNC. Esto es la operación normal de upgrade.

## Paso 1 — Crear el LXC del Docker Registry (una sola vez)

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

> Como el repo `followerBot-deploy` es público, no se necesita autenticación.

Anota la IP del LXC. Configura un hostname en Unifi (recomendado: `registry.lan`).

## Paso 2 — Construir y subir la imagen del bot

Desde tu máquina de desarrollo (o cualquier LXC con Docker):

```bash
# Clonar el repo público con el Dockerfile:
git clone https://github.com/alexpargon/followerBot-deploy.git
cd followerBot-deploy

# Configurar el registry como insecure (HTTP, no HTTPS):
cat > /etc/docker/daemon.json <<'EOF'
{
  "insecure-registries": ["registry.lan:5000"]
}
EOF
systemctl restart docker
sleep 3

# Login y build:
docker login registry.lan:5000 -u <usuario>
docker build -t followerbot:1.0 .
docker tag followerbot:1.0 registry.lan:5000/followerbot:1.0
docker tag followerbot:1.0 registry.lan:5000/followerbot:latest
docker push registry.lan:5000/followerbot:1.0
docker push registry.lan:5000/followerbot:latest
```

> El build tarda 10-20 min la primera vez.

## Paso 3 — Crear el LXC del bot

Desde Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)"
```

**Advanced**, **Debian**, **20 GB disco**, **2 GB RAM**, **2 CPU**.

## Paso 4 — Ejecutar setup-lxc.sh

```bash
pct enter <VMID-bot>
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/alexpargon/followerBot-deploy/main/setup-lxc.sh -o /tmp/setup-lxc.sh
chmod +x /tmp/setup-lxc.sh
REGISTRY="registry.lan:5000" IMAGE_TAG="followerbot:1.0" /tmp/setup-lxc.sh
```

El script imprimirá una **deploy key SSH**. Cópiala.

## Paso 5 — Pegar la deploy key en GitHub

`https://github.com/alexpargon/followerBot/settings/keys` → **Add deploy key**. "Allow write access" desmarcado.

Verifica:

```bash
ssh -T git@github.com
```

## Paso 6 — Login en el registry y pull de la imagen

```bash
docker login registry.lan:5000 -u <usuario>
docker pull registry.lan:5000/followerbot:1.0
```

## Paso 7 — Clonar el repo del bot (privado, con SSH)

```bash
git clone git@github.com:alexpargon/followerBot.git /opt/mi_trading_bot
cd /opt/mi_trading_bot
git branch --set-upstream-to=origin/master master
```

## Paso 8 — Crear .env

```bash
cp /opt/followerbot-deploy/.env.example /opt/bot-config/.env
nano /opt/bot-config/.env  # rellena valores reales
chmod 640 /opt/bot-config/.env
chown 911:911 /opt/bot-config/.env
```

## Paso 9 — Login MT5 vía VNC

`hostname -I` → IP. Navegador: `http://<IP>:3000`.

1. `File → Login to Trade Account` con credenciales MT5.
2. `Tools → Options → Expert Advisors` → **Allow algorithmic trading**.
3. Botón **AutoTrading** → verde.

## Paso 10 — Forzar primer arranque

```bash
/usr/local/bin/sync_and_deploy.sh
docker ps
tail -f /opt/bot-config/bot.log
```

La primera vez Telethon pedirá código SMS; ejecútalo en modo interactivo:

```bash
docker exec -it followerbot bash
# dentro, lanzar main.py una vez a mano para que Telethon te pida el código
```

Tras esto, todo es automático.
