# 00 — Overview

## What is PulseVM?

A **Rust-based Antelope-compatible virtual machine** that runs as a plugin binary loaded by **MetalGo** (Metallicus's fork of AvalancheGo). It speaks the Avalanche VM gRPC interface, participates in Snowman consensus, and internally implements an Antelope-like chain: accounts, permissions, WASM smart contracts, multi-index tables, ABI-encoded actions.

Think of it as: "`nodeos` rewritten in Rust as an Avalanche subnet VM, with opinionated protocol changes."

Source: [`pulsevm/README.md`](../pulsevm/README.md), [`pulsevm/PROTOCOL.md`](../pulsevm/PROTOCOL.md).

## Who built it?

- **Glenn Marien** — Co-founder and CTO of Metallicus since 2017, based in Belgium. GitHub handle is `MlennGarien` (the pulsevm repo path embedded in the README is `/Users/glennmarien/Documents/MetalBlockchain/pulsevm/` — confirms authorship). Primary committer across the PulseVM repos.
- **Metallicus** — US fintech, founded 2016 by Marshall Hayner (CEO) and Glenn Marien. Product line: Metal Pay, Metal X, WebAuth, Metal Blockchain, XPR Network (formerly Proton).
- First public PulseVM mention: **Metallicus Q3 2025 report** — *"internal testing continues for PulseVM, our high-performance virtual machine purpose-built for banking."*

## Where does it fit in the stack?

```
┌──────────────────────────────────────────────────────────┐
│  Apps / wallets  (Metal X, WebAuth, custom dapps)        │
└─────────────┬────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────┐
│  pulsevm-js  (TS SDK — wharfkit-compatible types)        │
└─────────────┬────────────────────────────────────────────┘
              │ JSON-RPC 2.0  (pulsevm.*)
              ▼
┌──────────────────────────────────────────────────────────┐
│  MetalGo node   ──── plugin load ────▶   pulsevm binary  │
│  (AvalancheGo fork, Go)               (Rust + FFI→C++)   │
│                                                          │
│  - Snowman consensus                  - chain state      │
│  - P/X/C/A chains                     - WASM runtime     │
│  - Subnet plugin mgmt                 - action dispatch  │
│                                       - chainbase DB     │
└───────────────────────────┬──────────────────────────────┘
                            │  state-history / WS
                            ▼
                 ┌──────────────────────────────┐
                 │ pulsevm-hyperion  (Node/TS)  │
                 │ ES + Mongo + Rabbit + Redis  │
                 │ → v1/v2 history REST API     │
                 └──────────────────────────────┘

         ┌──────────────────────────────┐
         │  pulse-cdt-rust              │
         │  Rust → wasm32 → setcode     │
         └──────────────────────────────┘
```

## Why not just use Antelope/Leap/Spring directly?

The README and PROTOCOL.md name two "notable changes":

### 1. Objective CPU metering
- **EOS/Antelope:** CPU is billed by wall-clock time of the producer that executed it. This is subjective — a slow producer over-charges; a colluding producer can grief accounts.
- **PulseVM:** Every action carries a fixed **50 µs baseline**, plus **per-WASM-instruction metering** via Wasmer's `wasmer-middlewares::Metering`. Billing is deterministic across producers.

### 2. Instant finality
- **EOS/Antelope:** Finality ~120 s (45-block LIB rule).
- **PulseVM:** 500 ms mempool tick → ~200 ms Snowman consensus acceptance. Blocks are only produced when the mempool is non-empty.

Other simplifications visible in the code:
- **No deferred transactions** (PROTOCOL.md:52 "we don't intend to support deferred transactions"); `wait_weight` removed from authority struct.
- **No floating-point types** by design (PROTOCOL.md:80) — aligns with EVM/financial norms.
- **No RAM market / buyram** in the current reference system contract (assigned at creation, not traded).
- **JSON-RPC 2.0** instead of `/v1/chain/*` REST (clients must adapt).

## Relationship to XPR Network

Metallicus is the core steward of XPR Network (formerly Proton), which today runs on Antelope/Leap.

**XPR Network 2026 roadmap** (https://xprnetwork.org/blog/xpr-network-roadmap-update-2025) talks about the **"A-Chain upgrade"** — integrating XPR Network into the Metal Blockchain Superstack. The roadmap does **not** use the name "PulseVM" in the published text, but:

- PulseVM's own README positions it directly against "EOS / Leap / Spring" (the Antelope lineage XPR Network runs on);
- Metallicus Q3 2025 confirms PulseVM is in internal testing;
- Third-party coverage of A-Chain describes it as "a new virtual machine for lightning-fast payments."

Conclusion: **PulseVM is almost certainly the A-Chain implementation**, but that identity is strongly inferred, not stated in a single first-party sentence we could find. See [11-open-questions.md](11-open-questions.md).

## Timeline

| Date | Event |
|---|---|
| 2022-10-18 | Metal Blockchain mainnet live |
| 2022-10-07 | First Antelope-on-Metal attempt (`antelopevm`, Go) |
| 2024-03-18 | `leapvm` created (short-lived Leap-based attempt) |
| **2024-11-01** | **`pulsevm` repo created — the Rust rewrite begins** |
| 2025-02-10 | `pulse-cdt` (TS/AssemblyScript CDK) |
| 2025-03-05 | `pulsevm-js` SDK |
| 2025-04-01 | `pulse-cdt-rust` — Rust CDK supersedes TS one for production contracts |
| 2025-08-27 | `pulsevm-hyperion` fork created |
| Q3 2025 | First public acknowledgement in Metallicus quarterly report |
| 2026-04-09 | Most recent commit to `pulsevm` main (release flow, install script, `getTableByScope` RPC) |

## Related repos on the Metal Blockchain org

Complete list on [07-antelope-vs-pulsevm.md](07-antelope-vs-pulsevm.md) for context, but the PulseVM "stack" is just these five:

- `pulsevm` — the VM (Rust)
- `pulse-cdt-rust` — Rust contract SDK (current)
- `pulse-cdt` — TS/AssemblyScript contract SDK (older, may be deprecated in favour of Rust)
- `pulsevm-js` — TS client SDK
- `pulsevm-hyperion` — history indexer

Superseded predecessors: `antelopevm` (Go), `antelopevm-cpp` (empty), `leapvm`, `leapsdk`, `leap`.
