# 07 — Becoming a validator on A-Chain Alpine

The end-to-end sequence to register a new validator on A-Chain Alpine, verified live in April 2026. Every script referenced is in [`scripts/`](../../scripts/) and works against the live testnet.

There are **three layers + a trigger**:

| Step | Layer | Who can do it | Script |
|---|---|---|---|
| A | Tahoe primary-network validator | You, given some METAL | [`scripts/metalgen.mjs`](../../scripts/metalgen.mjs) → [`scripts/bridge-c-to-p.mjs`](../../scripts/bridge-c-to-p.mjs) → [`scripts/add-validator.mjs`](../../scripts/add-validator.mjs) |
| B | A-Chain Alpine subnet validator | Metallicus only (permissioned) | (P-Chain `addSubnetValidator`, signed by their control key) |
| C | PulseVM `regproducer` + chain config update | You + Metallicus co-sign | [`scripts/regprod.mjs`](../../scripts/regprod.mjs) |
| D | Trigger block production | Anyone with an account | [`scripts/heartbeat.mjs`](../../scripts/heartbeat.mjs) |

If your goal is to be a fully-working A-Chain Alpine BP that actually gets selected by Snowman to build blocks, **you need all four**.

## Step A — Become a Tahoe primary-network validator

A-Chain Alpine runs as a subnet on Metal Blockchain's Tahoe network. Subnet validation requires Tahoe primary-network validation first.

### A.1 Generate a P-Chain keypair offline

