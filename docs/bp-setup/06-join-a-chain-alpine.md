# 06 — Joining A-Chain Alpine testnet as a single node

This is the **one doc that matters** for a BP getting hands on PulseVM today.

A-Chain Alpine is the **live PulseVM testnet** running as a subnet on Metal Blockchain's Tahoe network. You don't need to run a local 5-node devnet — just stand up a single MetalGo + PulseVM node and track the subnet. That gets you:

- A local RPC you can hammer without rate limits
- A local WebSocket state-history stream (needed by Hyperion)
- The same binaries and plugin path a real BP would run

## What you need to know about A-Chain Alpine

(All verified 2026-04-15 by hitting the public endpoints.)

| | |
|---|---|
| Parent network | Tahoe (`--network-id=tahoe`, networkID=5) |
| Subnet ID | `zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW` |
| Blockchain ID | `6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y` |
| Antelope chain_id | `0d6f033e887fae475d641104b6e87762b6c869e87a101afeeb64d608ab376618` |
| VM ID | `rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs` |
| Public RPC | `https://a-chain-alpine.metalblockchain.org/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc` |
| Producers | pulsebp1 … pulsebp5 |
| Server version | PulseVM v5.0.3 over MetalGo v1.13.5 |

## Prereqs

You already ran `scripts/bootstrap.sh`, so the box has:

- `/opt/metalgo/metalgo` (v1.13.5-tahoe, rpcchainvm v43)
- `/opt/pulsevm/plugins/rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs` (v0.2.3)
- Ports 9650 (RPC) and 9651 (staking) free

## Step 1 — Drop the per-subnet chain config

PulseVM's controller parses a JSON blob at startup. Even for a read-only syncing node, the blob is mandatory:

```bash
mkdir -p /etc/metalgo/chains/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y

cat >/etc/metalgo/chains/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/config.json <<'EOF'
{
  "producer_name": "observer",
  "producer_key": "PVT_K1_2pjSqJxTbRHq8h8aHHTux81Ypscb36Q2syB8UJbZcUmxbfZdnT"
}
EOF
```

`producer_name` can be any valid 1–12 char Antelope name not on the active producer list (we're not a validator, we won't be picked to produce anyway). `producer_key` is a throwaway — the above key is the one shipped in the pulsevm repo's `chain_config.json`, already public, fine for observer use. **Replace with a dedicated key if you plan to ever produce.**

If you don't supply this, PulseVM aborts with `could not initialize controller: parse error: failed to parse node config JSON: EOF while parsing a value`.

## Step 2 — Launch MetalGo

```bash
tmux new-session -d -s mgo "/opt/metalgo/metalgo \
  --network-id=tahoe \
  --plugin-dir=/opt/pulsevm/plugins \
  --track-subnets=zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW \
  --partial-sync-primary-network=true \
  --chain-config-dir=/etc/metalgo/chains \
  --data-dir=/var/lib/metalgo \
  --log-dir=/var/log/metalgo \
  --http-host=127.0.0.1 \
  --http-port=9650 \
  --staking-port=9651 \
  --public-ip=\$(curl -s https://ipv4.icanhazip.com) \
  --log-level=info \
  > /var/log/metalgo/stdout.log 2>&1"
```

Key flags:

| Flag | Why |
|---|---|
| `--network-id=tahoe` | Tahoe testnet (networkID=5). Metalgo knows Tahoe's genesis, bootstrap peers, upgrade schedule |
| `--plugin-dir` | Where the PulseVM plugin binary lives, named by its exact VM ID |
| `--track-subnets` | Which subnets this node joins. Comma-separated. Without this, the A-Chain subnet is ignored entirely |
| `--partial-sync-primary-network=true` | Skip full C/X-chain sync. We only care about the subnet, not Metal's primary network |
| `--chain-config-dir` | Where per-chain JSON configs live |
| `--public-ip` | Required for peer negotiation. Must be your real external IPv4 |
| `--http-host=127.0.0.1` | RPC bound to localhost only. For a producer node later, never expose RPC publicly |

