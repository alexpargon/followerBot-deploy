# FollowerBot Control API

The control API is opt-in. It does not listen unless
`FOLLOWERBOT_CONTROL_API_KEY` is set in `/opt/bot-config/.env`, and Docker does
not publish it unless `FOLLOWERBOT_CONTROL_PUBLISH_ADDRESS` is configured in
the same file.

## Private deployment

1. Generate a dedicated secret with `openssl rand -hex 32`.
2. Set these bot variables:

   ```dotenv
   FOLLOWERBOT_CONTROL_API_KEY=<generated secret>
   FOLLOWERBOT_CONTROL_BIND=0.0.0.0
   FOLLOWERBOT_CONTROL_PORT=8787
   FOLLOWERBOT_CONTROL_PUBLISH_ADDRESS=0.0.0.0
   ```

3. Apply the deployment configuration. Port publication requires container
   recreation, so a normal restart is insufficient:

   ```bash
   bot-cli apply-config
   ```

4. Restrict the port to the private VPN/LAN or place TLS ingress in front of
   it. Do not publish raw HTTP to the internet.

5. Verify the listener from the LXC and then another LAN device:

   ```bash
   curl -i http://127.0.0.1:8787/api/control/v1/health
   curl -i http://<LXC-IP>:8787/api/control/v1/health
   ```

Every protected request uses `X-FollowerBot-Key`. `GET
/api/control/v1/health` is intentionally unauthenticated and returns no account
or strategy data. Mutations require `expected_revision`; stale clients receive
HTTP 409 and must refresh before retrying.

## Configuration endpoints

- `GET /api/control/v1/strategies` returns runtime state, risk, behavior,
  basket settings, and pending-restart fields for every strategy.
- `PATCH /api/control/v1/strategies/{id}` updates validated strategy settings.
- `GET /api/control/v1/general` returns non-sensitive global operation values.
- `PATCH /api/control/v1/general` currently updates the global SL safety buffer.

Nullable basket distances preserve `.env` `AUTO` semantics: JSON `null` means
adaptive calculation, while numeric zero remains zero. The API never returns
credentials, listener configuration, routing identity, or filesystem paths.

## Suspension behavior

Turning a strategy Off stops its MT5-mutating components and ignores ordinary
signals. It does not close or modify positions already open at the broker. The
signal source remains available as an observer. A close-all signal received
while suspended is not executed; it is appended to `control_alerts.jsonl` and
returned by `GET /api/control/v1/alerts`.

The durable alert endpoint supports foreground refresh. Background APNs push
requires the TradingControl backend to expose an authenticated bot-alert
ingestion endpoint; that backend is not part of these repositories.