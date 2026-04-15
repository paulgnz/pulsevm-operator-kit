# 09 — Testing guide

How to exercise PulseVM without waiting for XPR mainnet cutover. **The canonical path today is to test against A-Chain Alpine** — Metallicus's live PulseVM testnet running as a subnet on Metal Blockchain Tahoe. Everything downstream (Hyperion, contracts, SDK smoke tests) should point there.

Local 5-node devnets (via `metal-network-runner`) are kept as a fallback for disconnected development and for reproducing protocol-level bugs — **not** for day-to-day BP rehearsal. A-Chain Alpine is real validators, real blocks, real state; use it.

## Path A (recommended): connect to A-Chain Alpine

See [bp-setup/06-join-a-chain-alpine.md](bp-setup/06-join-a-chain-alpine.md) for the operational walkthrough. Short form:

```bash
# Prereq: bootstrap.sh has run
mkdir -p /etc/metalgo/chains/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y
cat >/etc/metalgo/chains/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/config.json <<'EOF'
{"producer_name":"observer","producer_key":"PVT_K1_2pjSqJxTbRHq8h8aHHTux81Ypscb36Q2syB8UJbZcUmxbfZdnT"}
EOF

tmux new-session -d -s mgo "/opt/metalgo/metalgo \
  --network-id=tahoe \
  --plugin-dir=/opt/pulsevm/plugins \
  --track-subnets=zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW \
  --partial-sync-primary-network=true \
  --chain-config-dir=/etc/metalgo/chains \
  --data-dir=/var/lib/metalgo \
  --log-dir=/var/log/metalgo \
  --http-host=127.0.0.1 --http-port=9650 --staking-port=9651 \
  --public-ip=\$(curl -s https://ipv4.icanhazip.com) \
  --log-level=info > /var/log/metalgo/stdout.log 2>&1"
```

Verify:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"pulsevm.getInfo","id":1}' \
  http://127.0.0.1:9650/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc \
  | jq '{head: .result.head_block_num, chain_id: .result.chain_id}'
```

Expected: `head` and `chain_id` match the public Alpine RPC.

### What to probe

- **`pulsevm.getInfo`** — head, LIB, chain_id, head producer.
- **`pulsevm.getAccount`** — `pulse`, `pulsebp1`..`pulsebp5`. Inspect permissions, balances, voter_info.
- **`pulsevm.getBlock`** — retrieve block 37 (the current head as of 2026-04-10) and verify its transactions — several `pulse.token@transfer` actions.
- **`pulsevm.getTableRows`** — once we know the ABI of the system contract at `pulse` (code hash `a351dd76…`), read the producers / voters / rex tables.

### What you cannot do read-only

- Create accounts
- Push transactions
- Register a producer

All of those need a payer account with signing authority — see [00-migration-playbook.md](00-migration-playbook.md) Phases 3–5.

## Path B (fallback): local throwaway devnet

Only pick this path if:
- You need to reproduce a bug that would affect a shared network.
- You want to test a patched PulseVM build that's not yet merged.
- A-Chain Alpine is down for maintenance and you want to keep working.

For a BP rehearsal you should not use this path.

If you do need it: run `INSTALL_MNR=1 bash scripts/bootstrap.sh` to install `metal-network-runner`. Then launch a 5-node local network:

```bash
tmux new-session -d -s mnr \
  "/opt/bin/metal-network-runner server --port=:8080 --grpc-gateway-port=:8081 > /var/log/mnr-server.log 2>&1"

# Wait a few seconds, then:
/opt/bin/metal-network-runner control start \
  --request-timeout=10m \
  --endpoint="0.0.0.0:8080" \
  --number-of-nodes=5 \
  --avalanchego-path /opt/metalgo/metalgo \
  --plugin-dir /opt/pulsevm/plugins \
  --blockchain-specs '[{"vm_name":"pulsevm","genesis":"/root/pulsevm-experimental/pulsevm/genesis.json"}]'
```

**Important caveats for Path B (all captured in [edge-cases.md](edge-cases.md)):**

1. The repo's `chain_config.json` has **per-node producer config** keyed by node name. `metal-network-runner` does **not** auto-split this into per-node chain configs, and the local devnet will fail to initialize PulseVM with "EOF while parsing node config JSON" unless you pass `--chain-configs` with per-blockchain content. Not a BP workflow; solving it is out of scope for this guide.
2. Default `--request-timeout=3m` is too short for 5-node local bootstrap on a 4-vCPU box — always pass `10m`.
3. `--metalgo-path` was renamed to `--avalanchego-path` in MNR v1.9.0. The pulsevm README is stale.

## Smoke tests from your Mac (no local node required)

You can exercise the whole API against the public Alpine endpoint from your laptop:

```bash
RPC='https://a-chain-alpine.metalblockchain.org/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc'

curl -s -X POST -H 'Content-Type: application/json' $RPC -d '{
  "jsonrpc":"2.0","method":"pulsevm.getInfo","id":1
}' | jq .

curl -s -X POST -H 'Content-Type: application/json' $RPC -d '{
  "jsonrpc":"2.0","method":"pulsevm.getAccount","id":1,
  "params":{"account_name":"pulsebp3"}
}' | jq '.result | {name: .account_name, created, privileged}'
```

Useful for testing clients (`pulsevm-js`, our `pulse-cli-ts` fork, any dapp integration) without needing to sync a full node. Just keep in mind the public RPC is rate-limited / subject to maintenance — it's not a production-grade endpoint for BPs.

## Writing transactions (when we have an account)

Once Metallicus issues us `protonnz` with resources, the simplest test is a self-to-self transfer of 0.0001 SYS. Template once the CLI fork is ready:

```bash
# protonnz active key already imported into pulse-keosd / pulse-cli wallet
pulse-cli transfer protonnz protonnz "0.0001 SYS" "smoke test"
```

Underneath: build `pulse.token@transfer` action with `{from: "protonnz", to: "protonnz", quantity: "0.0001 SYS", memo: "smoke test"}`, sign with active key, push. If the response returns a `transaction_id` and the next `pulsevm.getBlock` shows our action, the full write path works.

See [pulse-cli-ts/](../pulse-cli-ts/) for the current state of the fork. The `transact()` implementation is in `src/storage/networks.ts`.
