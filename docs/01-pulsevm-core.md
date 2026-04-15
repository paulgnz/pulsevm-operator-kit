# 01 — PulseVM core (`pulsevm/`)

The VM itself. Rust workspace with 18 crates under `crates/` plus a C++ Chainbase library linked in via FFI.

## Workspace layout

| Crate | Responsibility | nodeos analogue |
|---|---|---|
| `pulse` (binary) | Entry point: gRPC server, RPC service, state-history WS | `nodeos` binary |
| `pulsevm_core` | Controller, apply_context, WASM runtime, auth, ABI, resource mgmt | `eosio::chain` library + chainbase glue |
| `pulsevm_ffi` | C++ bridge for chainbase DB, libfc crypto, object types | chainbase + libfc |
| `pulsevm_grpc` | Protobuf defs for the Avalanche VM interface and HTTP handlers | N/A (Avalanche) |
| `pulsevm_wasm_validation` | WASM module validation | `wasm_interface` validator |
| `pulsevm_crypto` | SHA2, merkle, digest, bytes utilities | `fc::crypto` |
| `pulsevm_name` | 64-bit base32 Antelope-compatible name type | `eosio::name` |
| `pulsevm_serialization` | Binary codec (`Read` / `Write` traits + derives) | `fc::datastream` |
| `pulsevm_time` | Block timestamps, time_point | `eosio::time_point_sec` |
| `pulsevm_billable_size` | Resource-billing size calculations | chain_config billables |
| `pulsevm_constants` | Block interval (500 ms), resource window constants | `chain_config` constants |
| `pulsevm_error` | `ChainError` enum | `eosio::chain_exception` |
| `pulsevm_proc_macros` | Derive macros (`Read`, `Write`, `NumBytes`) | code-gen |
| `pulsevm_keosd` / `pulsevm_keosd_client` | Key management daemon | `keosd` |
| `pulsevm_api_client` | HTTP client library | `cleos` / eosjs |

The core is `pulsevm_core::chain` — 75 `.rs` files. Module tree roughly mirrors `eosio::chain`:

```
chain/
├── controller.rs            (~1100 LoC, orchestrates tx exec + block build)
├── apply_context.rs         (~690 LoC, per-action exec context)
├── authorization_manager.rs (~479 LoC, permission graph validation)
├── wasm_runtime.rs          (Wasmer 7 + LLVM backend, instruction metering)
├── webassembly/             (host intrinsics by category)
├── transaction/             (Transaction, SignedTransaction, PackedTransaction, Action, ActionTrace)
├── block/                   (BlockHeader, SignedBlock)
├── account/                 (Account, AccountMetadata, CodeObject)
├── abi/                     (~3450 LoC, schema + serializer)
├── resource/                (resource limits state machine)
└── pulse_contract/          (native action handlers on the `pulse` account: newaccount, setcode, setabi, updateauth, …)
```

## Consensus boundary (gRPC)

PulseVM is not a standalone daemon — it is a **child process of MetalGo**. On startup, `pulse/src/main.rs`:

1. Reads `AVALANCHE_VM_RUNTIME_ENGINE_ADDR` (env var set by MetalGo).
2. Dials that gRPC endpoint and sends `InitializeRequest` (protocol version + listen address).
3. Implements the `vm_server::Vm` gRPC service: `Initialize`, `ParseBlock`, `BuildBlock`, `GetBlock`, `SetPreference`, `BlockVerify`, `BlockAccept`, plus the state-sync `StateSyncableVM` methods.

MetalGo drives block production: when the mempool is non-empty, it asks the configured producer to build a block via `BuildBlock`. The block is then gossiped and **Snowman** reaches acceptance in ~200 ms, after which MetalGo calls `BlockAccept` and PulseVM commits the state delta to chainbase.

Consequences worth internalising:

