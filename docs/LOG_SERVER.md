# Log server (acceso remoto de solo lectura)

Servicio HTTP mínimo (stdlib de Python, sin dependencias) que expone
`bot.log`, `audit_log.jsonl` y `trades.db` de un LXC concreto, agrupados
por día de calendario, en JSON. Pensado para dar acceso de solo lectura
a un LXC de **dev/demo** (no a prod) sin tener que copiar archivos a mano.

**Solo lectura por diseño**: ningún endpoint puede escribir, reiniciar el
contenedor ni tocar `.env`. No está enganchado a `setup-lxc.sh` — es
opt-in, se instala aparte, para no ampliar la superficie de ataque de los
LXC de producción sin decidirlo explícitamente.

## Por qué "agrupado por día" sin tocar el logging del bot

`bot.log` rota por **tamaño** (`RotatingFileHandler`, 5 MB, 5 backups), no
por día — un solo día puede repartirse entre `bot.log` y `bot.log.1`, y un
solo archivo puede contener varios días. El servidor lee **todos** los
`bot.log*` presentes y reagrupa cada línea por la fecha que lleva su propio
timestamp (las líneas de continuación, p.ej. tracebacks multilínea, se
agrupan con la última fecha vista). Así la agrupación por día es correcta
sin cambiar nada del logging real del bot.

## Instalación (una vez, en el LXC que quieras exponer)

```bash
cd /opt/followerbot-deploy && git pull
./scripts/install-log-server.sh
```

El script:
1. Comprueba que `python3` está disponible (lo instala si falta).
2. Genera un token aleatorio en `/etc/followerbot-logs.env` (si no existe ya) y lo imprime **una sola vez** — guárdalo.
3. Instala y arranca `followerbot-logs.service` (systemd), con `Restart=on-failure`.

Verificación:
```bash
systemctl status followerbot-logs
curl http://localhost:8765/health
```

## Uso

Todos los endpoints salvo `/health` requieren `Authorization: Bearer <token>`.

```bash
TOKEN=$(grep -oP '(?<=LOG_SERVER_TOKEN=).*' /etc/followerbot-logs.env)

# Estado / commit desplegado ahora mismo
curl -H "Authorization: Bearer $TOKEN" http://<ip-lxc>:8765/status

# Logs agrupados por día (máx. 31 días por consulta)
curl -H "Authorization: Bearer $TOKEN" \
  "http://<ip-lxc>:8765/logs?from=2026-07-24&to=2026-07-26"

# Igual para audit_log.jsonl y trades.db
curl -H "Authorization: Bearer $TOKEN" ".../audit?from=...&to=..."
curl -H "Authorization: Bearer $TOKEN" ".../trades?from=...&to=..."
```

Formato de respuesta (`/logs`):
```json
{
  "source": "bot.log",
  "from": "2026-07-24", "to": "2026-07-26",
  "days": {
    "2026-07-24": {"count": 42, "lines": ["2026-07-24 09:00:00,100 [INFO] ...", "..."]},
    "2026-07-25": {"count": 0,  "lines": []}
  }
}
```

## Seguridad

- Token único (`LOG_SERVER_TOKEN`), comparación en tiempo constante. Sin
  token configurado, el servicio **rechaza arrancar** (no sirve nada sin
  auth por defecto).
- El servicio corre como el usuario `911` (mismo dueño que `/opt/bot-config`),
  con `NoNewPrivileges` y `ProtectSystem=strict` en la unit de systemd.
- Escucha en `0.0.0.0:8765` — pensado para LAN interna / detrás de VPN
  (Tailscale, WireGuard, etc.), **no** para exponer el puerto a internet.
  Si necesitas restringirlo a una interfaz concreta, sobreescribe
  `LOG_SERVER_HOST` en `/etc/followerbot-logs.env`.
- Rango máximo de 31 días por consulta (evita respuestas absurdamente
  grandes / auto-DoS).

## Montar un LXC dev/demo completo (código + log server)

Mismo procedimiento que un LXC de prod (`docs/INSTALL.md`), con dos
diferencias: rama `develop` y credenciales MT5 de la cuenta **demo**.

```bash
# En el LXC del bot (nuevo, dedicado a dev/demo):
REGISTRY="registry.lan:5000" IMAGE_TAG="followerbot:1.0" BRANCH="develop" \
  /tmp/setup-lxc.sh
# ... login MT5 (cuenta demo) y Telegram como en INSTALL.md ...

# Añadir el log server:
cd /opt/followerbot-deploy && git pull
./scripts/install-log-server.sh
```

El watcher (`sync_and_deploy.sh`) ya es agnóstico de rama: seguirá
`develop` automáticamente porque es la rama que quedó *checked out* en
`/opt/mi_trading_bot`.
