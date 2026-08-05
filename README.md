# followerBot-deploy

Infraestructura de despliegue para [followerBot](https://github.com/alexpargon/followerBot) — bot de copy-trading que opera en MetaTrader 5 a partir de señales de Telegram.

## Contenido

- **`Dockerfile`** — Imagen Docker con Wine + MT5 + Python 3.11 + librerías.
- **`setup-registry.sh`** — Crea un Docker registry local con auth básica.
- **`setup-lxc.sh`** — Configura un LXC de Proxmox para correr el bot.
- **`s6/`** — Servicio s6 que supervisa el proceso del bot.
- **`scripts/`** — Watcher git + watchdog del bot.
- **`docs/INSTALL.md`** — Guía paso a paso de instalación.
- **`docs/TROUBLESHOOTING.md`** — Errores comunes y soluciones.
- **`docs/MIGRATION.md`** — Cómo migrar de versiones antiguas.
- **`docs/LOG_SERVER.md`** — Servicio HTTP opt-in de solo lectura para consultar logs/trades por día (pensado para un LXC de dev/demo).
- **`docs/ANALYSIS.md`** — Cómo usar `/stats` (mismo log server) para revisar rendimiento y detectar discrepancias antes de promover `develop` a `master`.
- **`docs/TRADER_CONTROL_EA.md`** — Ejecutar TraderControlEA (calendario nativo MT5) en el terminal del followerbot.

## Quick start

```bash
# En el LXC del bot:
curl -fsSL https://raw.githubusercontent.com/alexpargon/followerBot-deploy/main/setup-lxc.sh | \
  REGISTRY="registry.lan:5000" IMAGE_TAG="followerbot:1.0" bash
```

Ver [docs/INSTALL.md](docs/INSTALL.md) para el procedimiento completo.

## Por qué un repo separado

Este repo es **público** para que los LXC y scripts de despliegue puedan clonarlo sin credenciales. El código real del bot vive en un repo privado (`followerBot`) al que se accede únicamente mediante deploy keys SSH generadas durante el setup.
