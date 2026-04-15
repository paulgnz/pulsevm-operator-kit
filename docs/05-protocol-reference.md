# 05 — Protocol reference

Canonical reference for PulseVM's on-chain protocol. Compiled from `pulsevm/PROTOCOL.md`, `pulsevm/genesis.json`, and source inspection.

## Accounts

- Name: 1–12 chars, charset `a-z 1-5 .`, dot cannot be the last char.
- Encoded as 64-bit integer (base32), identical to Antelope. Supports 1,152,921,504,606,846,974 distinct names.
- Examples: `glenn`, `proton.wrap`, `pulse.token`.
- Reserved: `pulse` is the system account (see [01-pulsevm-core.md](01-pulsevm-core.md)).

Account record fields (PROTOCOL.md:13-20):

| Field | Type | Description |
|---|---|---|
| `account_name` | name | the name |
| `privileged` | bool | privileged flag |
| `created` | uint64 | creation timestamp |
| `last_code_update` | uint64 | last setcode timestamp |

ABI is stored separately, at the `AccountObject` level.

## Permissions

Hierarchical named permissions per account. Every account has `owner` (root) and `active` (child of owner). Custom sub-permissions below `active` are common for dapps.

Permission row:

| Name | Type | Description |
|---|---|---|
| `perm_name` | name | named permission |
| `parent` | name | parent permission |
| `required_auth` | authority | the authority table |

## Authority

The authority struct used in every permission:

| Field | Type | Description |
|---|---|---|
| `threshold` | uint32 | satisfies when sum of matched weights ≥ threshold |
| `keys` | `[]key_weight` | public keys with weights |
| `accounts` | `[]permission_level_weight` | delegated permissions with weights |

**Gone compared to EOSIO:** `wait_weight` is **not present** — PulseVM does not support deferred transactions, so delay-based auth satisfaction is meaningless.

## Default token

Symbol: **`SYS`** (PROTOCOL.md:56). Used to pay for resources.

## Resource model

Three-axis, same shape as Antelope but measured differently:

| Resource | Unit | How it's charged |
|---|---|---|
| **RAM** | KiB | Data storage per account. Allocated at account creation in the current reference system; no buyram market in shipping reference contract. |
| **CPU** | "microseconds" (label) — actually **WASM instruction count + 50 baseline** | **Deterministic**: 50 baseline units per action + WASM instructions counted by Wasmer metering middleware. **NOT wall-clock time** despite the µs unit label inherited from Antelope. Block explorers may show "CPU time" / "µs" — that value is the instruction count, not real microseconds. Confirmed by Glenn 2026-04-15. |
| **NET** | bytes | Transaction bandwidth. |

> "In Pulse this metric will be determined based on the WASM instruction set and which host intrinsics were called." — PROTOCOL.md:65

## Blocks

- Target interval: **500 ms**
- Blocks are produced **only when the mempool has transactions** (no empty blocks).
- Finality: delegated to Snowman (~200 ms after block production).
- `schedule_version` is currently fixed at 0 (no rotating producer schedule).
- Block id = SHA256 of packed block with block number in first 4 big-endian bytes.

Block header fields (`chain/block/block.rs`):

```
timestamp: BlockTimestamp
producer:  Name
confirmed: u16
previous:  BlockId
transaction_mroot: Digest
action_mroot:      Digest
schedule_version:  u32    (always 0 today)
new_producers:     Option<...>  (unused today)
header_extensions: Vec<(u16, Vec<u8>)>
```

## Integer types supported in ABI

| Signed | Unsigned |
|---|---|
| int8 | uint8 |
| int16 | uint16 |
| int32 | uint32 |
| int64 | uint64 |
| int128 (partial; TODO in serializer) | uint128 (partial) |
| int256 | uint256 |

**No floating-point types.** This is a design decision for financial correctness.

## Names encoding (reminder)

Exactly Antelope: 5 bits per char, 64-bit integer packed big-endian. `.` maps to 0, `1..5` to 1..5, `a..z` to 6..31. Char 13 (only 4 bits) restricts the last char's range.

## Native system actions (on the `pulse` account)

All implemented natively (not WASM) in `crates/pulsevm_core/src/chain/pulse_contract/`. They are actions **on** the `pulse` account — **not** separate `pulse.<name>` accounts (there is no such account as `pulse.newaccount` / `pulse.system` / etc.).

Canonical reference form: `pulse@<action>`.

| Action | Purpose |
|---|---|
| `pulse@newaccount` | Create account with `owner` + `active` authorities |
| `pulse@setcode` | Deploy / replace / remove WASM on an account |
| `pulse@setabi` | Deploy / replace / remove ABI on an account |
| `pulse@updateauth` | Update a named permission's authority |
| `pulse@deleteauth` | Delete a non-`owner`, non-`active` permission |
| `pulse@linkauth` | Route a specific `(code, action)` to a permission |
| `pulse@unlinkauth` | Remove such a route |

