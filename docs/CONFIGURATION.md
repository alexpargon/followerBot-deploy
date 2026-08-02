# FollowerBot Configuration Ownership

This document classifies the environment settings supported by FollowerBot and
defines which values belong in TradingControl. The rule is operational safety:
mobile controls may tune behavior, but must not replace deployment identity,
credentials, routing, or broker ownership while the process is running.

## Mobile live controls

These values should be editable in TradingControl and applied without restarting
the bot. Every mutation must use revision checks and be recorded in the control
audit.

### Strategy state and risk

- `*_ENABLED`: suspend/resume strategy execution. Suspension does not mutate
  open positions or pending orders. While suspended, channel instructions are
  not executed; close instructions may be classified only for reporting.
- `*_LOT_SIZE`: fixed size for future entries.
- `max_open_positions`: control-plane risk limit, per strategy.
- `max_daily_loss`: control-plane realized-loss limit, per strategy.

### Strategy behavior

- LIFT: `LIFT_TP_PIPS`, `LIFT_SL_POSITIVE_PIPS`,
  `LIFT_SL_ACTIVATION_MARGIN_PIPS`, `LIFT_BASKET_ENABLED`.
- Maestro: `MAESTRO_MAX_LAYERS`, `MAESTRO_BASKET_ENABLED`.
- TrueTrading: `TRUETRADING_TP_PIPS`, `TRUETRADING_SL_POSITIVE_PIPS`,
  `TRUETRADING_SL_ACTIVATION_MARGIN_PIPS`,
  `TRUETRADING_AUTO_AVG_GOLDEN_RATIO`, `TRUETRADING_BASKET_ENABLED`.
- Elite XAU: `ELITEXAU_BASKET_ENABLED`.

### General operation

- `SL_SAFETY_BUFFER_PIPS`.
- Global `BASKET_*` trailing, volatility, loss-guard, and duration defaults.
- Per-strategy `<STRATEGY>_BASKET_*` overrides.
- Margin Guardian operational thresholds and sizing (`GUARDIAN_BASE_LOT`,
  `GUARDIAN_HEDGE_LOT`, `GUARDIAN_MAX_HEDGE_LOT`, margin/re-arm thresholds,
  adaptive SL/lock values, pacing, and hedge limits).
- Manual Manager capture mode and protection/trailing thresholds.

`AUTO`-capable values must remain nullable in the API. `null` means adaptive
runtime calculation; zero has its documented numeric meaning and must not be
silently converted to `AUTO`.

## Mobile controls requiring restart

These settings are reasonable to show in TradingControl but should be clearly
marked **Restart required** because they establish sources or construct optional
components:

- Enabling a source that was unavailable at startup, such as TrueTrading with
  no configured credentials or Elite XAU with no channel ID.
- Adding/removing a BasketTrail component when that strategy was constructed
  without one.
- ATR period changes, because existing volatility estimators capture the period
  during construction.

A future controlled restart command may activate these persisted settings. The
UI must not claim they are active until runtime status confirms it.

## Deployment-only settings

These values must remain in `.env`/secret storage and must never be returned by
the control API:

- Broker credentials: `MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER`.
- Source credentials: `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`,
  `TRUETRADING_USER`, `TRUETRADING_PASSWORD`.
- Control secret and listener: `FOLLOWERBOT_CONTROL_API_KEY`,
  `FOLLOWERBOT_CONTROL_BIND`, `FOLLOWERBOT_CONTROL_PORT`, and the host-side
  `FOLLOWERBOT_CONTROL_PUBLISH_ADDRESS` Docker publication setting.
- Runtime filesystem: `BOT_DATA_DIR`, Guardian/Manual state-file paths.
- Trading ownership and routing: channel IDs, magic numbers, symbols, pip sizes.
- Environment identity: `BOT_ENV`; `BOT_INSTANCE_NAME` may be displayed but
  should be changed through deployment configuration.

Changing channel IDs, magic numbers, symbols, or pip sizes remotely could route
signals or management to the wrong broker positions, so they are intentionally
excluded from mobile mutation.

## Implementation status

The control API and TradingControl now implement strategy suspension/resume,
lot size, per-strategy risk limits, strategy TP/SL/layer/averaging behavior,
per-strategy basket enablement and tuning, the global SL safety buffer,
emergency stop, audit, and suspended close-instruction reporting. Basket ATR
period changes are persisted and reported as pending restart.

Margin Guardian and Manual Manager are always constructed and have independent
mobile configuration pages. Their enabled state and operational tuning apply
independently from signal-strategy Emergency Stop. Their source identity,
symbols, magic numbers, pip sizes, and state-file paths remain deployment-only
under the rules above.
