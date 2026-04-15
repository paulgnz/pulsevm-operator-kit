# 04 — MetalGo config & flags

MetalGo is the parent daemon. A BP operator's mental picture should be: **MetalGo is to PulseVM as Kubernetes is to a pod.** It schedules, supervises, networks, and exposes RPC.

## Data root

Default: `~/.metalgo/` (for root: `/root/.metalgo/`). Override: `--data-dir=...`.

Layout:

```
~/.metalgo/
├── configs/                  node.json, chains/<chainID>.json, subnets/<subnetID>.json, upgrades/...
├── db/                       primary-network chain databases (P, X, C)
├── chainData/<chainID>/      per-subnet chain data (e.g. PulseVM's chainbase FFI lives here)
├── logs/                     per-chain stdout/stderr
├── network/                  p2p peer list, TLS certs
├── plugins/                  VM plugin binaries — metalgo loads these at start
└── staking/                  staker.key, staker.crt, signer.key  ← back these up
```

**Never run two metalgo instances pointed at the same data dir.** Chainbase is mmap-based; concurrent writers corrupt state silently.

## Flags you'll actually use

```bash
/opt/metalgo/metalgo \
    --data-dir /var/lib/metalgo \
    --plugin-dir /opt/pulsevm/plugins \
    --network-id fuji                          # or mainnet; "local" for local devnet
    --http-host 127.0.0.1 \
    --http-port 9650 \
    --staking-port 9651 \
    --public-ip $EXTERNAL_IP \
    --log-level info \
    --log-dir /var/log/metalgo \
    --chain-config-dir /etc/metalgo/chains \
    --subnet-config-dir /etc/metalgo/subnets \
    --track-subnets 2EoLb7EoV3XqLPzWe4WSWFQ6... \ # subnet IDs we care about
    --bootstrap-ips=... --bootstrap-ids=...       # entry-point peers
```

Flags that matter most for a BP:

| Flag | Why |
|---|---|
| `--data-dir` | Keep off the OS disk if possible; use dedicated NVMe volume |
| `--public-ip` | Without it, peer address negotiation is guesswork. Set to the actual public IPv4 |
| `--staking-port` | Peers dial this. Must be open in firewall |
| `--http-host 127.0.0.1` | RPC bound to localhost only for producer nodes. Expose via reverse proxy / VPN if needed |
| `--http-port` | RPC port. 9650 is the default. Path: `http://host:port/ext/bc/<chainID>/rpc` |
| `--track-subnets` | Comma-sep list of subnet IDs to validate. Without this, metalgo ignores the subnet entirely |
| `--chain-config-dir` | Where per-chain JSON configs live. PulseVM expects its subnet config here |
| `--log-level` | `info` in prod, `debug` only when debugging |
| `--health-check-frequency` | Tune if your dashboards care |

## Subnet + chain config

To *validate* a subnet, you need to:

1. Register your NodeID as a validator on the P-Chain (costs METAL stake).
2. Opt into the subnet with `--track-subnets=<subnetID>`.
3. Provide the VM plugin at `<plugin-dir>/<VM_ID>`.
4. Provide the chain's subnet config (`--subnet-config-dir`) and chain config (`--chain-config-dir`) if the chain wants non-default values.

PulseVM's **chain config** file:

```
${CHAIN_CONFIG_DIR}/<pulsevm_chain_id>.json
```

The repo ships a minimal `chain_config.json` which is loaded by metal-network-runner automatically. For a real subnet validator, generate it per chain. Contents are node-local (not consensus-bound).

## RPC URLs a BP needs to bookmark

Once metalgo is up and PulseVM is created on the subnet:

```
# metalgo base
http://127.0.0.1:9650/

# metalgo health
http://127.0.0.1:9650/ext/health

# metalgo metrics (Prometheus scrape)
http://127.0.0.1:9650/ext/metrics

# metalgo info (nodeID, version, peers)
POST http://127.0.0.1:9650/ext/info   — method "info.getNodeVersion", etc.

# PulseVM JSON-RPC on the subnet chain
POST http://127.0.0.1:9650/ext/bc/<pulsevm_chain_id>/rpc
     Content-Type: application/json
     Body: {"jsonrpc":"2.0","method":"pulsevm.getInfo","id":1}

# PulseVM state-history WebSocket (configured via pulsevm env var, default :9090 on the node)
ws://127.0.0.1:9090/
```

The `<pulsevm_chain_id>` is printed by `metal-network-runner control status` (for local) or by P-Chain `createChain` tx receipt (for real subnets).

## Staking key security

`~/.metalgo/staking/staker.key` is the private half of your validator identity. If exfiltrated:

- An attacker with network access can register as you and eat your rewards.
- They cannot (directly) sign block-level transactions — that's still your Antelope K1 key.

Best practice:

1. After first metalgo boot, copy `staker.key + staker.crt + signer.key` off to a secrets store.
2. Set perms `chmod 600` on the files, owned by the metalgo service user.
3. Rotate if you ever suspect compromise (requires re-staking).

The Tahoe pre-release may auto-generate BLS `signer.key` — check `~/.metalgo/staking/` after first boot.

## Upgrading metalgo

For a BP with a warm-spare setup:

1. Download new binary to `/opt/metalgo/metalgo.new`.
2. Stop spare node, swap binary, start — verify healthy.
3. Promote spare to primary (peer announce, or DNS/proxy swap).
4. Upgrade old primary.

Don't just `kill` a running metalgo in mid-consensus — it can leave the subnet with incomplete block state. Use `SIGTERM` and wait for the "finished node shutdown" log line before replacing the binary.

## Logs

Primary-network logs:

```
~/.metalgo/logs/main.log
~/.metalgo/logs/P.log    # P-Chain
~/.metalgo/logs/X.log    # X-Chain
~/.metalgo/logs/C.log    # C-Chain (EVM)
```

Subnet/chain logs:

```
~/.metalgo/logs/<pulsevm_chain_id>.log    # the PulseVM chain
```

PulseVM plugin logs interleave with the chain log — metalgo pipes the plugin's stderr. When debugging contract issues, look for `pulsevm` or `pulse` substring lines within `<chain_id>.log`.

## Node health quick check

```bash
curl -s http://127.0.0.1:9650/ext/health | jq .
# {
#   "checks": { ... },
#   "healthy": true
# }
```

Expected subchecks:
- `bootstrapped` — is the primary network bootstrapped
- subnet chain IDs — each subnet you track has a health entry
- `network.percentConnected` — peer mesh connectivity (should be 1.0 on stable network)

If `healthy: false`, scroll the error; usually it's "chain not bootstrapped" (wait) or "rpcchainvm version mismatch" (see [edge-cases.md](../edge-cases.md)).
