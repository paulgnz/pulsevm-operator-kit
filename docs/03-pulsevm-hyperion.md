# 03 — `pulsevm-hyperion` (history indexer)

A fork of **eosrio/hyperion-history-api 4.0.0-beta.3**. Provides the `/v2/history/*` and `/v2/state/*` REST APIs that block explorers, wallets, and dapps rely on.

## What this is

- **Node.js 22+ / TypeScript / ES modules**
- Ingests blocks from a PulseVM node via the state-history WebSocket
- Deserializes actions/deltas, pushes through RabbitMQ workers into Elasticsearch
- Serves Fastify-based REST API on top

## Upstream delta — this is a thin port

The PulseVM-specific work is **one commit**: `41223a0` "update hyperion for pulsevm" (2026-02-06, Glenn). **52 files, ~261 added / ~141 removed.**

Changes are **localized to the API-interaction layer**, not the deserialization or ingestion core. In practical terms:

| Before (upstream Hyperion) | After (pulsevm-hyperion) |
|---|---|
| `import { APIClient } from '@wharfkit/antelope'` | `import { PulseAPI } from '@metalblockchain/pulsevm-js'` |
| `api.v1.chain.get_info()` | `api.getInfo()` |
| `api.v1.chain.get_abi(acc)` | `api.getABI(acc)` |
| `api.v1.chain.get_producer_schedule()` | `api.getProducerSchedule()` |
| `api.call({path: "/v1/chain/get_account", params: {...}})` | `api.callRpc({methodName: "pulsevm.getAccount", params: {...}})` |
| System account regex: `^eosio[\.][a-z1-5]{1,6}` | `^pulse[\.][a-z1-5]{1,6}` |
| Table owner name `'eosio'` (fallback) | `'pulse'` |

The **SHIP (state-history plugin) WebSocket protocol itself is unchanged** — PulseVM's state-history WS speaks the same wire format as nodeos. `src/indexer/connections/state-history.ts` (247 lines) was not rewritten.

Deserialization still uses `@eosrio/node-abieos` for speed; type signatures in `deserializer.ts` swap `@wharfkit/antelope`-sourced types (`Serializer`, `ABI`, `Action`, `PackedTransaction`) for the `@metalblockchain/pulsevm-js` equivalents.

## What this implies

- **Indexer is minimally forked.** Almost all upstream Hyperion features should Just Work: `/v2/history/get_actions`, `/v2/state/get_tokens`, streaming via Socket.IO, repair tools, etc.
- **But** the migration is **incomplete**. Several CLI tools — `hyp-config.ts`, `hyp-control`, the `repair-cli/scan.ts`, `sync-modules/sync-*.ts` — were **not** updated from `@wharfkit/antelope` to `@metalblockchain/pulsevm-js`. Since the new `PulseAPI` has a completely different method surface (e.g. `callRpc` vs `call`, no `v1.chain.*` namespace), these tools will break when invoked against a PulseVM node.
- A `console.log(res)` + `prev_block` null-check at `src/indexer/workers/deserializer.ts:292-302` signals work-in-progress handling of PulseVM genesis or special blocks.

## Dependencies

From `package.json` (v4.0.0-beta.3):

- `@elastic/elasticsearch` 9.0.3 (ES 9)
- `@metalblockchain/pulsevm-js` ^0.0.49
- `@wharfkit/antelope` 1.1.1 (still present — used in CLI paths that weren't migrated)
- `@eosrio/node-abieos` 4.0.2 (native C++ codec, for speed)
- `@noble/hashes` ^1.7.1, `@noble/secp256k1` ^2.2.3
- `fastify` 5.4.0
- `amqplib` 0.10.8 (RabbitMQ)
- `mongodb` 6.17.0
- `ioredis` 5.6.1
- `socket.io` for streaming

## Configuration

- `references/connections.ref.json` and `references/config.ref.json` are templates.
- `hyp-config` CLI scaffolds per-chain `config/chains/{chain}.json` + global `config/connections.json`.
- Expected HTTP endpoint is a single URL (the PulseVM JSON-RPC endpoint), not an array like some Hyperion setups.
- SHIP endpoints still configured as an array of `{ label, url }` WebSocket entries.

## Running it

Stack required:
- Elasticsearch 9
- MongoDB
- RabbitMQ
- Redis
- A PulseVM node with state-history enabled (WS_BIND port)

Commands:

```bash
./hyp-config          # Interactive chain + connection setup
./run <chain>          # Start indexer + api under PM2
./hyp-control <chain>  # Runtime control (pause, resume, repair)
./stop <chain>         # Shutdown
```

`pm2/ecosystem.config.cjs` defines the process groups.

## API surface

All 88 v1/v2 route files are preserved. Endpoints you'll care about:

- `/v2/health` — liveness + indexing lag
- `/v2/history/get_actions` — main query endpoint (search by account, action name, block range, etc.)
- `/v2/history/get_transaction` — retrieve a tx and its traces
- `/v2/state/get_account` — proxies to `pulsevm.getAccount` now
- `/v2/state/get_tokens` — account token holdings
- `/v2/state/get_key_accounts` — which accounts a given pub key controls
- `/v2/state/get_producer_schedule`
- `/v1/chain/*` — compatibility layer

For XPR migration, this is significant: **existing XPR tooling that talks to Hyperion v2 can point at this fork without code changes**, provided the data shape stays compatible.

## Known issues / watchouts

1. **CLI tooling half-migrated** — any operational task that shells into `hyp-config`, `hyp-control`, or repair scripts is likely broken until those imports are swapped to `pulsevm-js`. Worth raising upstream or patching locally.
2. **`prev_block` null check** — genesis block or snapshot resume may hit edge cases.
3. **Upstream merges lag** — last merge of eosrio upstream was `8486825` (release/4.0); future bug fixes need manual rebases.
4. **Debug `console.log(res)`** in the deserializer is WIP noise.
5. **ES 9 is recent** — ensure cluster/plugin compatibility.

## Git log highlights

- `8e4af22` fix: update changelog and package description for clarity
- `8486825` Merge pull request #158 from eosrio/changelog-4.0.0-beta.3-absolutely-final
- `79000ec` cleanup
- `73d9ee0` Merge pull request #157 from eosrio/release/4.0
- `a4db3c2` chore: update dependencies in package.json
- `41223a0` update hyperion for pulsevm   ← the only PulseVM-specific change
