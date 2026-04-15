# 02 — `pulse-cdt-rust` (Contract SDK in Rust)

The Rust analogue of `eosio.cdt`. Contracts compile to **wasm32-unknown-unknown** and are deployed via the native `setcode` + `setabi` actions on the `pulse` system account (i.e. `pulse@setcode` / `pulse@setabi`).

## Workspace

Core crates (`Cargo.toml`):

- `pulse_cdt` — main SDK (host bindings, core types, `MultiIndex`, `Singleton`)
- `pulse_proc_macro` — `#[contract]`, `#[action]`, `#[table]`, derives
- `pulse_serialization` — `Read` / `Write` traits + derives
- `pulse_name` — name encoding
- `pulse_bytes` — fixed-size hash/byte types

Reference contracts (`contracts/`):

- `pulse_token` — create / issue / retire / transfer (eosio.token equivalent)
- `pulse_system` — producer voting, delegate/undelegate bw, REX (Bancor), name auctions, RAM market — **substantial**
- `pulse_msig` — multisig proposals
- `pulse_bios` — genesis bootstrap contract

Tests: `test-contracts/test_api_db` exercises raw DB intrinsics.

## Programming model

```rust
#[contract]
impl TokenContract {
    #[constructor]
    fn new() -> Self { ... }

    #[action]
    fn create(issuer: Name, max_supply: Asset) { ... }

    #[action(name = "transfer")]
    fn do_transfer(&self, from: Name, to: Name, quantity: Asset, memo: String) { ... }
}
```

The `#[contract]` proc-macro expands to:

- struct instantiation (default-constructor or `#[constructor]`-designated)
- action dispatcher on `(code, action)` name pairs
- automatic tuple-decoding of action arguments (or `decoder = "path"` override)
- optional `#[destructor]` invoked after each action

Constraints (from `pulse_proc_macro/src/contract.rs:136-155`):
- action methods must be `&self` or static — no `&mut self`, no `self` by value
- `#[action]` method name → action name, overridable via attribute
- at most one `#[constructor]`, at most one `#[destructor]`

## Standard types

All the Antelope core types are present:

- `Name`, `Symbol`, `SymbolCode`, `Asset`
- `TimePoint`, `TimePointSec`, `BlockTimestamp`
- `Checksum160`, `Checksum256`, `Checksum512`
- `PublicKey` (34 bytes — includes 1-byte type tag), `Signature`
- `PermissionLevel`, `Authority`
- `Action`, `ActionWrapper`, `Transaction`, `TransactionHeader`
- `Singleton<T>`, `MultiIndex<T>`

## Multi-index — primary-key-only today

The current `MultiIndex` API supports **only the primary i64 key**. There is **no** Rust-level API for secondary indices (`idx64`, `idx128`, `idx_double`, `idx256`) — because the host intrinsics for them are not yet exposed (see [01-pulsevm-core.md](01-pulsevm-core.md)).

```rust
#[table(primary_key = row.balance.symbol.code().raw())]
pub struct Account { balance: Asset }

const ACCOUNTS: MultiIndexDefinition<Account> =
    MultiIndexDefinition::new(name!("accounts"));

let table = ACCOUNTS.index(code, scope);
table.find(key);       // lookup by primary
table.emplace(payer, |row| { ... });
table.modify(&row, payer, |r| { ... });
table.erase(&row);
```

`Singleton<T>` wraps `MultiIndex<T>` with 1-row semantics (`get` / `set` / `exists` / `remove`).

**Implication for XPR migration:** contracts that use secondary indices (e.g. voter pagination, producer ranking, resource lookups) must either (a) wait for secondary-index intrinsics, or (b) be rewritten to maintain parallel primary-keyed tables. Most `eosio.system` logic hits this.

## Host bindings (what the SDK imports from the VM)

Mirrors what PulseVM exposes (see [05-protocol-reference.md](05-protocol-reference.md)):

