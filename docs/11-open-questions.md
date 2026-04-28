# 11 — Open questions

Things that are either **unverified** from public sources, **incomplete** in the code, or **strategic decisions** we need input from Metallicus/XPR governance on. Consolidated here so we don't lose track.

## Unverified claims

1. **"PulseVM is the A-Chain upgrade."** Strongly inferred from (a) PulseVM README framing, (b) Metallicus Q3 2025 report confirming internal testing, (c) third-party coverage calling A-Chain "a new virtual machine." Not stated first-party in a single sentence we could find.
2. **Glenn Marien ↔ dogechain.info.** Widely cited online but not on his professional profiles. Plausible-but-partially-verified.
3. **Q2 2025 Metallicus report** could not be retrieved via WebFetch (binary PDF).
4. **No governance thread** on XPR forums specifically about migrating to PulseVM was found in search.

## Technical gaps in the code we'd want to confirm

From TODO/FIXME scanning (pulsevm core):

1. `abi/serializer.rs` — int128/uint128/float128 codec stubs. Is this done? (We said no floats are planned — confirm.)
2. `block/block.rs` — time-skew tolerance, previous-block-id validation, mroot validation are all TODOs. Are they implemented anywhere else? Any security implication?
3. `apply_context.rs` — recursion depth hardcoded 1024. Is this intentional forever, or config-bound later?
4. `state_history/log.rs` — SHiP "magic number" placeholder. Does Hyperion's indexer tolerate this?
5. ~~**No secondary-index intrinsics.** Is this coming? If yes, what roadmap / milestone?~~ **Answered (2026-04-24):** Glenn confirmed v0.3 will ship the `db_idx*` family (`db_idx64`, `db_idx128`, `db_idx_double`, `db_idx_long_double`). Required for any contract using Antelope multi-index with secondary keys — i.e. ~all real dapps (token registries, marketplaces, vote/stake tables). v0.2.x can't port these; v0.3 unlocks them.
6. **State sync reports disabled?** Need to read `is_state_sync_enabled` impl to confirm; if disabled, cold-sync time for mainnet-scale state would be painful.
7. **Single producer per node model.** Is there a planned multi-producer/failover story?

## SDK / tooling

1. `pulse-cdt-rust` derive macros `unimplemented!()` on enums/unions — any plan to support?
2. ABI v1.2 (variant, kv tables) — on the roadmap?
3. `pulsevm-hyperion` CLI tooling (`hyp-config`, `hyp-control`, `repair-cli`, `sync-modules`) is half-migrated. Has this been noticed? Should we upstream a patch?
4. `pulsevm-js` README example references removed classes (`BaseTransaction`) — docs need a refresh.
5. `pulse-cdt` (the TypeScript/AssemblyScript version) — deprecated in favour of Rust, or kept as an alternative?

## Roadmap signals (Metallicus, 2026-04-24)

From conversation with Glenn after the v0.2.4 release:

1. **v0.3 will ship `db_idx*` secondary-index intrinsics.** Required for any contract using Antelope multi-index with secondary keys. Until v0.3, dapp porting is gated to single-primary-key contracts only.
2. **WebAuth deep-linking integration in progress.** Metallicus is working with the WebAuth team to support deep links from the block explorer to the WebAuth wallet for tx signing. This is the missing user-facing signer for Pulse — once shipped, real dapps can have real users sign txs without each dapp rolling its own signer UX.
3. **First dapp deploys** likely follow once (1) and (2) land.

Order of unblocks for "first real dapp running on A-Chain with real users":
> v0.2.x ✅ → v0.3 (db_idx) → WebAuth deep linking → port first dapps → public users sign

## Strategic / governance

These are questions for you (or Glenn / Metallicus):

1. **Migration model.** Snapshot fork vs bridge vs dual-production? ([08-xpr-migration.md](08-xpr-migration.md))
2. **Chain ID continuity.** Preserve XPR Network's chain id, or mint a new one?
3. **Producer set.** Keep current XPR BPs, or reshape around Avalanche-style validation + Metal stake?
4. **Token semantics.** Does XPR token become SYS on PulseVM, or does SYS stay separate?
5. **Resource formula.** How do XPR staking positions convert to PulseVM's deterministic CPU budget?
6. **Historical data.** Backfill into new Hyperion, keep old Hyperion read-only, or drop?
7. **Cutover downtime budget.** Any user-facing SLA?
8. **`eosio.*` → `pulse.*` naming.** Keep `eosio` aliases (reserved for back-compat), or rename wholesale?
9. **XPR-specific contracts** (proton.wrap, free accounts, oracles, pomelo) — which are port-priority, which can wait?
10. **Public roadmap coordination.** When does this migration go from internal testing to public spec?

## Things we should do ourselves to close gaps

1. **Stand up the local devnet** per [09-testing-guide.md](09-testing-guide.md) and smoke-test every RPC.
2. **Port one small XPR contract** to `pulse-cdt-rust` end-to-end; document friction.
3. **Prototype a snapshot → genesis converter** for a small slice of XPR state.
4. **Prototype a `/v1/chain/*` REST → JSON-RPC shim** so legacy tooling keeps working.
5. **Fix the half-migrated Hyperion CLI** and either keep the patch local or upstream it.
6. **Measure deterministic CPU** by running the same contract on two differently-specced machines and comparing billed CPU.
7. **Test secondary-index workarounds** — pick one XPR contract that uses `idx64`, redesign with parallel primary tables, confirm feasibility.
8. **Reach out to Glenn / Metallicus** directly to confirm intent, timeline, and missing features (especially secondary indices).

## Sources to re-scan later

- https://xprnetwork.org/blog — new posts may explicitly mention PulseVM
- https://www.metallicus.com/blog — Q4 2025 and Q1 2026 reports
- https://github.com/MetalBlockchain/pulsevm/releases — once release flow produces tagged builds
- XPR governance forum / Discord — for producer-side coordination
- `git log --author="Glenn"` across all four repos — commit trail over time
