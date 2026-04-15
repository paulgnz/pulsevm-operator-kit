# Troubleshooting

Catalogue of issues we've actually hit, with verified fixes. Keep this list curated — it's the most-read playbook.

## "Database dirty flag set" on metalgo startup

**Symptom:** metalgo refuses to mount the Pulse plugin's chain DB. Logs mention Chainbase dirty flag.

**Cause:** previous metalgo was killed with `SIGKILL` (or the host hard-crashed), leaving the mmap state DB in an inconsistent state.

**Fix:**

```bash
# 1. Stop metalgo cleanly first
kill -TERM $(pgrep -x metalgo)
# wait for "finished node shutdown" in logs

# 2. Wipe the dirty chain DB (DESTRUCTIVE — full resync follows)
rm -rf ~/.metalgo/chainData/<blockchainID>/

# 3. Restart
metalgo --config-file=~/.metalgo/config.json
```

The node will re-sync from peers (hours on mainnet, minutes on a small testnet).

**Prevention:** never `kill -9 metalgo`. Always SIGTERM and wait for the shutdown line.

## "context deadline exceeded" on plugin handshake

**Symptom:** metalgo logs `failed to start chain: context deadline exceeded` referencing the Pulse plugin.

**Cause:** rpcchainvm protocol version mismatch between metalgo and pulsevm.

**Fix:** pin both binaries to the same release line. Tahoe is currently on metalgo `1.13.x-tahoe` (rpcchainvm v43); Pulse `v0.2.3` was built against this. metalgo `1.12.x` speaks v39 and won't load.

```bash
metalgo --version
ls -la /opt/pulsevm/plugins/
```

If versions are wrong, re-run `scripts/bootstrap.sh` — it pins the matching pair.

## "insufficient number of validators"

**Symptom:** Snowman refuses to make progress on the subnet; metalgo logs "insufficient number of validators".

**Cause:** default Snowman params (`k=20, alphaPreference=15`) are impossible on a small testnet (e.g. Alpine has 6).

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

## Hyperion 500 errors on `/v1/chain/*` or specific v2 endpoints

**Symptom:** Hyperion 3.6 returns 500 on legacy `/v1/chain/get_*` REST surface, or on `get_creator` / `get_created_accounts`.

**Cause:** the `release/3.6` branch only ships `/v2/*` endpoints fully. `/v1/chain/*` was never wired for Pulse. Specific v2 endpoints have null-handling bugs — we have a PR for `prev_block` null-guard merged.

**Fix:**

- For legacy `/v1/chain/*` clients, front Hyperion with the `pulsevm-rest-compat` REST→JSON-RPC shim (in `rest-compat/`).
- For `get_created_accounts` 500s, check `wiki/hyperion-3.6-test-report.md` for the patch status. If not yet fixed, fall back to `pulsevm.getAccount` directly.

## Validator added to P-Chain but not building blocks

**Symptom:** `addPermissionlessValidator` confirmed; node is in `platform.getCurrentValidators`; chain config has `producer_name`; but you never sign a block.

**Diagnostics:**

1. `kill -TERM` and restart metalgo — sometimes the producer plugin starts in a bad state if config was edited mid-run.
2. Check the per-chain log for "producer not enabled" — means the chain config JSON is malformed (most often a missing comma or wrong filename — must be `<blockchainID>.json` exactly).
3. Confirm the BLS key in your staker matches what you registered with `addPermissionlessValidator`.
4. With 6 validators expect ~17% of blocks; over a 5-minute window if you've signed zero, something's wrong. Over a 1-minute window, just rotation luck.

## Cross-chain transfer hung (METAL C → P)

**Symptom:** `avm.export` confirmed on C-Chain, but `platform.import` on P-Chain returns "no atomic UTXOs".

**Fix:** check the destination — atomic memory is per-direction. Make sure you ran `platform.importTx` and not `avm.importTx`. Also: the C-Chain export uses the EVM `0x...` address; the P-Chain import uses the bech32 `P-...` address — they're different keypairs, easy to mix up.

## TLS cert issuance failed via certbot HTTP-01

**Symptom:** certbot HTTP-01 challenge fails with 404 / connection refused.

**Cause:** Cloudflare proxying or nginx 80→443 redirect intercepting the challenge.

**Fix:** before requesting the cert, set the Cloudflare DNS record to **DNS-only** (grey cloud, not orange). After the cert lands, you can re-enable the proxy if you want the WAF benefits (though it's overkill for a JSON RPC).
