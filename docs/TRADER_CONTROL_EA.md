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

Automated (host-side, no compile, no `docker exec`, no bot interruption):

- Installing the compiled EA into the terminal's `MQL5/Experts/`.
- Generating the preset (`MQL5/Presets/TraderControlEA.set`) with the server
  URL and API key from `.env`.

One-time manual (via VNC — persists afterwards in the bind-mounted profile):

- Allowing `WebRequest` to the server URL.
- Attaching the EA to a chart (loading the preset) and enabling Algo Trading.

MT5 cannot auto-attach an EA headlessly, but once attached and saved it is
restored on every restart because the terminal profile lives under the
bind-mounted data folder.

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
   ```

3. Make sure the container has started at least once (MT5 must have created its
   `Terminal/<hash>/MQL5` folder), then install:

   ```bash
   bot-cli install-ea
   ```

   This copies the EA and writes the preset, then prints the remaining manual
   steps.

4. One-time in MT5 (VNC, `http://<lxc-ip>:3000`):
   - Tools → Options → Expert Advisors → **Allow WebRequest for listed URL** →
     add `TRADERCONTROL_EA_URL`.
   - Drag **TraderControlEA** onto any chart → in the dialog **Load** the
     `TraderControlEA` preset → tick **Allow Algo Trading** → OK.
   - Confirm the **AutoTrading** toolbar button is green.

5. Verify: the EA prints `TraderControlEA: Initialized` in the Experts tab and
   `Calendar cursor initialized` shortly after, and TraderControlServer starts
   receiving calendar updates.

## Notes

- The EA registers the followerbot's MT5 account with TraderControlServer and
  pushes its account/positions/deals as well as the calendar. `install-ea` sets
  `InpFullHistoryOnStart=false` so it does not backfill deal history on attach.
- The calendar source becomes the followerbot broker's calendar (equivalent for
  USD macro news).
- Everything is gated behind `TRADERCONTROL_EA_ENABLED`; with it `false` (the
  default) nothing is installed and existing deployments are unaffected.
- Re-running `bot-cli install-ea` is idempotent (overwrites the EA and preset).