## Step 3 — Watch it sync

```bash
tail -f /var/log/metalgo/stdout.log
# or
tmux attach -t mgo       # ctrl-b d to detach
```

Milestones to look for:

1. `initializing node` — process started
2. `bootstrapper starting` — P-Chain picking peers
3. `plugin handshake succeeded` — PulseVM plugin forked and talking via gRPC
4. `<6v9NieZi... Chain> starting bootstrapper` — A-Chain sync begins
5. `<6v9NieZi... Chain> starting to fetch blocks` — pulling blocks from peers
6. `accepted state summary` OR `bootstrapped` — caught up

Health check (once it's up):

```bash
curl -s http://127.0.0.1:9650/ext/health | jq '.healthy, .checks | keys'
```

Expected: `true` and a list of checks including the subnet blockchain ID.

## Step 4 — Hit the local PulseVM RPC

```bash
# Same JSON-RPC interface as the public endpoint, just local.
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"pulsevm.getInfo","id":1}' \
  http://127.0.0.1:9650/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc | jq .
```

Should return the same `chain_id` (`0d6f033e…376618`) and `head_block_num` as the public endpoint. Your local node is now a peer — if someone pushes a tx to the public RPC, Snowman gossips the block and your head advances.

## Step 5 — SSH tunnel to hit it from your laptop

Without exposing RPC publicly:

```bash
# On your Mac:
ssh -L 9650:127.0.0.1:9650 pulsevm-dev
# Then from another terminal on your Mac:
curl http://127.0.0.1:9650/ext/bc/6v9NieZi.../rpc -d '...'
```

Or make it automatic — in `~/.ssh/config` for `pulsevm-dev`, add `LocalForward 9650 127.0.0.1:9650`.

## What changes for a real block producer

This is an **observer / full node** config. To become a validator for the subnet:

1. Fund a P-Chain address with Tahoe METAL (testnet faucet or pre-fund from Metallicus).
2. Issue `platform.addValidator` to stake on Tahoe primary network.
3. Issue `platform.addSubnetValidator` to stake on the A-Chain Alpine subnet.
4. Replace the throwaway `producer_key` in chain config with your real Antelope block-signing key.
5. Register an active producer record on the chain by calling the `regproducer` action on the `pulse` account (served by the system-contract WASM deployed there, code hash `a351dd76…` on Alpine).

See [07-joining-network.md](07-joining-network.md) for the production validator flow (stub until Metallicus publishes stake requirements and validator onboarding docs).

## Shutdown

```bash
# Graceful stop via metalgo's own process signal
tmux send-keys -t mgo C-c
# or just
pkill -x metalgo
# then wait ~10 s for "finished node shutdown" before touching data dir
```

Never kill -9 a producing node — chainbase is mmap-based and can leave torn writes.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "failed to parse node config JSON: EOF" | chain config file missing or empty (Step 1) |
| "RPCChainVM protocol version mismatch" | metalgo and pulsevm versions drifted. See [edge-cases.md](../edge-cases.md) |
| Node stays "unhealthy: subnets not bootstrapped" | Still syncing. A-Chain has only 37 blocks, should finish in seconds. If stuck >5 min, check peer connectivity |
| No peers connect | Firewall — port 9651 must be open inbound on the public IP |
| RPC returns 404 | You're hitting `/ext/bc/<wrong_id>/rpc`. Use the blockchain ID from the table above |
| `info.peers` shows 0 | Check DNS + `public-ip` — metalgo couldn't register its address |

## Production hygiene for this setup

Before you let this node run unattended:

1. **Firewall:** `ufw allow 9651/tcp; ufw deny 9650/tcp` (RPC local-only).
2. **Systemd unit** instead of tmux (see [10-upgrades.md](10-upgrades.md)).
3. **Backup** `/var/lib/metalgo/staking/` — contains the NodeID key.
4. **Monitoring:** `/ext/health` every 30 s, alert on `healthy: false`.
5. **Log rotation** — already configured by metalgo (`loggingConfig.maxFiles: 7`, `maxSize: 8 MB`).
