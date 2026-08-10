# TraderControlEA on the followerbot terminal

The followerbot container already runs a bare, headless MT5 terminal for the
trading bot. `TraderControlEA` can run on that same terminal to push the
**native MT5 economic calendar** (and account data) to TraderControlServer —
so the calendar comes from a light terminal that never gets starved by heavy
analysis indicators.

The MetaTrader5 Python API the bot uses has **no** calendar access, so this
must be an MQL5 EA. The EA only *reads* MT5's local calendar; MT5 itself pulls
the calendar from the broker. Keeping the EA on a light terminal is what
prevents the "calendar frozen until restart" problem.

Only the **compiled** `ea/TraderControlEA.ex5` lives in this (public) repo.
The raw `.mq5`/`.mqh` source must never be committed here — `.gitignore`
blocks it.

## What is automated vs. one-time manual

Automated (host-side, no compile, no bot interruption):

- Installing the compiled EA into the terminal's `MQL5/Experts/`.
- Generating the preset (`MQL5/Presets/TraderControlEA.set`) with the server
  URL and API key from `.env`.
- Generating `C:\mt5-startup.ini`, which makes MT5 **re-attach the EA on every
  terminal launch**. `s6/followerbot/run` passes it via `/config:`.

One-time manual (via VNC):

- Allowing `WebRequest` to the server URL. This one really is persistent: MT5
  writes it to `Config/common.ini` when you close the Options dialog.

> **Do not rely on attaching the EA by hand.** MT5 only writes chart profiles
> (`Profiles/Charts/<profile>/*.chr`) during a *graceful* shutdown. This
> container is hard-killed — `docker logs` shows `s6-svwait: fatal: timed out`
> — so a hand-attached EA is silently lost on the next restart, and MT5
> auto-updates itself (build 6090 arrived within days of install) which forces
> exactly such a restart. That is why the EA "worked for a day or two and then
> stopped". The startup `.ini` is what makes it survive.

## Steps

1. Provide the compiled EA. Compile the source in MetaEditor elsewhere and place
   only the result at `ea/TraderControlEA.ex5` in this repo. The `.ex5` holds no
   extractable source and no secrets (the API key is supplied at runtime via the
   preset), so it is safe to commit; the `.mq5` source is not.

2. Configure `/opt/bot-config/.env`:

   ```dotenv
   TRADERCONTROL_EA_ENABLED=true
   TRADERCONTROL_EA_URL=https://tradedata.your-domain.com
   TRADERCONTROL_EA_KEY=<the X-API-Key for TraderControlServer>
   # Optional. Defaults to the terminal's last selected symbol, then EURUSD.
   # Set it if your broker uses suffixes (e.g. XAUUSD-VIPc) and the default
   # chart fails to open — no chart means no EA.
   TRADERCONTROL_EA_SYMBOL=
   ```

3. Make sure the container has started at least once (MT5 must have created its
   `MQL5` folder), then install and apply:

   ```bash
   bot-cli install-ea
   bot-cli restart
   ```

4. One-time in MT5 (VNC, `http://<lxc-ip>:3000`), only if not already done:
   - Tools → Options → Expert Advisors → **Allow WebRequest for listed URL** →
     add `TRADERCONTROL_EA_URL`.

5. Verify:

   ```bash
   bot-cli ea-status
   ```

   Expect `[OK] El EA está empujando` with a heartbeat age under ~60 s, plus
   `TraderControlEA: Initialized` and `Calendar cursor initialized` in the
   Experts log.

## Monitoring

The EA rewrites `Common/Files/TraderControlEA_<login>.dat` on every successful
push (~15 s), so its mtime is an exact liveness probe. `scripts/watchdog.sh`
checks it every 15 min and restarts the container if it goes stale for more
than `EA_STALE_AFTER` (300 s), rate-limited by `EA_COOLDOWN` (1 h) so a
TraderControlServer outage — which also stalls the heartbeat — cannot cause a
restart loop.

## Notes

- The EA registers the followerbot's MT5 account with TraderControlServer and
  pushes its account/positions/deals as well as the calendar. `install-ea` sets
  `InpFullHistoryOnStart=false` so it does not backfill deal history on attach.
- The calendar source becomes the followerbot broker's calendar (equivalent for
  USD macro news).
- Everything is gated behind `TRADERCONTROL_EA_ENABLED`; with it `false` (the
  default) nothing is installed and existing deployments are unaffected.
- Re-running `bot-cli install-ea` is idempotent (overwrites the EA and preset).
