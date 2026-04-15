# 06 — JSON-RPC reference

PulseVM exposes JSON-RPC 2.0 (not REST like nodeos). All methods are namespaced `pulsevm.*`. Called by POSTing `{"jsonrpc":"2.0","method":"pulsevm.X","params":{...},"id":1}` to the chain's RPC endpoint.

Endpoint path on MetalGo: typically `http://<host>:9650/ext/bc/<chainID>/rpc` (standard Avalanche subnet RPC routing).

## Method table

| Method | Params | Returns | nodeos equivalent |
|---|---|---|---|
| `pulsevm.issueTx` | `{signatures, compression, packed_trx}` | `{tx_id, block_num?}` | `/v1/chain/push_transaction` |
| `pulsevm.getInfo` | — | chain_id, head_block_num, head_block_id, head_block_time, server_time | `/v1/chain/get_info` |
| `pulsevm.getBlock` | `{block_num_or_id}` | full signed block | `/v1/chain/get_block` |
| `pulsevm.getBlockInfo` | `{block_num}` | block header only | `/v1/chain/get_block_info` |
| `pulsevm.getAccount` | `{account_name, expected_core_symbol?}` | permissions, resource limits, balances | `/v1/chain/get_account` |
| `pulsevm.getABI` | `{account_name}` | decoded ABI JSON | `/v1/chain/get_abi` |
| `pulsevm.getRawABI` | `{account_name}` | base64 ABI + code hash | `/v1/chain/get_raw_abi` |
| `pulsevm.getCode` | `{account_name}` | ABI + WASM hash | `/v1/chain/get_code` |
| `pulsevm.getCodeHash` | `{account_name}` | `{code_hash}` | (custom) |
| `pulsevm.getRequiredKeys` | `{transaction, available_keys}` | `Set<PublicKey>` | `/v1/chain/get_required_keys` |
| `pulsevm.getTableRows` | `{code, scope, table, lower_bound, upper_bound, limit, json, reverse, index_position, key_type, encode_type}` | `{rows, more, next_key}` | `/v1/chain/get_table_rows` |
| `pulsevm.getTableByScope` | `{code, table, lower_bound, upper_bound, limit, reverse}` | `{tables, more}` | `/v1/chain/get_table_by_scope` |
| `pulsevm.getCurrencyBalance` | `{code, account, symbol?}` | `Asset[]` | `/v1/chain/get_currency_balance` |
| `pulsevm.getCurrencyStats` | `{code, symbol}` | `{supply, max_supply, issuer}` | `/v1/chain/get_currency_stats` |
| `pulsevm.getProducerSchedule` | — | active/pending/proposed producer sets | `/v1/chain/get_producer_schedule` |

Service implementation: `pulse/src/chain/service.rs` (uses `jsonrpsee`).

## WebSocket state-history

Separate endpoint on `WS_BIND` (default `0.0.0.0:9090`). Streams blocks + deltas in a format close enough to SHIP that Hyperion (stock upstream) consumes it after just the API-layer changes documented in [03-pulsevm-hyperion.md](03-pulsevm-hyperion.md).

## Request / response examples

### `pulsevm.getInfo`

```json
{"jsonrpc":"2.0","method":"pulsevm.getInfo","id":1}
```

```json
{
  "jsonrpc":"2.0","id":1,
  "result":{
    "server_version":"…",
    "chain_id":"<hex>",
    "head_block_num": 1234,
    "head_block_id":"<hex>",
    "head_block_time":"2026-04-15T12:00:00.500",
    "server_time":"2026-04-15T12:00:00.500",
    "last_irreversible_block_num": 1234,
    "last_irreversible_block_id":"<hex>"
  }
}
```

Note: under Snowman finality, once `BlockAccept` fires `last_irreversible_block_num` tracks `head_block_num` closely — unlike Antelope's 45-block LIB lag.

### `pulsevm.issueTx`

```json
{"jsonrpc":"2.0","method":"pulsevm.issueTx","id":1,
 "params":{
   "signatures":["SIG_K1_…"],
   "compression":1,
   "packed_trx":"<hex>"
 }}
```

Returns `{"tx_id":"<hex>"}`. Compression: `0` = none, `1` = zlib.

### `pulsevm.getTableRows`

```json
{"jsonrpc":"2.0","method":"pulsevm.getTableRows","id":1,
 "params":{
   "code":"pulse.token",
   "scope":"alice",
   "table":"accounts",
   "limit":10,
   "json":true
 }}
```

**Caveat:** because the current protocol has no secondary-index intrinsics, `index_position` values other than `1` (primary) will fail or be ignored. Clients that rely on secondary-index reads (many XPR governance UIs) need to adapt.

## Differences from nodeos REST that bite clients

1. **Transport:** POST of JSON-RPC body to single URL, not path-based REST. Most SDKs need a tiny shim.
2. **No `/v1/history/*`** — PulseVM itself has no history; that is entirely Hyperion's job.
3. **No `/v1/chain/abi_json_to_bin` / `abi_bin_to_json`** — clients encode/decode ABI themselves (pulsevm-js does).
4. **No `/v1/chain/get_scheduled_transactions`** — no deferred txs.
5. **`pulsevm.issueTx` response is minimal** — returns tx id, not the full trace like nodeos. If you need traces, subscribe via Hyperion or the state-history WS.

## Compatibility layer strategy

For XPR migration: a thin Express/Fastify proxy can front a PulseVM node and serve `/v1/chain/*` REST paths that translate to `pulsevm.*` JSON-RPC. That lets legacy XPR wallets/tools keep working unchanged until they migrate to pulsevm-js. Hyperion already does this for history endpoints; the proxy only needs to cover the chain endpoints Hyperion doesn't already serve.