Semantics follow Antelope's native `eosio@*` handlers 1:1 except for the absence of `wait_weight` in supplied authorities.

Higher-level system actions (`regproducer`, `voteproducer`, `buyram`, `delegatebw`, etc.) are **not** native — they are served by the WASM system contract deployed at the `pulse` account (code hash `a351dd76…` on A-Chain Alpine as of 2026-04-15). Call them as `pulse@regproducer`, `pulse@voteproducer`, etc.

## Smart contracts

- WebAssembly (wasm32-unknown-unknown).
- Deployed via `pulse@setcode` / `pulse@setabi` (the native actions above).
- Rust is the current production language (`pulse-cdt-rust`). TypeScript/AssemblyScript via `pulse-cdt` also exists but may be deprecated.
- Contracts are `#![no_std]`, small stack (8 KiB), strict WASM validation (stack-first, separated data segments).

## Host intrinsics (what contracts can call)

See [02-pulse-cdt-rust.md](02-pulse-cdt-rust.md) for the Rust-side bindings. PROTOCOL.md:108-132 lists the canonical set. Grouped:

### Accounts / auth / action
- `is_account(name)` → bool
- `get_account(name)` → struct bytes
- `get_account_creation_time(name)` → uint64
- `require_auth(name)`, `require_auth2(name, perm)`
- `has_auth(name)` → bool
- `require_recipient(name)`
- `check_transaction_authorization(…)`   ← added 2026 in commit `0f261e1`
- `current_receiver()` → name
- `get_sender()` → name
- `action_data_size()`, `read_action_data(buf, len)`
- `send_inline(data, len)`

### System
- `current_time()` → uint64 (microseconds)
- `is_privileged(name)` → bool
- `set_privileged(name, bool)`
- `pulse_assert(cond, msg)`
- `pulse_exit(code)`

### Privileged (only callable from privileged accounts)
- `set_resource_limits(account, ram, net, cpu)`
- `get_resource_limits(account) -> (ram, net, cpu)`

### Crypto
- `sha1`, `sha256`, `sha512`, `ripemd160`, and their `assert_*` variants
- `recover_key(digest, sig)` → public_key
- `assert_recover_key(digest, sig, expected)`

### Database (primary i64 index only at this time)
- `db_store_i64(scope, table, payer, id, data, len)` → iterator
- `db_update_i64(it, payer, data, len)`
- `db_remove_i64(it)`
- `db_get_i64(it, buf, len)`
- `db_find_i64(code, scope, table, id)` → iterator
- `db_next_i64(it, &out_primary)` → iterator
- `db_previous_i64(it, &out_primary)` → iterator
- `db_end_i64(code, scope, table)` → iterator
- `db_lowerbound_i64(code, scope, table, id)` → iterator
- `db_upperbound_i64(code, scope, table, id)` → iterator

**Absent** compared to EOSIO: `db_idx64_*`, `db_idx128_*`, `db_idx256_*`, `db_idx_double_*`, `db_idx_long_double_*` — any form of secondary index. This is the **largest protocol-level gap** for porting XPR contracts.

Also absent: transaction-sending intrinsics for deferred txs (`send_deferred`, `cancel_deferred`) — intentional.

## Wire compatibility with Antelope

- **Names:** identical.
- **Actions, Transactions, Blocks:** same shape, same serialization, same digest algorithm. ABI-encoded action data is byte-identical to Antelope for types both sides support.
- **Signatures:** identical format (`SIG_K1_…`, `SIG_R1_…`, `SIG_WA_…`), same secp256k1/P-256 canonical form.
- **ABI version:** PulseVM reads/writes `eosio::abi/1.1`. v1.2 features (variant, kv) are not supported yet.

This means tools that speak Antelope at the byte level (abieos, legacy eosjs) can often decode PulseVM actions without modification — as `pulsevm-hyperion` demonstrates.

## What PulseVM removes relative to Antelope

Consolidated list:

| Feature | Removed? | Why |
|---|---|---|
| Deferred transactions | ✅ removed | Design decision |
| `wait_weight` in authorities | ✅ removed | Follows from above |
| Rotating producer schedule | ✅ removed | Snowman replaces PBFT |
| Subjective CPU metering | ✅ removed | Replaced with instruction counting |
| `buyram` / RAM market | ✅ (for now) | Not in reference system contract |
| Floating-point types | ✅ removed | Financial correctness |
| `/v1/chain/*` REST API | ✅ replaced | JSON-RPC 2.0 instead |
| Secondary index intrinsics | ✅ not yet | Expected to return eventually |
| ABI v1.2 features (variant, kv) | ✅ not yet | Only v1.1 today |