- There is no producer schedule in the Antelope sense (no 21-BP rotation, no schedule version bump). `schedule_version` is hardcoded to 0 in `block.rs`.
- Finality is **outside** PulseVM — it is whatever Snowman decides.
- "Producer" in PulseVM context means "which node assembled this particular block," which is the node MetalGo picked based on its production window.

## WASM runtime

- **Engine:** `wasmer` 7.0.1 with the **LLVM compiler backend** (`Cargo.toml` pins `wasmer-compiler-llvm` and `wasmer-middlewares`).
- **Why LLVM:** ahead-of-time compile + deterministic metering middleware. (This is why LLVM 18 is a hard system dependency per README.)
- **Metering:** `wasmer-middlewares::Metering` counts instructions → objective CPU.
- **Host bindings** live under `crates/pulsevm_core/src/chain/webassembly/`:
  - `db_*.rs` — primary i64 index ops (store/update/remove/find/next/previous/end/lowerbound/upperbound); secondary indices not yet exposed.
  - `action.rs` — `action_data_size`, `read_action_data`, `current_receiver`, `send_inline`, `require_recipient`, `set_action_return_value`.
  - `authorization.rs` — `require_auth`, `require_auth2`, `has_auth`, `check_transaction_authorization` (added in commit `0f261e1`).
  - `crypto.rs` — `sha256`, `sha512`, `assert_sha256`, `assert_sha512`.
  - `system.rs` — `pulse_assert`, `pulse_exit`, `is_account`, `get_account`, `current_time`, `is_privileged`, `set_privileged`.
  - `privileged.rs` — `set_resource_limits`, `get_resource_limits`.
  - `memory.rs` — `memmove`.

Host function names and semantics match eosio.cdt 1:1 wherever they exist. See [05-protocol-reference.md](05-protocol-reference.md) for the full table.

## State & storage

State sits in **Chainbase** — the same C++ `boost::multi_index_container` library Antelope uses. PulseVM does not reimplement it in Rust; instead `pulsevm_ffi` links against `pulsevm_ffi/pulsevm/libraries/chainbase/` via `cxx` 1.0. This is a pragmatic choice: chainbase already handles nested undo revisions (required for atomic tx rollback), is battle-tested, and is ABI-stable.

Object types exposed through FFI:

- `AccountObject` — name, creation time, ABI blob
- `AccountMetadataObject` — privileged flag, last_code_update
- `CodeObject` — WASM bytecode keyed by code_hash
- `PermissionObject` — authority per (account, perm_name)
- `PermissionLinkObject` — action → permission routing
- `TableObject` — (code, scope, table) metadata, payer
- `KeyValueObject` — table rows (primary key → serialised data)

Merkle commitments: block header holds `transaction_mroot` and `action_mroot`, computed via `pulsevm_crypto::merkle()`.

State sync: the `StateSyncableVM` interface is implemented (proto defs in `pulsevm_grpc/proto/vm/vm.proto:61-73`) but likely returns `state_sync_enabled = false` today (see [11-open-questions.md](11-open-questions.md)).

## Reference contracts

`pulsevm/reference_contracts/` ships **pre-built WASM + ABI** for:

- `pulse_system.wasm` (~80 KB) — staking, resource allocation, producer voting
- `pulse_token.wasm` (~15 KB) — SYS token
- `pulse_bios.wasm` (~14 KB) — genesis bootstrap
- `test_api_db.wasm`, `endless_loop.wasm` — test contracts
- `pulse_token.abi` — JSON ABI

These are compiled from the Rust sources that live in `pulse-cdt-rust/contracts/`. No C++ source is present.

## Native system actions (on the `pulse` account)

`pulse_contract/` inside `pulsevm_core` implements these as **native** handlers (not WASM) — identical in shape to Antelope's native actions on `eosio`. They are actions on the `pulse` account, not separate contracts:

- `pulse@newaccount`
- `pulse@setcode`
- `pulse@setabi`
- `pulse@updateauth`
- `pulse@deleteauth`
- `pulse@linkauth`
- `pulse@unlinkauth`

