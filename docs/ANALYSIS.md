# Análisis de rendimiento (`/stats`)

El log server (ver [LOG_SERVER.md](LOG_SERVER.md)) expone `/stats`, un
endpoint que agrega `trades.db` + `audit_log.jsonl` en un solo JSON —
pensado para revisar el rendimiento del bot y detectar discrepancias de
comportamiento sin tener que descargar cada fila cruda y reconstruirla a
mano. Solo lectura, mismo token que el resto de endpoints.

```bash
TOKEN=$(grep -oP '(?<=LOG_SERVER_TOKEN=).*' /etc/followerbot-logs.env)
curl -H "Authorization: Bearer $TOKEN" \
  "http://<ip-lxc>:8765/stats?from=2026-07-21&to=2026-07-28"
```

Rango máximo 31 días, igual que `/logs`, `/audit` y `/trades`. Timestamps
en UTC (misma advertencia que el resto de la pipeline — ver
`log_server_pipeline` en memoria si usas fechas relativas a "hoy").

## Respuesta

```json
{
  "source": "trades.db + audit_log.jsonl",
  "from": "2026-07-21", "to": "2026-07-28",
  "by_strategy": {
    "LIFT":     {"opened": 12, "closed": 11, "still_open": 1, "wins": 7, "losses": 4,
                 "win_rate_pct": 63.6, "total_profit": 184.30, "avg_profit": 16.76,
                 "avg_pips": 22.4, "close_reasons": {"TP": 6, "SL": 4, "MANUAL": 1}},
    "GUARDIAN": {"opened": 3, "closed": 2, "still_open": 1, "wins": 2, "losses": 0,
                 "win_rate_pct": 100.0, "total_profit": 9.40, "avg_profit": 4.70,
                 "avg_pips": 20.0, "close_reasons": {"TP": 2}}
  },
  "guardian": {
    "hedges_opened_audit": 3, "hedges_opened_trades_db": 3,
    "hedges_rejected": 1, "hedges_rejected_no_free_margin": 0, "hedges_rejected_broker": 1,
    "hedges_locked": 2, "rearms": 2, "max_hedges_cap_hits": 0,
    "min_hedge_interval_sec": 340.0, "rapid_fire_count_under_30s": 0
  }
}
```

### `by_strategy` (todos los canales, incluido GUARDIAN)

Construido a partir de las mismas filas que ya expone `/trades`, agregadas
por `strategy`. `opened`/`closed` cuentan trades cuyo `open_time`/`close_time`
cae en el rango — un trade abierto en el rango pero cerrado después puede
aparecer en `opened` con `still_open` sin aparecer en `closed` todavía.

**Caveat de `avg_pips`/`avg_profit`**: los cierres reconciliados vía deal
history (`close_reason` distinto de los que pone la propia estrategia,
p.ej. detectados por `engine._deal_reconciliation_loop`) escriben
`pips=0.0` porque no se puede recalcular el valor real solo a partir del
deal (limitación conocida de `record_close_from_deal`, no un bug). Si
`avg_pips` sale sospechosamente bajo, mira `close_reasons` — un canal con
muchos cierres reconciliados así diluye el promedio sin que sea una
regresión real de la estrategia.

### `guardian` (diagnóstico específico del guardián de margen)

Estos campos existen solo aquí — un hedge rechazado nunca llega a
`trades.db` (no se abrió posición), y un lock o un re-arm no son ni
apertura ni cierre. Sin `audit_log`, esta información solo estaría en
`bot.log` como texto libre.

- **`hedges_opened_audit` vs `hedges_opened_trades_db`**: deberían
  coincidir. La apertura se reporta a `trades.db` de forma asíncrona
  (`_reporter.report_open` vía `call_soon_threadsafe`); un hueco entre
  ambos números significa que esa tarea no llegó a ejecutarse (p.ej. un
  crash entre el fill y el reporte) — es en sí mismo el tipo de
  discrepancia a buscar, no ruido.
- **`hedges_rejected_no_free_margin` / `_broker`**: rechazos por falta de
  margen libre vs. rechazo del bróker (tamaño/precio). Un valor alto de
  cualquiera de los dos durante una caída de margen indica que el
  guardián detectó el problema pero no pudo cubrir — la caída siguió sin
  frenar.
- **`min_hedge_interval_sec` / `rapid_fire_count_under_30s`**: intervalo
  mínimo entre aperturas de hedge consecutivas, y cuántos pares están por
  debajo de 30s. Es la firma del bucle de hedging descontrolado corregido
  en `ac51958`/`93329f5`/`5e88e73` (un hedge demasiado pequeño no movía
  `margin_level` lo suficiente, así que el gate de re-armado nunca se
  cerraba y disparaba un hedge nuevo cada pocos segundos indefinidamente).
  Con las correcciones desplegadas, un valor bajo aquí (segundos, no
  minutos) durante una caída real de margen sería señal de regresión.
- **`rearms`**: nº de veces que `margin_level` volvió a subir por encima
  de `rearm_margin_level` tras haber estado armado en falso. Útil para
  distinguir "el guardián cubrió una vez y la cuenta se recuperó" de
  "estuvo abriendo hedges en bucle sin re-armar nunca".
- **`max_hedges_cap_hits`**: cuántas veces se alcanzó `GUARDIAN_MAX_HEDGES`
  (0 = sin límite, valor esperado por defecto). Si aparece con el límite
  en 0, es un bug — no debería poder dispararse.

## Comparar develop (demo) vs. master (producción) antes de fusionar

Antes de promover cambios de `develop` a `master`, comparar el mismo rango
de fechas en ambos LXCs (mismo endpoint, distinto host):

```bash
curl -H "Authorization: Bearer $TOKEN_DEV"  "http://<ip-dev>:8765/stats?from=A&to=B"  > dev.json
curl -H "Authorization: Bearer $TOKEN_PROD" "http://<ip-prod>:8765/stats?from=A&to=B" > prod.json
```

No son comparables en volumen (cuenta demo vs. real, y develop suele
llevar código más nuevo), pero sí sirven para verificar que **no hay
regresión de comportamiento**: mismo orden de magnitud de `win_rate_pct`
por estrategia, ningún `rapid_fire_count_under_30s` > 0 en `develop` que no
exista ya en `master`, `hedges_opened_audit == hedges_opened_trades_db` en
ambos, y ningún `close_reasons` con una categoría nueva/inesperada.

## Instalación / actualización

`/stats` vive en el mismo `scripts/log_server.py` que el resto de
endpoints — no requiere un servicio nuevo, solo actualizar el que ya
corre:

```bash
cd /opt/followerbot-deploy && git pull
systemctl restart followerbot-logs
```
