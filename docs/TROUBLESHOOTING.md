# Troubleshooting

## Comandos útiles (bot-cli)

Todas las operaciones comunes se hacen con `bot-cli`. Ejecuta `bot-cli help` para ver la lista.

| Comando | Para qué |
|---------|----------|
| `bot-cli status` | Estado general (contenedor, repo, archivos críticos) |
| `bot-cli logs` | Logs del contenedor (s6 + Wine) |
| `bot-cli bot-logs` | Logs del bot Python (más limpios) |
| `bot-cli restart` | Reinicia el contenedor sin rebuild |
| `bot-cli pull-and-restart` | git pull + reinicio (forzar actualización) |
| `bot-cli telegram-login` | Login interactivo de Telethon (primera vez) |
| `bot-cli env-edit` | Editar `/opt/bot-config/.env` con permisos correctos |
| `bot-cli env-show` | Ver `.env` con passwords enmascaradas |
| `bot-cli vnc` | URL de VNC para login MT5 |
| `bot-cli rebuild-image` | Pull de nueva imagen + restart |
| `bot-cli shell` | Shell dentro del contenedor como `abc` |
| `bot-cli mt5-shell` | Python interactivo con `import MetaTrader5` listo |

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

### `ModuleNotFoundError` para módulos locales del bot (`config`, `engine`, etc.)

Python embeddable bajo Wine ignora `PYTHONPATH` (define `sys.path` desde `python311._pth`). Por eso el bot adopta layout `src/` y `main.py` es un shim que inyecta `src/` en `sys.path` antes de cualquier import del proyecto:

```python
# main.py (raíz del repo del bot)
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from followerbot.bootstrap import ensure_dependencies
ensure_dependencies()
from followerbot.app import main
if __name__ == "__main__":
    main()
```

Todo el código vive bajo `src/followerbot/` (y `src/followerbot/channels/`). Si añades nuevos módulos, ponlos dentro del paquete y usa imports relativos (`from .config import ...`). No hace falta tocar nada del deploy.

### `ModuleNotFoundError` para librerías de terceros (`requests`, `MetaTrader5`, ...)

El bot incluye un módulo `src/followerbot/bootstrap.py` que se ejecuta al arranque y, si detecta imports rotos, ejecuta `sys.executable -m pip install -r requirements.lock.txt` para auto-reparar.

Si esto falla (p. ej. sin conexión a internet), instala manualmente dentro del contenedor:

```bash
docker exec -u abc followerbot \
  wine 'C:\Python311\python.exe' -m pip install -r /config/mi_trading_bot/requirements.lock.txt
```

**Importante**: usa siempre la ruta explícita `C:\Python311\python.exe`. `wine python.exe` (sin ruta) puede resolver a otro Python instalado en el wineprefix (p. ej. `Python39-32`) y los paquetes acabarían en el sitio equivocado.

### El bot crashea en bucle con `MT5 initialize failed` durante el primer arranque

En el primer arranque del contenedor (volumen `/config` recién creado o LXC nuevo), la imagen base instala MT5 desde cero. Puede tardar 1-3 minutos. El `s6/followerbot/run` espera hasta 5 minutos a que aparezca `terminal64.exe` antes de lanzar el bot.

Si pasados 5 minutos sigue sin estar instalado, el servicio falla con mensaje claro. Mira los logs del contenedor para ver el progreso del init de la imagen base (descarga de Mono, etc.):

```bash
docker logs followerbot | grep -E '\[\d/7\]'
```
