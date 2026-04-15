# Become an A-Chain validator (regproducer)

You're synced as an observer. Goal: add producer config, register on-chain, start signing blocks.

## Step 1 — Add the producer config

Drop `~/.metalgo/configs/chains/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y.json`:

```json
{
  "producer_name": "yourbp",
  "producer_key": "PVT_K1_..."
}
```

> The on-disk private key is fine for testnet. **It is an audit finding on mainnet.** Use `pulse-keosd` or a hardware signer (Ledger / YubiHSM). See `playbooks/split-mainnet.md`.

Restart metalgo (`kill -TERM`, wait for shutdown line, restart).

## Step 2 — `regproducer`

The action requires dual `pulse@active` + `<yourbp>@active` authorization. On Alpine, ask Metallicus to co-sign. On mainnet you'll have your own multi-sig setup.

Action shape:

```json
{
  "account": "pulse",
  "name": "regproducer",
  "authorization": [
    { "actor": "pulse",   "permission": "active" },
    { "actor": "yourbp",  "permission": "active" }
  ],
  "data": {
    "producer": "yourbp",
    "producer_key": "PUB_K1_...",
    "url": "https://yourbp.example/bp.json",
    "location": 554
  }
}
```

Push via `pulse-cli`, `pulsevm-js`, or whatever signer you trust.

## Step 3 — Confirm you're producing

Wait ~2 minutes for Snowman to start picking you. With N=6 validators, expect ~17% of blocks.

```bash
pulse chain:info | jq '{head:.head_block_num, producer:.head_block_producer}'
```

Or via Hyperion:

```
GET https://<your-hyperion-host>/v2/history/get_actions?account=yourbp&filter=*::onblock
```

## Step 4 — Heartbeat (testnet only)

To keep the chain busy and validate end-to-end signing, run a 1-XPR-every-30s loop from your own account:

```bash
while true; do
  pulse transfer yourbp pulse "1.0000 XPR" "heartbeat $(date -u +%FT%TZ)"
  sleep 30
done
```

Don't do this on mainnet — pointless on-chain spam. Useful only when validating a fresh testnet bring-up.

## Failure modes to watch

- **`missing authority of pulse`** — you didn't co-sign. The action needs `pulse@active` AND `yourbp@active`.
- **Block rate looks wrong** — `kill -TERM` and restart cleanly. If the producer config is malformed, metalgo logs "producer not enabled" at startup.
- **Signing key mismatch** — `producer_key` private must correspond to the `producer_key` public registered via `regproducer`. A rotation requires `pulse::updateauth` + chain config edit + restart.
