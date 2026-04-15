# 07 — Antelope vs PulseVM (delta table)

Single-page diff of everything that matters. Use this when reading an Antelope contract or client and wondering "does this work on PulseVM?"

## Consensus

| Aspect | Antelope (Leap/Spring) | PulseVM |
|---|---|---|
| Algorithm | DPoS / Savanna (BFT) | **Snowman** via MetalGo |
| Finality | ~120 s LIB (Leap) / sub-second (Savanna) | **~200 ms** |
| Block interval | 500 ms | 500 ms, **only when mempool non-empty** |
| Producer rotation | 21-BP rotating schedule | MetalGo picks the building node per window; no PBFT rotation |
| `schedule_version` header | increments on rotation | hardcoded 0 |
| Deferred transactions | supported (historical; later deprecated) | **not supported** |

## Resource metering

| Aspect | Antelope | PulseVM |
|---|---|---|
| CPU | wall-clock µs on the producer | **deterministic**: 50 µs baseline + WASM instruction count |
| NET | bytes | bytes (same) |
| RAM | KiB, tradeable Bancor market (`eosio.ram`) | KiB, **assigned at account creation** in current reference; no market |
| `buyram` / `sellram` | yes | not in reference system contract |

## Accounts / permissions

| Aspect | Antelope | PulseVM |
|---|---|---|
| Name encoding | 64-bit base32, 1–12 chars, `.1-5a-z` | **identical** |
| Hierarchy | `owner` → `active` → custom | **identical** |
| Authority threshold/keys/accounts | yes | yes |
| Authority `wait_weight` | yes | **removed** |
| Default keys | K1 (secp256k1) | K1, R1 (P-256), WA (WebAuthn) |
| Reserved system account | `eosio` | **`pulse`** |

## Smart contracts

| Aspect | Antelope | PulseVM |
|---|---|---|
| WASM target | custom eos-llvm, wasm32 | **wasm32-unknown-unknown with LLVM**, mimicking eos-llvm constraints |
| Primary toolkit | `eosio.cdt` (C++) | **`pulse-cdt-rust`** (`pulse-cdt` for TS/AssemblyScript also exists) |
| Runtime | eos-vm / WAVM | **Wasmer 7 + LLVM compiler backend** |
| ABI version supported | v1.2 | **v1.1** |
| `require_auth`, `has_auth` | yes | yes |
| `check_transaction_authorization` | yes | yes (recently added) |
| `send_inline` | yes | yes |
| `send_deferred` / `cancel_deferred` | yes (deprecated) | **not supported** |
| Crypto intrinsics | sha1/256/512, ripemd160, assert_*, recover_key | **same set** |
| DB — primary i64 index | yes | yes |
| DB — secondary indices (`idx64`/`idx128`/`idx256`/`idx_double`/`idx_ld`) | yes | **not yet** |
| KV tables (v1.2) | yes | no |

## Data types

| Type | Antelope | PulseVM |
|---|---|---|
| int8–int64 / uint8–uint64 | yes | yes |
| int128 / uint128 | yes | partial (codec TODOs) |
| int256 / uint256 | yes | yes |
| float32, float64, float128 | yes | **no — by design** |
| name, asset, symbol | yes | yes |
| checksum160/256/512 | yes | yes |
| public_key, signature | yes (K1, R1, WA) | yes (K1, R1, WA) |
| time_point, time_point_sec, block_timestamp | yes | yes |

## Client API

| Aspect | Antelope | PulseVM |
|---|---|---|
| Protocol | REST (`/v1/chain/*`, `/v1/history/*`) | **JSON-RPC 2.0** (`pulsevm.*`) |
| Primary SDK | eosjs, `@wharfkit/antelope`, `@wharfkit/session` | **pulsevm-js** (wharfkit-style) |
| State-history | SHiP WebSocket | SHiP-compatible WS |
| History API | Hyperion (v2) | **pulsevm-hyperion** (one-commit fork) |
| Key management | keosd / wallet libs | **pulsevm-keosd** crate |
| Signatures | SIG_K1/R1/WA | **identical** |
| Transaction signing digest | SHA256(chain_id ‖ packed_tx ‖ 32 zero bytes) | **identical** |

## Stack diagram differences

```
Antelope:   App → eosjs/wharfkit ──HTTP/REST──▶ nodeos ──SHiP──▶ Hyperion
PulseVM:    App → pulsevm-js    ──JSON-RPC──▶ MetalGo
                                              └───▶ pulsevm (plugin)
                                                    └──SHiP-compatible WS──▶ pulsevm-hyperion
```

## What Just Works

- Antelope wallets that let users sign arbitrary K1 signatures over a pre-built digest.
- ABI-encoding code that targets v1.1 structs.
- Hyperion clients that only hit `/v2/*` endpoints.
- Block explorers reading action / transaction shapes.
- Existing Antelope keys — same curves, same WIF/PVT formats.

## What needs adaptation

- Any client making raw `/v1/chain/*` REST calls — shim to JSON-RPC.
- Any contract using secondary indices — redesign tables.
- Any contract using `send_deferred` — rearchitect.
- Any contract relying on `wait_weight` — redesign permission flow.
- ABI v1.2-only features (variant, kv) — downgrade or wait.
- `eosio.*` references in tooling — retarget to `pulse.*`.
- CDT C++ source — port to `pulse-cdt-rust`.

## Compatibility ladder

1. **Wire-level (bytes):** ~95% compatible. Same tx/action/block structs with `wait_weight` difference.
2. **ABI level:** v1.1 intersection compatible; v1.2 extras fail.
3. **Host function level:** strong subset match for primary tables; missing for secondary.
4. **Source level (contracts):** requires full port (C++ → Rust).
5. **Client level:** JSON-RPC shim layer is the minimum viable adapter.
