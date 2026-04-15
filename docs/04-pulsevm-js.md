# 04 — `pulsevm-js` (TypeScript client SDK)

The client library apps and wallets use to call PulseVM. Deliberately shaped like **`@wharfkit/antelope`** so existing Antelope developers feel at home — but it is a standalone implementation (not a re-export).

## Package

- Name: `@metalblockchain/pulsevm-js`
- Version: 0.0.50 (at time of clone)
- Dual CJS + ESM + TS declarations
- Key deps: `@noble/secp256k1` 2.2.3, `@noble/hashes`, `elliptic` 6.6.1, `pako` (zlib)
- Node ≥ 22

Built via Rollup (`rollup.config.mjs`).

## Public API (from `src/index.ts`)

- `PulseAPI` (`src/api.ts`) — the RPC client class
- Chain types (`src/chain/`): `Name`, `Asset`, `Symbol`, `SymbolCode`, `Authority`, `PublicKey`, `PrivateKey`, `Signature`, `Action`, `Transaction`, `SignedTransaction`, `PackedTransaction`, `PermissionLevel`, `Checksum256`, `Checksum160`, `BlockId`, `TimePoint`, `TimePointSec`, `BlockTimestamp`, `UInt8..UInt128`, `Int8..Int128`
- Serializer (`src/serializer/`): `Serializer.encode()`, `Serializer.decode()`, `Serializer.synthesize()` (ABI from TS class)
- Decorators: `@Struct.type()`, `@Struct.field()` for ABI-mapped classes
- Utilities: `Base58`, `isInstanceOf`

## RPC methods (what `PulseAPI` wraps)

Internally uses a `JsonRpcProvider` (`src/rpc.ts`) that POSTs JSON-RPC 2.0 to the node.

| TS method | JSON-RPC method | Notes |
|---|---|---|
| `getInfo()` | `pulsevm.getInfo` | Includes `server_time` (added in commit `48059bf`) |
| `getBlock(numOrId)` | `pulsevm.getBlock` | Full block + transactions |
| `getBlockInfo(num)` | `pulsevm.getBlockInfo` | Header only |
| `getAccount(name)` | `pulsevm.getAccount` | Permissions, resource limits, balance |
| `getABI(name)` | `pulsevm.getABI` | Decoded ABI |
| `getCode(name)` | `pulsevm.getCode` | ABI + WASM hash |
| `getRawABI(name)` | `pulsevm.getRawABI` | base64 blob + hash |
| `getTableRows(params)` | `pulsevm.getTableRows` | Supports ABI decoding + pagination |
| `getTableByScope(params)` | `pulsevm.getTableByScope` | |
| `getCurrencyBalance(contract, account)` | `pulsevm.getCurrencyBalance` | Returns `Asset[]` |
| `getCurrencyStats(contract, symbol)` | `pulsevm.getCurrencyStats` | |
| `getProducerSchedule()` | `pulsevm.getProducerSchedule` | |
| `pushTransaction(tx)` | `pulsevm.issueTx` | Returns just the tx id |

## Transaction flow

```ts
import {
  PulseAPI, PrivateKey, Name, Asset, Action,
  Transaction, SignedTransaction, PackedTransaction
} from '@metalblockchain/pulsevm-js';

const api  = new PulseAPI('http://localhost:9650/ext/bc/<chainId>/rpc');
const info = await api.getInfo();

const action = Action.from({
  account: Name.from('pulse.token'),
  name:    Name.from('transfer'),
  authorization: [{ actor: 'alice', permission: 'active' }],
  data: { from: 'alice', to: 'bob', quantity: '1.0000 SYS', memo: '' }
}, abi);                        // pass the abi to encode `data` correctly

const header = info.getTransactionHeader(120);   // 120 s expiration
const tx     = Transaction.from({
  ...header,
  actions: [action],
  context_free_actions: [],
  transaction_extensions: []
});

const priv   = PrivateKey.from('PVT_K1_…');
const digest = tx.signingDigest(info.chain_id);
const sig    = priv.signDigest(digest);

const signed = SignedTransaction.from({
  ...tx,
  signatures: [sig],
  context_free_data: []
});

const packed = PackedTransaction.fromSigned(signed, 1 /* zlib */);
const txid   = await api.pushTransaction(packed);
```

## Signing details

- Curves: **K1 (secp256k1)**, **R1 (P-256)**, **WA (WebAuthn)** — all via `elliptic` or `@noble/secp256k1`.
- Signatures are **EOSIO-style recoverable** (recovery id + r + s, 65 bytes).
- String format: `SIG_<type>_<base58check>`, e.g. `SIG_K1_KzZ2…`.
- K1 sigs enforce low-s canonical form (`src/crypto/sign.ts`).

Transaction signing digest = `SHA256(chain_id || packed_tx || 32 zero bytes)` — identical to Antelope.

## Wharfkit compatibility

Commit `661860a` "make framework compatible with wharfkit" was a major refactor: old `src/tx/` and `src/serializable/` were replaced with Antelope-shaped chain types and a full serializer. Decorator pattern (`@Struct.type` / `@Struct.field`) matches `@wharfkit/antelope`. Net effect: code written against wharfkit patterns ports across with minimal changes — but this is a **standalone implementation**, not a re-export of wharfkit.

## Serialization

Full Antelope ABI codec (`src/serializer/encoder.ts`, `decoder.ts`, `builtins.ts`):

- All builtin types (int*, uint*, float*, string, bytes, name, asset, checksum*, public_key, signature)
- Struct / variant / array nesting
- `Action.from(data, abi)` auto-encodes through the ABI
- `Serializer.synthesize(Class)` reverse-generates an ABI from a decorated TS class

## Gaps in the SDK

From TODOs in source:
1. `transaction.ts:262` — `PackedTransaction.getSignedTransaction()` doesn't decode context-free data.
2. No end-to-end test for build → sign → pack → push round-trip.
3. `authority.ts:55` has a leftover `console.log()`.
4. README example code references removed classes (`BaseTransaction`, old `Transaction`) — don't trust the README; trust the types.

## How hyperion uses it

See [03-pulsevm-hyperion.md](03-pulsevm-hyperion.md) — pulsevm-hyperion imports `PulseAPI`, `Serializer`, `ABI`, `Action`, `PackedTransaction` from this package in the indexer/deserializer paths.
