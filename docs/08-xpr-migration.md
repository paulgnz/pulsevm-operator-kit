# 08 — XPR Network → PulseVM migration

A component-by-component plan for moving XPR Network (Antelope/Leap) onto PulseVM running as a subnet on Metal Blockchain. This is **strategy, not a runbook** — expect scope to shift as we actually run the experiments described in [09-testing-guide.md](09-testing-guide.md).

## Goals (as we understand them)

- Preserve account identity (names and keys).
- Preserve token balances and important contract state (NFTs, oracle feeds, name service, etc.).
- Keep wallets (WebAuth, Anchor-style) working with minimal change.
- Keep block explorers / history APIs functional.
- Inherit PulseVM's sub-second finality and deterministic CPU.

## What "migration" actually means — 3 candidate models

### A. Genesis snapshot fork (cleanest)
Snapshot XPR Network at a height, encode every account / balance / contract state / permission as genesis records, boot PulseVM with that genesis. XPR Network stops producing, PulseVM takes over the chain id.

- **Pros:** single cutover, clean history break, no bridge risk.
- **Cons:** requires every contract to be ported & deployed at genesis; downtime during switchover; history before cutover lives only in old Hyperion.

### B. Bridge (most common in Avalanche-land)
XPR Network keeps running. A canonical token bridge (like Metal's existing `bridge-contracts`) ports balances on demand. New dapps deploy on PulseVM; old ones stay.

- **Pros:** zero downtime, gradual migration, reversible.
- **Cons:** two chains forever; split liquidity; bridge operator trust.

### C. Dual-production ("A-Chain upgrade" wording suggests this)
XPR Network validators run PulseVM *alongside* current Leap; a governance-coordinated switchover promotes PulseVM to canonical. The "A-Chain" in Metal's Superstack becomes the XPR Network.

- **Pros:** keeps the XPR brand / chain id continuity; validators already know the deal.
- **Cons:** large coordination problem; two codebases in flight; producer set reshaped by Snowman's different assumptions.

The public XPR roadmap language ("A-Chain becomes part of Metal Superstack") most closely matches **C**. We should confirm with Metallicus.

## Component-by-component plan

### 1. System contracts (`eosio.system`, `eosio.token`, `eosio.msig`, `eosio.wrap`)

**Port every one to `pulse-cdt-rust`.** `pulse-cdt-rust/contracts/` already has `pulse_system`, `pulse_token`, `pulse_msig`, `pulse_bios`. Use those as the scaffold; fold in XPR-specific actions:

- `pulse_system` — add XPR's staking model (if any diverges from eosio.system), resource delegation variants, producer voting shape.
- `pulse_token` — should Just Work for XPR core token; create with correct max supply on genesis.
- `pulse_msig` — straightforward port.
- XPR-specific contracts (`proton`, `eosio.proton`, `nft.proton`, escrow, pomelo, etc.) — port each.

**Blockers to watch:**
- **Secondary indices.** Anything that paginates by vote weight, producer rank, or resource usage needs a redesign (maintain a sorted auxiliary primary table, or wait for idx64/idx128 intrinsics).
- **Deferred transactions.** Anywhere XPR contracts use `send_deferred`, rearchitect to immediate inline actions or off-chain keepers.
- **`wait_weight`.** If any XPR permission uses delay-based auth, redesign.
- **ABI v1.2 features.** Downgrade variants to explicit struct-per-type until PulseVM catches up.

### 2. User / producer accounts

- Export full `(name, permissions, authorities, keys)` from XPR Network (nodeos snapshot or Hyperion).
- Encode into genesis records for model A/C, or leave on XPR side for model B.
- **Keys carry over unchanged** — PulseVM supports K1, R1, WA exactly like XPR.
- **Strip `wait_weight`** entries from authorities during import; warn any owners whose security model assumed delay.

### 3. Token balances

- For each `eosio.token` holder on XPR, emit a `pulse.token` row at genesis.
- For non-eosio-token SPL-style tokens (NFTs, custom tokens), port the owning contract and initialise tables.
- RAM accounting: since no RAM market, assign initial RAM = `max(current_usage, some_headroom)` for each account.

### 4. Resource allocations

- Current staking positions (CPU/NET delegations) need to map onto PulseVM's deterministic CPU. Pick a conversion: e.g. "1 XPR staked = N µs/window budget." Precise formula is a governance choice.
- REX positions, refund rows — port the raw tables so UIs still render.

### 5. Client wallets / dapps

- Existing K1/R1/WA signing flows work unchanged.
- **Replace `eosjs`/`@wharfkit/antelope` RPC calls with `pulsevm-js`.** Method renames (`v1.chain.get_info()` → `getInfo()`) are mechanical; type imports swap 1:1.
- Offer a `/v1/chain/*` REST shim (see [06-rpc-reference.md](06-rpc-reference.md)) to keep tools that haven't migrated alive.
- ABI decoding on the client is done by `pulsevm-js`'s Serializer — no server round-trip needed.

### 6. Block explorers / history API

- Deploy `pulsevm-hyperion` pointing at the new chain.
- **Patch the half-migrated CLI tools** in hyperion (`hyp-config`, `hyp-control`, `repair-cli`, `sync-modules`) to use `pulsevm-js` consistently — see [03-pulsevm-hyperion.md](03-pulsevm-hyperion.md) known issues.
- Point existing explorer UIs (proton.bloks, etc.) at the new Hyperion endpoint — v2 REST shape preserved.
- Historical data before cutover: keep old Hyperion read-only, or back-fill.

### 7. Validators / producers

- Producers need to run **MetalGo + PulseVM plugin**, not nodeos.
- Producer key concept shifts: MetalGo picks which validator builds each block via Snowman production window, not via rotating schedule. Producer onboarding is an Avalanche validator onboarding (stake METAL / whatever collateral Metal requires), layered with PulseVM node config.
- Test in Metal's Tahoe testnet before mainnet cutover.

### 8. Bridge-style integrations

If we go with model B or need intermediate state during A/C:
- Use Metal's existing `bridge-contracts` / `bridge-frontend` / `bridge-processes` org repos as the starting stack.
- Canonical token wrapper on each side; custodial or lock-and-mint semantics.

## Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Secondary-index intrinsics absent | High — most XPR contracts use them | Work with Metallicus to land `db_idx64_*` etc.; or redesign tables with sorted auxiliary structures |
| Deterministic CPU makes some contracts too expensive | Medium | Benchmark porte contracts; optimise tight loops or raise baselines |
| ABI v1.1 rollback breaks tooling | Low-Medium | Port contracts to v1.1-expressible shapes |
| Hyperion CLI paths broken | Low | Patch the remaining imports to `pulsevm-js` |
| No state-sync in PulseVM today | Medium | New validators cold-sync from genesis; feasible while chain is young |
| Chain ID decision (preserve XPR's vs new) | Strategy | Governance call; pick early |
| `pulsevm.*` RPC schema still changing (commit `87c0a4e` added `getTableByScope` Feb 2026) | Low | Pin SDK versions; follow releases |
| `pulse-cdt-rust` ABI generator panics on enums/unions | Low | Avoid those types until fixed; contribute patches |

## Phased execution

1. **Familiarity phase (now).** Stand up local devnet per [09-testing-guide.md](09-testing-guide.md). Exercise pulsevm-js. Deploy `pulse_token`. Verify transfers. Read Hyperion data. This is where we are.
2. **Port phase.** Port one XPR-specific contract end-to-end (start with something simple — a single-table NFT or escrow). Publish the diff, document type-by-type friction.
3. **Snapshot tooling.** Build a snapshot-to-genesis converter: nodeos/Hyperion dump → PulseVM genesis records.
4. **Testnet rehearsal.** Full XPR snapshot rehearsed on Tahoe testnet. Measure: does state load, do balances render, do wallets connect, does Hyperion index.
5. **Producer coordination.** Governance vote; validators onboarded on MetalGo.
6. **Cutover.** Model-specific switchover.

## Open strategic questions

These are for you / Metallicus, not technical blockers:

1. Model A / B / C — which does Metallicus actually intend? "A-Chain upgrade" language hints at C.
2. Chain ID — preserve XPR's, or mint a new one?
3. Producer set — stays the same, or reshapes with Avalanche-style staking?
4. Historical data — migrate, archive, or leave behind?
5. XPR token semantics — does the existing XPR token become the SYS of the new chain, or stay as its own asset?

See [11-open-questions.md](11-open-questions.md) for more.