(There is **no** `pulse.system` or `pulse.newaccount` account. "pulse.system" as a separate account does not exist on-chain; it's only used loosely as a label for the WASM system contract code that gets deployed at the `pulse` account itself.)

## JSON-RPC service

Defined in `pulse/src/chain/service.rs` using `jsonrpsee`. Full list with request/response in [06-rpc-reference.md](06-rpc-reference.md). Exposed methods:

`pulsevm.issueTx`, `pulsevm.getInfo`, `pulsevm.getAccount`, `pulsevm.getBlock`, `pulsevm.getBlockInfo`, `pulsevm.getABI`, `pulsevm.getRawABI`, `pulsevm.getCode`, `pulsevm.getCodeHash`, `pulsevm.getRequiredKeys`, `pulsevm.getTableRows`, `pulsevm.getTableByScope`, `pulsevm.getCurrencyBalance`, `pulsevm.getCurrencyStats`, `pulsevm.getProducerSchedule`.

Also: WebSocket state-history endpoint on `WS_BIND` (default `0.0.0.0:9090`) streaming Hyperion-compatible deltas.

## Build & run

```bash
# Build
cargo build --release     # produces target/release/pulse (the VM plugin)

# Rename to the VM ID metalgo expects
cp target/release/pulse build/rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs

# Start metal-network-runner (see README.md in repo root)
metal-network-runner server --log-level info --port=":8080" --grpc-gateway-port=":8081"
metal-network-runner control start \
    --endpoint="0.0.0.0:8080" \
    --number-of-nodes=5 \
    --metalgo-path ${METALGO_EXEC_PATH} \
    --plugin-dir $(pwd)/build \
    --blockchain-specs '[{"vm_name":"pulsevm","genesis":"/abs/path/to/genesis.json"}]'
```

Runtime env vars:
- `AVALANCHE_VM_RUNTIME_ENGINE_ADDR` — gRPC endpoint back to MetalGo (required, set by parent)
- `WS_BIND` — state-history WS address (default `0.0.0.0:9090`)
- `RUST_LOG` — log level

System deps: Ubuntu 22.04+, zstd, LLVM 18, libffi. Mac supported for dev only (needs `brew install zstd llvm@18 libffi`).

## Boot / genesis

1. MetalGo hands PulseVM the genesis bytes via `InitializeRequest`.
2. `controller.rs` parses genesis JSON (initial timestamp, initial key, initial config).
3. `database::initialize_database()` (FFI) creates chainbase indices, creates the `pulse` system account, deploys `pulse_system.wasm` + `pulse_token.wasm` + `pulse_bios.wasm`.
4. Initial resource limits and global properties are set.
5. Chain ID = SHA256 of genesis bytes.

The recent commit `7d2d1f9` "fix boot flow when having existing db" indicates the DB-already-exists code path was broken until very recently — worth scrutinising if we pick up that branch for testing.

## Known limitations (from TODO/FIXME scan)

- `abi/serializer.rs` — `int128` / `uint128` / `float128` codec paths are stubbed or incomplete.
- `block/block.rs:62-79` — time-skew tolerance, previous-block-ID validation, mroot validation are TODOs.
- `apply_context.rs` — recursion depth hardcoded to 1024; CPU return value is a placeholder.
- `state_history/log.rs` — SHiP "magic number" is a placeholder (not yet real).
- `webassembly/privileged.rs` — RAM enforcement validation TODO.
- No secondary index host functions (`db_idx64_*`, `db_idx128_*`, `db_idx_double_*`). **This is a significant gap for XPR migration** because many XPR system contracts rely on secondary indices.
- Single-producer-per-node model; no rotating schedule.
- No transaction extensions handling.
- State sync likely reports disabled.

## Commits worth knowing about

From git log (most recent first):

- `7d2d1f9` fix boot flow when having existing db
- `56a0560` add install script for ease of use
- `48de538` only run release on tags
- `09e6a8e` add release flow to github
- `87c0a4e` add pulsevm.getTableByScope  ← RPC surface still growing
