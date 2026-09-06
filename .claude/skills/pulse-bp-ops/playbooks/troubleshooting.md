# Troubleshooting

Catalogue of issues we've actually hit, with verified fixes. Keep this list curated — it's the most-read playbook.

## Node will not resume after an unclean shutdown

**Symptom:** the chain fails to create with `could not initialize controller: …` naming the block log, `synced_schedule.bin`, or a revision mismatch.

**Cause:** metalgo was hard-killed (or the host crashed) between the arena checkpoint and its companion files.

**Fix:** stop cleanly (`kill -TERM`, wait for the shutdown line), then either restore `chainData/<blockchainID>/` from a backup taken after a clean stop, or wipe it and resync (DESTRUCTIVE — full resync follows).

**Prevention:** never `kill -9 metalgo`. Always SIGTERM and wait for the shutdown line.

## "context deadline exceeded" on plugin handshake

**Symptom:** metalgo logs `failed to start chain: context deadline exceeded` referencing the Pulse plugin.

**Cause:** rpcchainvm protocol version mismatch between metalgo and pulsevm.

**Fix:** pin both binaries to the same release line. Tahoe runs the metalgo 1.13.x line (rpcchainvm v43); every pulsevm release states the rpcchainvm version it was built against — they must agree. metalgo 1.12.x (v39) won't load any current plugin.

```bash
metalgo --version
ls -la /opt/pulsevm/plugins/
```

If versions are wrong, re-run `scripts/bootstrap.sh` — it pins the matching pair.

## "insufficient number of validators"

**Symptom:** Snowman refuses to make progress on the subnet; metalgo logs "insufficient number of validators".

**Cause:** default Snowman params (`k=20, alphaPreference=15`) exceed the subnet's validator count (check `platform.getCurrentValidators` for the subnet).

**Fix:** drop `~/.metalgo/configs/subnets/<subnetID>.json`:

```json
{
  "consensusParameters": {
    "k": 5,
    "alphaPreference": 3,
    "alphaConfidence": 4
  }
}
```

Restart metalgo. **All nodes on the subnet must use the same params** or you'll fork against yourself.

## "missing authority of pulse" when creating an account

**Symptom:** `pulse::newaccount` push returns `missing authority of pulse`.

**Cause:** `newaccount` is gated on `pulse@active` on the current Pulse system contract — regular accounts cannot create accounts.

**Fix:** on Alpine, ask Metallicus to run the action. On mainnet this becomes a system contract action with a defined fee.

## Hyperion answers but history is empty, or `/v1/chain/*` 500s

**Symptom:** `/v2/health` is OK but `last_indexed_block` stays 0, or legacy `/v1/chain/*` calls fail.

**Cause:** on an imported chain hyperion-rs must start at the import head + 1 (`[indexer] start_block`); with `0` it asks the SHiP for blocks it cannot serve. `/v1/chain/*` is not a Hyperion surface.

**Fix:** set `start_block`, wipe the `xpr-*` (or chain-named) Elasticsearch indices, restart `hyperion-rs-indexer` and `-api`. For `/v1/chain/*` clients, front the node with `pulse-rest-gateway`.

## Validator added to P-Chain but not building blocks

**Symptom:** `addPermissionlessValidator` confirmed; node is in `platform.getCurrentValidators`; chain config has `producer_name`; but you never sign a block.

**Diagnostics:**

1. `kill -TERM` and restart metalgo — sometimes the producer plugin starts in a bad state if config was edited mid-run.
2. Check the per-chain log for "producer not enabled" — means the chain config JSON is malformed (most often a missing comma or wrong filename — must be `<blockchainID>.json` exactly).
3. Confirm the BLS key in your staker matches what you registered with `addPermissionlessValidator`.
4. Expect roughly 1/N of blocks for N current validators; over a 5-minute window if you've signed zero, something's wrong. Over a 1-minute window, just rotation luck.

## Cross-chain transfer hung (METAL C → P)

**Symptom:** `avm.export` confirmed on C-Chain, but `platform.import` on P-Chain returns "no atomic UTXOs".

**Fix:** check the destination — atomic memory is per-direction. Make sure you ran `platform.importTx` and not `avm.importTx`. Also: the C-Chain export uses the EVM `0x...` address; the P-Chain import uses the bech32 `P-...` address — they're different keypairs, easy to mix up.

## TLS cert issuance failed via certbot HTTP-01

**Symptom:** certbot HTTP-01 challenge fails with 404 / connection refused.

**Cause:** Cloudflare proxying or nginx 80→443 redirect intercepting the challenge.

**Fix:** before requesting the cert, set the Cloudflare DNS record to **DNS-only** (grey cloud, not orange). After the cert lands, you can re-enable the proxy if you want the WAF benefits (though it's overkill for a JSON RPC).