- Auth: `require_auth`, `require_auth2`, `has_auth`, `check_transaction_authorization`
- Action: `action_data_size`, `read_action_data`, `require_recipient`, `send_inline`, `is_account`, `current_receiver`
- System: `current_time`, `pulse_assert`, `pulse_exit`
- Privileged: `is_privileged`, `set_privileged`, `get/set_resource_limits`
- Crypto: `sha1`, `sha256`, `sha512`, `ripemd160`, assert-variants, `recover_key`, `assert_recover_key`
- DB (primary i64): `db_store_i64`, `db_update_i64`, `db_remove_i64`, `db_get_i64`, `db_find_i64`, `db_next_i64`, `db_previous_i64`, `db_end_i64`, `db_lowerbound_i64`, `db_upperbound_i64`

## ABI generation

Each contract's `build.rs` parses its own `src/lib.rs` with `syn`, pulls out `#[contract]` impls and `#[table]` structs, maps Rust types to Antelope ABI types, and emits `abi.json` with `"version": "eosio::abi/1.1"`.

Type map (from `build.rs:312-350`): `Name → name`, `Asset → asset`, `String → string`, `u64 → uint64`, `Checksum256 → checksum256`, etc.

**Note:** v1.1 only. No variant types, no KV-table ABI, no Ricardian clauses, no v1.2 features. Antelope chains are already at v1.2, so some imported contracts will need ABI tweaks.

## WASM build pipeline

`.cargo/config.toml`:

```toml
[target.wasm32-unknown-unknown]
rustflags = [
    "-C", "link-arg=--stack-first",
    "-C", "link-arg=-zstack-size=8192",
    "-C", "link-arg=--no-merge-data-segments",
    "-C", "link-arg=--gc-sections",
    "-C", "link-arg=--strip-all",
]
```

Release profile (`Cargo.toml:27-34`): `opt-level="z"`, `lto=true`, `codegen-units=1`, `panic="abort"`, `strip="debuginfo"`.

Allocator: `dlmalloc` with `lol_alloc` fallback. `#![no_std]` throughout.

The recent commit **`c7daf00` "mimic eos wasm llvm requirements"** pinned `--no-merge-data-segments` and `--stack-first` — these match what `eos-llvm` used to produce, because PulseVM's WASM validator is strict about module shape (stack-first placement, separate data segments).

## Testing

There's **no built-in unit-test harness**. `test-contracts/test_api_db/` is a contract that exercises `db_store_i64` + iterator behaviour end-to-end when deployed onto a live PulseVM node. For BP rehearsal, do integration-style testing against A-Chain Alpine (see [09-testing-guide.md](09-testing-guide.md)).

## Gaps

- Enum and union types are `unimplemented!()` in the derive macros (`derive_numbytes.rs:82`, `derive_write.rs:87`, `derive_read.rs:98,101`).
- ABI generator is v1.1 only.
- No secondary-index API.
- Lots of `// TODO docs` placeholders — reference docs are light, read the source.

## What the reference contracts look like

**`pulse_token`** is a near-1:1 translation of `eosio.token` (create, issue, retire, transfer, open, close). Tables: `Account` (balances by symbol code), `CurrencyStats` (supply).

**`pulse_system`** is where the complexity lives. Tables include `producers`, `voters`, `userres`, `delband`, `refunds`, `rexpool`, `namebids`. Actions: `newaccount`, `setcode`, `setabi`, `buyram`, `buyramsys`, `sellram`, `delegatebw`, `undelegatebw`, `voteproducer`, `regproducer`, `claimrewards`. Bancor-style RAM exchange state present. Recent commit `5e41639` "update system contracts" kept pushing on this.

**`pulse_msig`** implements standard multisig propose/approve/exec/cancel.

## How this relates to XPR migration

Most XPR system contracts (`eosio.system`, `eosio.token`, `eosio.msig`, `eosio.wrap`, `eosio.proton` name-auction variants) would need:

1. Port C++ → Rust against `pulse_cdt` types and macros.
2. Remove `wait_weight` authority uses.
3. Remove deferred-transaction patterns.
4. Replace secondary-index reads with alternative table design (until intrinsics land).
5. Regenerate ABI as v1.1.
6. Change `eosio` → `pulse` (or whatever reserved system account is configured at genesis).

See [08-xpr-migration.md](08-xpr-migration.md) for the full plan.
