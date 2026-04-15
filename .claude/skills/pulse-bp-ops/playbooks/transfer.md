# Push a transfer (or any action)

Goal: get a signed action onto Pulse without hand-rolling the tx envelope.

## Easy path — `pulse-cli`

```bash
pulse transfer <from> <to> "<quantity>" "<memo>"
# e.g.
pulse transfer protonnz hello "1.0000 XPR" "gm"
```

Signs from whatever private key for `<from>@active` is in the wallet (`pulse wallet:add` to import). Defaults to `pulse.token` contract; override with `--contract` and `--permission`.

## Medium path — `pulsevm-js` programmatic

```typescript
import { PulseAPI, PrivateKey, Action, Transaction, SignedTransaction, PackedTransaction } from '@metalblockchain/pulsevm-js'

const api = new PulseAPI('https://a-chain-alpine.metalblockchain.org/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc')
const info = await api.getInfo()
const block = await api.getBlock(info.last_irreversible_block_num)

const action = Action.from({
  account: 'pulse.token',
  name: 'transfer',
  authorization: [{ actor: 'protonnz', permission: 'active' }],
  data: { from: 'protonnz', to: 'hello', quantity: '1.0000 XPR', memo: 'gm' },
})

const tx = Transaction.from({
  expiration: new Date(Date.now() + 120_000).toISOString().replace(/\.\d+Z$/, ''),
  ref_block_num: block.block_num & 0xFFFF,
  ref_block_prefix: block.ref_block_prefix,
  max_net_usage_words: 0,
  max_cpu_usage_ms: 0,
  delay_sec: 0,
  context_free_actions: [],
  actions: [action],
  transaction_extensions: [],
})

const CHAIN_ID = '0d6f033e887fae475d641104b6e87762b6c869e87a101afeeb64d608ab376618'
const sig = PrivateKey.from('PVT_K1_...').signDigest(tx.signingDigest(CHAIN_ID))
const signed = SignedTransaction.from({ ...tx, signatures: [sig.toString()], context_free_data: [] })
const packed = PackedTransaction.fromSigned(signed, 0)

const result = await api.pushTransaction(packed)
console.log(result)
```

## Failure modes

- **`tx_net_usage_exceeded`** — bump `max_net_usage_words` to a non-zero value (e.g. 4096) for large data payloads.
- **`expired_tx_exception`** — your `expiration` is in the past relative to the chain's clock. Bump it; check `info.head_block_time`.
- **`missing authority of <account>`** — your signing key doesn't satisfy the action's `authorization`. For `pulse::*` actions on testnet you typically need `pulse@active` co-signing — that's a Metallicus call.
- **`unsatisfied_authorization`** — the action's `data.from` doesn't match `authorization.actor`. Common with copy-paste.
- **No `tx_id` in response** — `pushTransaction` returned a string id directly. Treat the whole result as the id; don't try `.transaction_id` on a string.

## Hyperion side-effects

After a push, allow 1-2 seconds for Hyperion to ingest. Then:

```
GET https://<hyperion>/v2/history/get_transaction?id=<tx_id>
```

If it 404s, Hyperion hasn't seen it yet — wait, then retry. If it 500s, that's the indexer barfing — see `playbooks/troubleshooting.md`.
