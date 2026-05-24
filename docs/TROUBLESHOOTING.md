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

### El build falla en la verificación de Python (`Python no se instaló en ninguna ruta esperada`)

Esto pasaba con la versión 2.0.1 del Dockerfile, que usaba el instalador `.exe` de Python con `/quiet`. Bajo Wine en builds Docker no interactivos, ese instalador muere en silencio sin instalar nada.

La versión 2.0.2+ del Dockerfile usa el **Python embeddable** (un zip auto-contenido) en vez del instalador. Si actualizas tu rama desde una versión anterior, asegúrate de hacer `git pull` antes de rebuilds.

### `unzip: command not found` durante el build

La imagen base normalmente trae `unzip`, pero si una actualización lo quitase, el Dockerfile lo reinstala automáticamente con `apt-get`. Si tu build falla aquí, verifica conectividad a `deb.debian.org` desde dentro del LXC donde construyes.

### `NO_PUBKEY` del repo de WineHQ durante el build

La imagen base `gmag11/metatrader5_vnc` configura un repo APT de WineHQ cuya clave GPG puede caducar con el tiempo. No usamos ese repo (Wine ya viene en la base), pero `apt-get update` falla si está presente y la clave no es válida.

El Dockerfile lo esquiva: comprueba si necesita usar `apt` (solo si falta `unzip`), y en ese caso mueve temporalmente el repo winehq fuera, hace el `apt`, y lo restaura. Si añades pasos nuevos al Dockerfile que requieran `apt`, aplica el mismo patrón.

### El contenedor arranca pero s6 muere con `Permission denied` en `/docker-mods` o `lsiown`

La imagen base de linuxserver.io requiere arrancar como `root` para que sus scripts de init configuren el usuario `abc` correctamente. El Dockerfile termina con `USER root` por ese motivo (la imagen baja privilegios internamente vía `s6-setuidgid`).

Si reaparece este error tras una modificación del Dockerfile, comprueba que la última línea es `USER root`.

### El contenedor arranca pero `/config` está vacío dentro del contenedor (sin wineprefix, sin Python)

Esto pasaba en versiones tempranas de `setup-lxc.sh` que montaban `/opt/mt5_data:/config`. Ese mount **enmascara** el `/config` de la imagen (que contiene wineprefix, Python 3.11 y librerías) con un directorio vacío del host.

Solución: NO montar nada sobre `/config` entero. El wineprefix forma parte de la imagen. Si necesitas persistir estado del bot, monta `/opt/bot-config:/config/bot-data` (subdirectorio específico). Si necesitas persistir config interna de MT5 (servidores conocidos, terminal.ini), monta sólo el subdirectorio relevante:
```
-v /opt/mt5_terminal:/config/.wine/drive_c/users/abc/AppData/Roaming/MetaQuotes
```

Pero **nunca** sobre `/config` entero.

## El bot Python falla al arrancar

### `ImportError: numpy.core.multiarray failed to import` / `_ARRAY_API not found`

MetaTrader5 sigue publicando wheels compilados contra NumPy 1.x (a la fecha de la última actualización de este repo). `requirements.lock.txt` fija `numpy==1.26.4` por esta razón.

**No actualices NumPy a 2.x sin antes verificar** que MetaQuotes ha publicado wheels compatibles. Para comprobarlo:

```bash
pip index versions MetaTrader5
# Mira el changelog del paquete en PyPI antes de subir numpy.
```

Si MetaQuotes actualiza, también edita `requirements.txt` del repo `followerBot` (que actualmente fija `numpy<2`).

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

## Errores del bot al arrancar (s6)

### `ModuleNotFoundError: No module named 'config'` (o similar)

El bot tiene módulos locales (`config.py`, `engine.py`, etc.) que importa desde su propio directorio. Al ejecutar `wine python.exe main.py`, Wine no inyecta el directorio del script al `sys.path` como hace Linux nativo.

Solución: el `s6/followerbot/run` exporta `PYTHONPATH='Z:\config\mi_trading_bot'` antes de invocar Wine. Si añades nuevos módulos o subdirectorios al bot, asegúrate de que las rutas relativas siguen funcionando con este PYTHONPATH. Si necesitas más paths, sepáralos con `;` (separador Windows):

```bash
PYTHONPATH='Z:\config\mi_trading_bot;Z:\config\mi_trading_bot\channels'
```

### El bot crashea en bucle con `MT5 initialize failed` durante el primer arranque

En el primer arranque del contenedor (volumen `/config` recién creado o LXC nuevo), la imagen base instala MT5 desde cero. Puede tardar 1-3 minutos. El `s6/followerbot/run` espera hasta 5 minutos a que aparezca `terminal64.exe` antes de lanzar el bot.

Si pasados 5 minutos sigue sin estar instalado, el servicio falla con mensaje claro. Mira los logs del contenedor para ver el progreso del init de la imagen base (descarga de Mono, etc.):

```bash
docker logs followerbot | grep -E '\[\d/7\]'
```
