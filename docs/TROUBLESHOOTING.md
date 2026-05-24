# Troubleshooting

## El contenedor no arranca

### `disk quota exceeded` durante `docker pull`

El LXC tiene disco insuficiente. Desde Proxmox host:
```bash
pct stop <ID>
pct resize <ID> rootfs 20G
pct start <ID>
```

### `wine: /config/.wine is not owned by you`

Estás ejecutando comandos como `root` dentro del contenedor pero Wine espera al usuario `abc` (UID 911). Usa `-u abc`:
```bash
docker exec -u abc followerbot bash -c "..."
```

### `XDG_RUNTIME_DIR is invalid or not set in the environment` durante `docker build`

Esto pasa cuando se invoca Wine en un `RUN` sin haber exportado `XDG_RUNTIME_DIR`. El `Dockerfile` actual lo soluciona definiendo la variable a nivel `ENV` y creando el directorio antes del primer `wineboot`. Si reaparece tras una actualización de la imagen base, revisa que el bloque "Entorno requerido por Wine" del Dockerfile esté presente y antes de cualquier `RUN wine ...`.

### El build de Python termina pero el siguiente paso no encuentra el ejecutable

Probablemente el instalador colocó Python en una ruta distinta de la esperada (32-bit vs 64-bit). El Dockerfile detecta automáticamente ambas rutas y falla con un mensaje claro listando el contenido de `Program Files` si no encuentra ninguna. Mira la salida del paso 6 del build para diagnosticar.

## El bot Python falla al arrancar

### `PermissionError: '.env'`

Permisos: `chown 911:911 /opt/bot-config/.env && chmod 640 /opt/bot-config/.env`.

### `sqlite3.OperationalError: unable to open database file`

Permisos en `/opt/bot-config/`. `chown -R 911:911 /opt/bot-config`.

### `Could not find the input entity for PeerUser(...)`

El warmup automático en `engine.py` debería resolver esto. Si persiste, ejecuta una vez:
```bash
docker exec -u abc followerbot bash -c "cd /config/mi_trading_bot && wine 'C:\\Program Files\\Python311\\python.exe' -c 'import asyncio; from engine import Engine; from config import config; e = Engine(config.telegram_api_id, config.telegram_api_hash, []); asyncio.run(e._warmup_only())'"
```

### `MT5 initialize failed: Authorization failed`

MT5 nunca ha visto este servidor. Conéctate por VNC (`http://<ip>:3000`) y haz **Login manual** en MT5 con las credenciales correctas. MT5 registra el servidor y futuras llamadas a `mt5.initialize()` funcionan.

## Conflictos NumPy / MetaTrader5

Si futuras versiones de MetaTrader5 vuelven a requerir NumPy 1.x:
- Edita `requirements.lock.txt` con la combinación correcta.
- Rebuilds: `docker build -t followerbot:latest .` (desde la raíz de `followerBot-deploy`).
- Push al registry.
- En cada LXC: `docker pull <registry>/followerbot:latest && docker restart followerbot`.

## El registry no acepta push

### `http: server gave HTTP response to HTTPS client`

Falta el `insecure-registries` en `/etc/docker/daemon.json` del cliente. El script `setup-lxc.sh` lo configura, pero si lo necesitas manualmente:
```json
{ "insecure-registries": ["registry.lan:5000"] }
```
`systemctl restart docker`.

### `unauthorized: authentication required`

`docker login registry.lan:5000` con usuario/pass que pusiste en `setup-registry.sh`.

## Python 64-bit vs 32-bit en Wine

Si el Dockerfile falla al instalar Python 3.11 64-bit (porque la imagen base usa Wine 32-bit):
1. Cambia `PYTHON_INSTALLER` a `python-3.11.9.exe` (32-bit).
2. Actualiza la ruta a `C:\\Program Files (x86)\\Python311\\python.exe`.
3. Rebuild la imagen.

## Problemas con autenticación de GitHub

### `Authentication failed for 'https://github.com/alexpargon/followerBot.git/'`

Estás intentando clonar el repo privado por HTTPS sin auth. Solo se debe clonar el repo privado **dentro del LXC del bot** y vía **SSH con deploy key**, nunca por HTTPS.

Si necesitas el código del bot fuera del LXC del bot:
- Para desarrollo: clona con tu key SSH personal.
- Para builds: NO lo necesitas — la imagen Docker no contiene el código, va en volumen.

### `Authentication failed` al clonar followerBot-deploy

El repo `followerBot-deploy` es público — no debería pedir auth. Si lo pide, verifica que la URL es correcta: `https://github.com/alexpargon/followerBot-deploy.git`.