metalgo v1.13+ removed the keystore API ([upstream AvalancheGo deprecation](https://github.com/ava-labs/avalanchego)). So we generate the P-Chain key offline using `@metalblockchain/metaljs`:

```bash
node scripts/metalgen.mjs
```

Output:
- `P-tahoe1...`  P-Chain address
- `PrivateKey-...`  CB58 form (import into metalgo / metaljs / avalanchejs)
- `0x...`  hex form (alternative)
- `0x...`  EVM-derived address (what MetaMask sees) — derived via `scripts/derive-addresses.mjs`

Stash the CB58 private key in 1Password before doing anything else.

### A.2 Get Tahoe METAL onto your address

Easiest path: Metallicus sends you ~2 METAL on Tahoe C-Chain (EVM) from MetaMask / Core. The C-Chain EVM address you give them is `0x...` — **not** the P-Chain address. They share the underlying secp256k1 key but the addressing scheme differs (P-Chain is Bech32 with HRP `tahoe`, EVM is keccak256 of uncompressed pubkey).

Configure Metamask for Metal Tahoe C-Chain:

```
RPC: https://tahoe.metalblockchain.org/ext/bc/C/rpc
Chain ID: 381932
Symbol: METAL
```

### A.3 Cross-chain C → P

```bash
AVAX_PRIV='PrivateKey-...' AMOUNT_METAL=1.5 node scripts/bridge-c-to-p.mjs
```

Two atomic txs run back to back:
1. **C-Chain ExportTx** — pops METAL from EVM into atomic memory.
2. **P-Chain ImportTx** — pulls the UTXOs into your `P-tahoe1...` address.

Important quirks (all baked into the script):
- C-Chain side denominates in nAVAX (9 decimals) but EVM balance is in wei (18 decimals). The script handles the conversion.
- C-Chain `getBlockchainID()` returns the alias `"tahoe"` not the cb58 hash by default — call `await cchain.refreshBlockchainID()` first or `buildExportTx` throws "not a valid base58 string".
- Pass an explicit fee on the export (we use 1,000,000 nAVAX = 0.001 METAL). Default fee=0 is rejected as "insufficient funds".
- Use `ethers.Wallet(hexPriv).address` to derive the EVM address; `cKC.getAddresses()` returns the Bech32 form (different bytes — sending METAL there doesn't brick you but needs a follow-up).

### A.4 Stake to register as a validator

```bash
AVAX_PRIV='PrivateKey-...' \
NODE_ID='NodeID-Msadbx...hpS' \
BLS_PUBKEY='0x...' \
BLS_POP='0x...' \
STAKE_METAL=1 \
DURATION_DAYS=14 \
node scripts/add-validator.mjs
```

Your NodeID + BLS public key + proof-of-possession come from `~/.metalgo/staking/` (metalgo generates them on first boot). Get them from `info.getNodeID` and `info.getNodeVersion`.

Min stake on Tahoe is 1 METAL (1,000,000,000 nAVAX). 14 days is fine for testnet.

The script wraps `platform.addPermissionlessValidator` with the right `Signer` typeID (`PlatformVMConstants.SIGNERPRIMARYNETWORK = 28`) wrapping the BLS `ProofOfPossession`. Without that exact wrapping, the tx is rejected.

### A.5 Verify

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"platform.getCurrentValidators","params":{"nodeIDs":["NodeID-Msadbx...hpS"]},"id":1}' \
  https://tahoe.metalblockchain.org/ext/bc/P | jq .
```

You should see your NodeID with `weight: 1000000000`. `connected: true` may take 10–30 min of sustained primary-network participation before flipping. **Crucial:** if your metalgo is running with `--partial-sync-primary-network=true` (an observer-mode optimisation), drop that flag — primary-network validators must validate P + X + C; with partial-sync you'll be benched on C and X and `connected` never flips. See [edge-cases.md](../edge-cases.md) for the gotcha.

## Step B — Get added to the A-Chain Alpine subnet validator set

A-Chain Alpine subnet (`zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW`) is **permissioned**:

```json
"isPermissioned": true,
"controlKeys": ["P-tahoe1z4t73n559f78p2nukn7kcn3x9dnm4em84xypan"],
"threshold": "1"
```

Only Metallicus can add subnet validators. Send them your NodeID + BLS pubkey + PoP and ask them to fire `platform.addSubnetValidator` for your NodeID on subnet `zT2up…CxLW`.

This step must wait until **after Step A.4** — addSubnetValidator requires the NodeID to already be in the primary-network validator set.

Verify the add:

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"platform.getCurrentValidators","params":{"subnetID":"zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW","nodeIDs":["NodeID-Msadbx...hpS"]},"id":1}' \
  https://tahoe.metalblockchain.org/ext/bc/P | jq .
```

Your NodeID should appear with `weight: 1` (subnet validators on Alpine all carry weight 1; the consensus is permissioned, not stake-weighted, today).

## Step B+ — Drop the canonical subnet consensus config

**Do this BEFORE you'd otherwise expect the chain to make progress on your node.** Without it, the default Snowman params (`k=20, alphaPreference=15, alphaConfidence=15, beta=20`) cannot reach quorum on a 6-validator subnet, so every Snowman query drops with `insufficient number of validators` and your node's view of the chain freezes at the height it had when it joined.

Metallicus's canonical config (Glenn shared, 2026-04-15):

```bash
mkdir -p ~/.metalgo/configs/subnets
cat > ~/.metalgo/configs/subnets/zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW.json <<'EOF'
{
  "consensusParameters": {
    "k": 5,
    "alphaPreference": 3,
    "alphaConfidence": 4
  }
}
EOF
```

Make sure your `node.json` has `"subnet-config-dir": "/root/.metalgo/configs/subnets"` (or wherever you put the file). Restart metalgo gracefully (SIGTERM, never `kill -9` — see [edge-cases.md](../edge-cases.md) on the Chainbase dirty flag).

The reference copy of this config lives at [`scripts/alpine-subnet-config.json`](../../scripts/alpine-subnet-config.json).

## Step C — Register on PulseVM as a producer

Two parts: register via the contract action, then update your node so when Snowman picks you the block is signed by the right key.

### C.1 The `regproducer` action (dual-signed)

`pulse@regproducer` requires both `pulse@active` AND `<your-account>@active` in the authorization list. Metallicus shares the testnet `pulse@active` private key for self-onboarding BPs:

```bash
PULSE_PRIV='PVT_K1_...the-shared-testnet-pulse-key...' \
PROTONNZ_PRIV='PVT_K1_...your-key...' \
node scripts/regprod.mjs
```

The script signs the same digest with both keys and pushes via `pulsevm.issueTx`.

Verification:

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"pulsevm.getTableRows","id":1,"params":{"code":"pulse","scope":"pulse","table":"producers","lower_bound":"","upper_bound":"","limit":50,"json":true,"reverse":false,"index_position":"1","key_type":"name","encode_type":"dec"}}' \
  https://a-chain-alpine.metalblockchain.org/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc | jq '.result.rows | map(.owner)'
```

You should see your account name in the list. (As of 2026-04-15: `protonnz, pulsebp1, pulsebp2, pulsebp3, pulsebp4, pulsebp5`.)

### C.2 Update PulseVM chain config

Even though Metallicus has registered you, your local PulseVM plugin still has `producer_name` set to whatever you configured during observer-mode bootstrap (e.g. `"observer"`). When Snowman picks your NodeID to build a block, the plugin signs the block claiming to be `"observer"`, which is not a registered producer — block rejected.

Update `/etc/metalgo/chains/<blockchainID>/config.json`:

```json
{"producer_name":"<your-account>","producer_key":"PVT_K1_..."}
```

The `producer_key` here is the active-permission private key you registered via `regproducer`. **This key sits on the producer node's disk** — for testnet, fine; for mainnet, use a hardware signer / pulse-keosd integration.

Then graceful restart:

```bash
pkill -TERM metalgo  # SIGTERM — wait for clean shutdown, see edge-cases on dirty flag
# wait for metalgo to exit, then start back up
```

## Step D — Trigger block production

PulseVM only produces blocks when there's something in the mempool. Without activity, your node never gets selected and you never produce. Easy fix: a heartbeat loop.

```bash
SIGNER_PRIV='PVT_K1_...' FROM=protonnz TO=hello QTY='1.0000 XPR' INTERVAL_SEC=30 \
pm2 start scripts/heartbeat.mjs --name xpr-heartbeat --time
```

Each tx triggers a new block; Snowman picks a builder uniformly across the subnet validator set; over enough heartbeats your NodeID rotates in. With 6 validators, you should be picked every ~6 heartbeats on average.

Verify your block:

```bash
# fetch each new block since some baseline and look for your account in producer field
for b in $(seq 50 60); do
  P=$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"pulsevm.getBlock\",\"id\":1,\"params\":{\"block_num_or_id\":\"$b\"}}" \
    https://a-chain-alpine.metalblockchain.org/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc \
    | jq -r '.result.producer // "?"')
  echo "block $b producer=$P"
