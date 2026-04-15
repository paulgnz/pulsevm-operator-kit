# 03 — Keys & signing

There are **two separate key universes** in a PulseVM stack. Keep them distinct or you'll hate yourself.

## The two kinds of keys

### A. MetalGo staking key (node identity for Snowman consensus)

- Generated automatically by `metalgo` on first boot, stored in `~/.metalgo/staking/`:
  - `staker.key` — the private key (PEM-encoded, RSA 4096 or EC P-256 depending on version)
  - `staker.crt` — matching x509 certificate
  - `signer.key` — BLS key for aggregate signature voting (newer metalgo versions)
- Identifies your node to the Avalanche/Metal network. Your **NodeID** (`NodeID-xxx...`) is derived from `staker.crt`.
- If lost, your node effectively becomes a new node — you lose validator standing and any stake attached to the old NodeID.
- **Back this up**, encrypted, off-box, immediately after first boot.

### B. Antelope block-signing keys (the XPR-style keys you already have)

- Your BP signing key. `PUB_K1_...` public, `PVT_K1_...` or WIF private.
- Same format as XPR Network — so your existing HSM flow and air-gapped signer work unchanged.
- Lives in `pulse-keosd` (Rust rewrite of keosd), or on a hardware signer that speaks the keosd WIF/PVT interface.
- This is the key that signs **actions** (transfers, contract calls, msig proposals). It does NOT vote on Snowman.

Treat them as independent assets with independent rotation schedules and independent incident response.

## `pulse-keosd` — the Rust key daemon

Rust rewrite of the classic `keosd`. Binary at `/opt/bin/pulse-keosd` (installed by bootstrap if the release asset exists). Stores keys encrypted, unlocks on demand, signs digests — same state machine as `keosd`.

Key workflows (mirroring Antelope flow you know):

```bash
# Start the daemon (foreground for dev)
pulse-keosd --http-server-address localhost:3030

# From another shell, via pulse-cli (or pulsevm-js equivalent):
pulse-cli wallet create -n default --to-console
pulse-cli wallet open -n default
pulse-cli wallet unlock -n default --password '...'
pulse-cli wallet import -n default --private-key PVT_K1_...

# Sign and push (schematic — exact CLI may differ; see pulse-cli --help)
pulse-cli push action pulse.token transfer '{"from":"protonnz","to":"alice","quantity":"1.0000 SYS","memo":""}' -p protonnz@active
```

Caveats from source inspection:
- `pulse-keosd` is a Rust binary, not a Node wallet. Treat state files (usually in `~/.pulse-keosd/`) as key material.
- Not yet feature-parity with upstream keosd — verify by hitting `--help`. If missing features matter, keep a wharfkit-style local signer in your toolkit for now.

## Signing primitives (bytes-level)

Wire format for signatures is **identical to Antelope**:

```
Signing digest = SHA256( chain_id || packed_transaction || 32 zero bytes )
```

Signature types and prefixes unchanged:

| Curve | Prefix | Format |
|---|---|---|
| secp256k1 | `SIG_K1_` | base58check, recoverable (r, s, recid), 65 bytes |
| P-256 | `SIG_R1_` | base58check, recoverable, 65 bytes |
| WebAuthn | `SIG_WA_` | base58check, device-attested, variable |

If your current XPR flow signs a digest and posts it, **the same exact bytes will verify on PulseVM** — assuming chain_id and packed_tx are constructed for the PulseVM chain.

## Hardware signer / HSM integration

Options that work today:

1. **Ledger app-eos** or equivalent — signs K1 digests. Works because the digest construction is identical. You just need a tx builder that uses PulseVM's chain_id.
2. **YubiHSM / AWS KMS / GCP KMS** — if you run a custom signer service for XPR today, point it at pulse-keosd's JSON-RPC interface or have it proxy signatures.
3. **Air-gapped machine + QR transport** — the digest-first signing workflow transfers cleanly. Build the tx on the online node, dump `chain_id + packed_tx`, carry across, sign, carry back.

Things that don't change between XPR and PulseVM for signers:
- K1 curve, low-s canonical requirement
- WIF / PVT_K1 format
- The digest algorithm

Things that DO change:
- Chain ID (different chain, different hash → different digest)
- No deferred tx support — your signer can drop delay_sec / max_cpu_usage_ms wait fields
- Authority struct has no `wait_weight` field — if your signer assembles `updateauth` payloads, drop that field

## Key rotation playbook

### MetalGo staking key
1. Stop metalgo on the replacement node.
2. Generate new `staker.key/staker.crt/signer.key` on the new box (let metalgo generate on first boot).
3. Register new NodeID with your stake on the P-Chain, or transition gradually.
4. Let the old node unstake / be removed from validator set.

### Antelope block-signing key
Same process you use today on XPR:
1. Propose an `updateauth` action (native, on `pulse`) via msig — `pulse@updateauth` signed for your BP account.
2. Get the existing threshold worth of signatures.
3. Execute. New key is active; old key revoked.

## Secrets hygiene

- Never paste `PVT_K1_...` or WIF strings into Slack/Discord/git.
- Store production keys in a secrets manager (1Password, Vault, AWS SM). The signing node reads them at startup via short-lived token.
- Don't co-locate the signing key with SSH access to the node. The SSH key unlocks root; the signing key should need a separate physical step.
- `pulse-keosd` wallet files are encrypted with a password. Password rotation is a separate rite from key rotation.

## What we haven't confirmed yet

- Whether `pulse-keosd` supports an HTTP API surface identical to keosd (wallet/sign/list_keys endpoints).
- Whether Ledger's eos/antelope app will recognise PulseVM's chain_id as a regular Antelope chain (it should — digest algorithm is unchanged).
- MSIG flow end-to-end on PulseVM — we'll validate this in the contract deploy walkthrough.

Document updates land in this file as we confirm or debunk each point.
