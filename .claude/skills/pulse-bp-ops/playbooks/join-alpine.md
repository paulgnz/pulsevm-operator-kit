# Join A-Chain Alpine (testnet)

You have `metalgo` + `pulsevm` plugin installed. Goal: sync the A-Chain Alpine subnet as an observer.

## Step 1 — Become a primary-network validator on Tahoe

A-Chain Alpine validators must first be primary-network validators on Tahoe (Metal's testnet). Stake the testnet minimum.

1. Move METAL from C-Chain to P-Chain — see Metal docs › transfer-metal-tokens-between-chains.
2. Issue `addPermissionlessValidator` from P-Chain with your NodeID + BLS pubkey + ProofOfPossession.
3. Reference TS builder: `scripts/regprod.ts` (uses `@metalblockchain/metaljs`).

Confirm:

```bash
curl -X POST -H 'content-type: application/json' --data "{
  \"jsonrpc\":\"2.0\",\"method\":\"platform.getCurrentValidators\",
  \"params\":{\"nodeIDs\":[\"NodeID-...\"]},\"id\":1
}" http://127.0.0.1:9650/ext/bc/P
```

## Step 2 — Track the subnet

Edit `~/.metalgo/config.json`:

```json
{
  "track-subnets": "<ALPINE_SUBNET_ID — current value at pulsevm.dev/network/endpoints>",
  "http-host": "0.0.0.0",
  "log-level": "info"
}
```

Drop the Snowman tuning at `~/.metalgo/configs/subnets/<ALPINE_SUBNET_ID>.json`:

```json
{
  "consensusParameters": {
    "k": 5,
    "alphaPreference": 3,
    "alphaConfidence": 4
  }
}
```

Without this you will get `insufficient number of validators` because the defaults (`k=20, alpha=15`) exceed the subnet's validator count; set `k` no larger than `platform.getCurrentValidators` reports and use the same params on every node.

## Step 3 — Restart cleanly

```bash
kill -TERM $(pgrep -x metalgo)
# wait for "finished node shutdown" in the log
metalgo --config-file=~/.metalgo/config.json
```

## Step 4 — Confirm sync

```bash
ALPINE_RPC=http://127.0.0.1:9650/ext/bc/<ALPINE_BLOCKCHAIN_ID>/rpc

curl -s -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"pulsevm.getInfo","params":{},"id":1}' \
  $ALPINE_RPC | jq
```

Compare your `head_block_num` against the public RPC:

```bash
curl -s -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"pulsevm.getInfo","params":{},"id":1}' \
  https://a-chain-alpine.metalblockchain.org/ext/bc/<ALPINE_BLOCKCHAIN_ID>/rpc | jq
```

Within a few seconds of each other = synced.

## Next

→ `playbooks/become-validator.md` to start signing blocks.
