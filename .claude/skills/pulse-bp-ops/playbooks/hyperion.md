# Hyperion (hyperion-rs)

Goal: stand up the indexer + REST API stack alongside a synced Pulse node.

## Branch matters

**Use `MetalBlockchain/hyperion-rs`.** It is Metallicus' Rust rewrite and the indexer run in production; the Node.js `pulsevm-hyperion` fork is legacy. Build with `cargo build --release`, then run `hyperion indexer -c config.toml` and `hyperion api -c config.toml` as two services.

## What gets stood up

- Elasticsearch 9 (the heavy one — 50% of RAM as heap, 50% page cache)
- `hyperion indexer` — reads the node's State-History WebSocket (`ws://127.0.0.1:9090`) and writes ES
- `hyperion api` — the `/v2/*` REST server (port from `[api] listen` in `config.toml`)

The indexer reads PulseVM's SHiP on `127.0.0.1:9090`. **Hyperion must run on the same host as its data source** (or an internal-IP-only network) — never expose `:9090` publicly.

## Bring-up

```bash
git clone https://github.com/MetalBlockchain/hyperion-rs && cd hyperion-rs && cargo build --release
# config.toml: [chain] name/http (the node's /ext/bc/<BID>/rpc)/ship=ws://127.0.0.1:9090/system_account
#              [indexer] start_block = <import head + 1 on an imported chain, else 0>
#              [elasticsearch] url ; [api] listen
./target/release/hyperion indexer -c config.toml   # as a systemd unit
./target/release/hyperion api -c config.toml       # second unit
```

## Verify

```bash
curl http://127.0.0.1:<api port>/v2/health | jq   # Indexer.last_indexed_block must advance
curl 'http://127.0.0.1:<api port>/v2/history/get_actions?limit=5' | jq
```

If `health` is fine but `last_indexed_block` stays 0, `start_block` is wrong (see troubleshooting).

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

## Two things that bite on imported chains

- `[indexer] start_block` must be the import head + 1, or the indexer requests blocks the SHiP cannot serve and never starts.
- `/v1/chain/*` is not Hyperion's job: front the node with `pulse-rest-gateway` (forwards the client's `compression`; reports `admitted`, never `executed`).
