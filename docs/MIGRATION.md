# Migración del LXC v1 al LXC v2

Si tienes un despliegue antiguo de followerBot (Python 3.9, sin separación código/estado, sin Dockerfile propio), sigue esta guía para migrar sin perder sesión Telegram ni histórico de trades.

## Premisa

El LXC v1 sigue corriendo en producción durante toda la migración. Solo se apaga al final, cuando el v2 ha demostrado funcionar. **Cero downtime** y **fallback inmediato** si algo va mal.

## Paso 1 — Despliega el v2 en paralelo

Sigue [INSTALL.md](INSTALL.md) hasta el Paso 9 pero **NO arranques el contenedor todavía** (cancela el cron temporalmente):

```bash
crontab -l | grep -v "sync_and_deploy\|watchdog" | crontab -
```

## Paso 2 — Copia el estado del bot v1 al v2

Desde el LXC v2:

```bash
# Si el v1 es accesible por SSH desde el v2:
scp root@<ip-v1>:/opt/mi_trading_bot/.env          /opt/bot-config/.env
scp root@<ip-v1>:/opt/mi_trading_bot/session.session /opt/bot-config/session.session
scp root@<ip-v1>:/opt/mi_trading_bot/trades.db     /opt/bot-config/trades.db
scp -r root@<ip-v1>:/opt/mi_trading_bot/bot.log*   /opt/bot-config/ 2>/dev/null || true

chown -R 911:911 /opt/bot-config
chmod 640 /opt/bot-config/.env
```

## Paso 3 — Restaura el cron y arranca

```bash
(crontab -l 2>/dev/null; \
 echo "* * * * * /usr/local/bin/sync_and_deploy.sh >> /var/log/followerbot-sync.log 2>&1"; \
 echo "*/15 * * * * /usr/local/bin/watchdog.sh >> /var/log/followerbot-sync.log 2>&1") | crontab -

/usr/local/bin/sync_and_deploy.sh
docker logs -f followerbot
```

Deberías ver:
- MT5 conectado.
- Telegram conectado **sin pedir SMS** (porque trajo `session.session`).
- Estrategias registradas con sus channel IDs.
- "Poll loop started" sin errores `PeerUser`.

## Paso 4 — Apaga el v1

Cuando lleves al menos **24 horas** de bot v2 estable y procesando mensajes correctamente:

```bash
# En el LXC v1:
docker stop contenedor_mt5_bot
crontab -r  # para que no se relance

# Opcional: archivar el LXC viejo desde Proxmox
pct stop <ID-v1>
```

> Conserva el LXC v1 apagado durante 1-2 semanas como backup. Cuando estés tranquilo, bórralo: `pct destroy <ID-v1>`.

## Rollback (si v2 falla)

```bash
# En el LXC v1:
crontab -e  # restaurar línea del cron viejo
# El cron v1 levantará el contenedor viejo en <1 min.
```

El v1 sigue intacto. Diagnostica el v2 sin presión.
