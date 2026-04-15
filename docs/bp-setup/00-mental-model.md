# 00 — Mental model: leap → MetalGo + PulseVM

You already know how a leap BP node works. This page is the smallest set of concepts you need to re-wire before anything else makes sense.

## The process tree

```
Leap (today):
  nodeos  ──(plugins compiled in)──  producer_plugin, chain_plugin, net_plugin,
                                     http_plugin, state_history_plugin, ...
  keosd   (optional, separate)

PulseVM (tomorrow):
  metalgo          ◀── the node: consensus, networking, RPC, staking
   └─ (fork/exec)
      pulsevm      ◀── the VM plugin: chain logic, WASM, state, RPC handlers
  pulse-keosd      (optional, separate)
```

`pulsevm` on its own does nothing useful — it expects a parent `metalgo` that spoke first over gRPC (`AVALANCHE_VM_RUNTIME_ENGINE_ADDR`). If you see a pulsevm process with no metalgo parent, it's a zombie.

## Where "block production" lives now

In leap, the producer_plugin owns block production: builds blocks, signs, gossips. Schedule rotation is consensus-ordered.

In PulseVM, **MetalGo drives block production** through Snowman. Your node is eligible to build a block when metalgo's Snowman engine picks it (production window). When chosen, metalgo calls `BuildBlock` via gRPC into pulsevm, pulsevm drains the mempool, returns a block, metalgo gossips, Snowman finalises in ~200 ms.

Consequences that matter operationally:

- **No producer schedule JSON.** `schedule_version` is 0 forever. `get_producer_schedule` returns all currently-eligible validators, not a rotating subset.
- **No missed-block metric in the leap sense.** You measure "was my node eligible and did it fail to propose" at the Snowman layer.
- **Signing happens at two layers.** Metalgo has a **staking key** (identity for Snowman voting, in `~/.metalgo/staking/`). PulseVM has your **block-signing key** (the Antelope K1/R1/WA key you already have). Do not conflate.

## What doesn't change

- Antelope **account names** — same 1–12 char `[a-z1-5.]` encoding. Your `protonnz` account name is literally portable.
- **Keys.** K1 (secp256k1) is still K1. R1 and WA still work. WIF/PVT formats unchanged. `PUB_K1_...` / `SIG_K1_...` unchanged.
- Transaction wire format, action shape, ABI encoding — byte-compatible for v1.1. Your existing sigd/multisig tooling should keep working.
- `require_auth`, `has_auth`, multi-index primary tables, `send_inline`, `current_receiver` — all the host functions you rely on in contracts.

## What changes — and will bite you

| Thing | Leap | PulseVM | Operator impact |
|---|---|---|---|
| Finality | 45-block LIB, ~120 s | Snowman ~200 ms | Rewrite any "wait N blocks" assumptions |
| CPU metering | wall-clock µs on producer | WASM instructions + 50 µs baseline | Contracts previously "cheap because our hardware is fast" may re-bill differently |
| Deferred txs | supported (historical) | gone | Any contract that schedules future txs is broken — redesign with inline or off-chain keepers |
| `wait_weight` in auth | supported | gone | Delay-based auth unusable |
| RAM market | Bancor via `eosio.ram` | gone (in reference system) | No `buyram`/`sellram`; RAM is allocated, not traded |
| Client API | REST `/v1/chain/*` | JSON-RPC `pulsevm.*` | Wallets and tools need adapter or SDK swap |
| System account | `eosio` | `pulse` | Privileged-account scripts hardcode this |
| Token symbol | e.g. XPR | SYS by default | Genesis decision; overrideable |
| ABI | v1.2 | v1.1 only | Variant / kv tables unsupported |
| State sync | snapshot files (.bin/.zst) | cold sync (state-sync not shipped) | Plan for longer new-validator onboarding |
| Secondary indices | idx64, idx128, idx256, double, ldouble | **not yet implemented** | Most `eosio.system` logic can't be ported verbatim — see 08-xpr-migration.md |

## Mental-model trap to avoid

*"Metal Blockchain is an EVM chain, so this is like deploying Antelope as a sidechain on Metal C-Chain."*

No. **C-Chain** is Metal's EVM. **A-Chain** (PulseVM) is a *separate* subnet with its own validator set, its own chain ID, its own data dir. They talk via bridge contracts, not via shared state. Running a PulseVM validator is not the same as running a C-Chain validator, even though metalgo is the daemon for both.

## Operator first-principles for this environment

1. **Metalgo is the node. PulseVM is the chain.** Two logs, two process states, two sets of metrics.
2. **Your BP key is the Antelope K1 key you already have.** It only signs actions and MSIG proposals. It does not vote on Snowman.
3. **Your Metal validator key is separate.** Metalgo generates `staker.key` + `staker.crt` at first boot — that's your identity for Snowman voting. Back it up like gold.
4. **Upgrades are two-binary now.** Metalgo ships on its own cadence; pulsevm ships on its own. Pin both.
5. **State is not self-describing via snapshot yet.** Assume a cold sync if you redeploy.

Now read [01-server-sizing.md](01-server-sizing.md).
