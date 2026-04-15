# Hyperion (pulsevm-hyperion)

Goal: stand up the indexer + REST API stack alongside a synced Pulse node.

## Branch matters

**Use `release/3.6`.** `main` is the 4.0-beta track and is not Pulse-ready (Glenn confirmed, 2026-04-15). Our fork pin lives at `pulsevm-hyperion/.git` checked out to `release/3.6`.

## What gets stood up

- Elasticsearch 9 (the heavy one — 50% of RAM as heap, 50% page cache)
- MongoDB
- RabbitMQ
- Redis
- The Hyperion indexer (Node.js worker pool)
- The Hyperion API (Node.js REST server, default port 7000)

The indexer reads PulseVM's State-History WebSocket on `127.0.0.1:9090`. **Hyperion must run on the same host as its data source** (or an internal-IP-only network) — never expose `:9090` publicly.

## docker-compose

`hyperion/docker-compose.yml` brings up ES + Mongo + Rabbit + Redis. The Hyperion processes themselves run as `pm2`-supervised Node processes against a host-mode Pulse node.

```bash
cd hyperion
docker-compose up -d
docker-compose ps     # confirm 4/4 healthy
```

Then in `pulsevm-hyperion/`:

```bash
git checkout release/3.6
npm ci
# Configure connections.json to point at your local PulseVM SHiP and ES
pm2 start ecosystem.config.js
pm2 logs            # watch indexer catch up
```

## Verify

```bash
curl http://127.0.0.1:7000/v2/health | jq
curl http://127.0.0.1:7000/v2/history/get_actions?limit=5 | jq
```

If `health` is fine but `get_actions` is empty, the indexer hasn't caught up yet. Watch `pm2 logs` for "indexed block X" lines.

## Production-style nginx + TLS

Reference `scripts/nginx-hyperion.conf`. Key shape:

- nginx :80 redirects to :443
- nginx :443 (TLS via Let's Encrypt) reverse-proxies to `127.0.0.1:7000`
- WebSocket upgrade enabled (Hyperion uses socket.io for streaming)
- Cloudflare set to DNS-only (grey cloud) for cert issuance — re-enable proxy after if desired

```bash
sudo certbot --nginx -d <your-host> -m <email> --agree-tos
```

Auto-renewal goes via the certbot systemd timer.

## Known endpoint state on 3.6

| Endpoint | Status |
|---|---|
| `/v2/health` | works |
| `/v2/history/get_actions` | works |
| `/v2/history/get_transaction` | works |
| `/v2/state/get_account` | works |
| `/v2/state/get_creator` | 500 — bug |
| `/v2/state/get_created_accounts` | 500 — bug (PR'd, awaiting merge) |
| `/v2/history/get_transfers` | 404 — not registered |
| `/v2/state/get_producers` | 404 — not registered |
| `/v1/chain/*` | 500 — REST surface not wired in 3.6 |

For `/v1/chain/*` clients, front Hyperion with the `pulsevm-rest-compat` shim (in `rest-compat/`).
