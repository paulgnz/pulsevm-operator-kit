# Operator docs

Reference material for running a [PulseVM](https://github.com/MetalBlockchain/pulsevm) / A-Chain node — the runtime, the toolchain, and the BP-setup playbook. Compiled from direct inspection of the upstream Metallicus repos plus end-to-end operator experience on A-Chain Alpine.

## Reading order

| # | Page | What it covers |
|---|---|---|
| 00 | [Overview](00-overview.md) | One-page mental model: who, what, why, where it fits |
| 01 | [PulseVM core](01-pulsevm-core.md) | The Rust VM: crates, consensus, WASM, state, RPC |
| 02 | [pulse-cdt-rust](02-pulse-cdt-rust.md) | Rust contract SDK (analogue of eosio.cdt) |
| 03 | [pulsevm-hyperion](03-pulsevm-hyperion.md) | History indexer (fork of eosrio Hyperion) |
| 04 | [pulsevm-js](04-pulsevm-js.md) | TypeScript SDK for clients |
| 05 | [Protocol reference](05-protocol-reference.md) | Names, accounts, permissions, resources, blocks, intrinsics |
| 06 | [JSON-RPC reference](06-rpc-reference.md) | Every `pulsevm.*` endpoint, mapped to nodeos equivalents |
| 07 | [Antelope vs PulseVM](07-antelope-vs-pulsevm.md) | Side-by-side delta table |
| 08 | [XPR → PulseVM migration](08-xpr-migration.md) | Strategy, risks, component-by-component plan |
| 09 | [Testing guide](09-testing-guide.md) | Spin up a local devnet; exercise each component |
| 10 | [Glossary](10-glossary.md) | Quick terms |
| 11 | [Open questions](11-open-questions.md) | What is still unverified or needs confirmation |
| 12 | [Pulse CLIs: canonical vs ts-fork](12-pulse-cli-canonical-vs-ts-fork.md) | When to use Glenn's `pulse` (Rust, ships with VM) vs `pulse-cli-ts` |

## BP setup playbook

The end-to-end operator flow lives in [`bp-setup/`](bp-setup/). Start at [`bp-setup/README.md`](bp-setup/README.md) and follow the numbered pages.

## Other reference

- [`edge-cases.md`](edge-cases.md) — issues operators have hit, with verified fixes (Chainbase dirty flag, rpcchainvm version mismatch, Snowman quorum on small subnets, etc.)
- [`pulse-abi.json`](pulse-abi.json) — full canonical decode of the deployed `pulse` system contract ABI on A-Chain Alpine

## How this repo is meant to be used

Most operators won't read these top-to-bottom — they'll either:

1. Run [`scripts/bootstrap.sh`](../scripts/bootstrap.sh) → follow the wizard → end up at a working node, then read `bp-setup/06-join-a-chain-alpine.md` and onwards as needed.
2. Hit a specific problem → search `edge-cases.md` for it, then drill into the relevant reference page.

The Claude Code agent skill at [`.claude/skills/pulse-bp-ops/`](../.claude/skills/pulse-bp-ops/) packages the most-used playbooks with routing logic so other operators using Claude Code can get instant guidance without re-explaining the stack.