done
```

When you see a block with your name as `producer`, you've fully closed the loop.

`protonnz`'s first block was **#50 at 2026-04-15T02:08:00Z** — exactly as described above, end-to-end on a fresh Hetzner box.

## Operator quick-ref

For when you're skimming this in the middle of an outage:

```
A. Generate P-Chain key, get METAL, bridge C→P, addPermissionlessValidator
B. Email Glenn your NodeID + BLS pubkey + BLS PoP for addSubnetValidator
B+. Drop ~/.metalgo/configs/subnets/<subnetID>.json with k=5, alpha=3/4
C. regproducer (dual-signed) + chain-config-dir/.json with your producer_key
D. heartbeat under pm2 to trigger block production
```

Total wall-clock from a fresh cloud box, assuming Metallicus is responsive: ~1 hour.

## What does NOT yet work on Alpine (so don't bother debugging)

Per Glenn (2026-04-15) and our on-chain ABI decode, the deployed `pulse` system contract is missing several Antelope-equivalent action surfaces:

- No `voteproducer` / `voteproxy` — you cannot vote for BPs yet
- No `claimrewards` — no producer rewards being distributed
- No `bidname` — no name auctions
- No `buyram` / `sellram` — RAM market not exposed (only `buyrambsys` from privileged account)
- No REX actions (despite tables existing)
- `onblock` is declared in the ABI but not invoked at block boundaries — no schedule rotation, no inflation

Producer-builder selection happens entirely at the Avalanche/Snowman layer — flat random across subnet validators. The `producers` table is currently a registration record only. Plan accordingly.

## Files referenced

- [`scripts/metalgen.mjs`](../../scripts/metalgen.mjs) — generate P-Chain keypair offline
- [`scripts/derive-addresses.mjs`](../../scripts/derive-addresses.mjs) — derive X/P/C-EVM addresses for the same key
- [`scripts/bridge-c-to-p.mjs`](../../scripts/bridge-c-to-p.mjs) — atomic C→P cross-chain
- [`scripts/add-validator.mjs`](../../scripts/add-validator.mjs) — primary-network stake
- [`scripts/regprod.mjs`](../../scripts/regprod.mjs) — dual-signed `pulse@regproducer`
- [`scripts/heartbeat.mjs`](../../scripts/heartbeat.mjs) — pm2 activity loop
- [`scripts/transfer.mjs`](../../scripts/transfer.mjs) — one-shot `pulse.token@transfer`
- [`scripts/dump-abi.mjs`](../../scripts/dump-abi.mjs) — fetch + decode any account's live on-chain ABI
- [`scripts/alpine-subnet-config.json`](../../scripts/alpine-subnet-config.json) — Metallicus's canonical Snowman config for A-Chain Alpine
- [`wiki/edge-cases.md`](../edge-cases.md) — every gotcha we hit, in order, with verified fixes
