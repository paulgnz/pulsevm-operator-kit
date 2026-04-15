# Edge cases, gotchas, and fixes

Running log of surprises hit while standing up PulseVM. Appended to as we go — newest at top. Each entry names the symptom, the cause, and the fix so you don't have to rediscover.

---

## 2026-04-15 — **Bloks explorer "CPU time" is instruction count, not microseconds** (Glenn confirmed)

The "CPU time" / "CPU usage" field shown for each transaction on the Bloks-powered explorer at `https://a-chain-testnet.metalblockchain.org/` is **the WASM instruction count billed**, not wall-clock execution time. The explorer hasn't been updated to reflect PulseVM's objective-metering model and still reads / labels the field as if it were Antelope's wall-clock µs. This is purely a UI labelling artifact — the on-chain value is unambiguous.

PulseVM uses **objective CPU metering**: per [`PROTOCOL.md`](https://github.com/MetalBlockchain/pulsevm/blob/main/PROTOCOL.md), every action carries a fixed 50 µs baseline + a per-WASM-instruction count via Wasmer's metering middleware. The result is deterministic across producers (no producer can charge a different amount based on its hardware speed). What lands in the receipt's `cpu_usage_us` field is therefore the **instruction count plus the 50µs equivalent baseline**, not wall-clock time.

**Operator implications:**
- Don't compare PulseVM "CPU" numbers to XPR / EOS "CPU µs" numbers directly — different units, different semantics.
- A contract that's "5,000 µs" on EOS and "5,000 (instructions, mislabelled as µs)" on PulseVM are not the same workload.
- Until the explorer's verb is fixed, dashboard CPU readings should be mentally re-labelled as "instructions billed."

**Worth fixing upstream in:** the Bloks explorer's PulseVM-aware build (separate concern from this repo). Verb suggestion: `instructions billed` or `objective cpu`.

---

## 2026-04-15 — **Deployed `pulse` system-contract WASM ≠ `pulse-cdt-rust` repo source** (Glenn confirmed)

**Symptom:** Grepping `pulse-cdt-rust/contracts/pulse_system/src/lib.rs` for `#[action]`-annotated functions gives an action list that may or may not match what's actually deployed at the `pulse` account on A-Chain Alpine. Glenn confirmed on 2026-04-15: *"the system contract is a bit different."*

**Canonical source of truth for on-chain action surface:** decode the live ABI, not the repo.

```bash
# Using @wharfkit/antelope (pulsevm-js's decoder is buggy, documented below)
node scripts/dump-abi.mjs pulse
# or for any other account
node scripts/dump-abi.mjs <account-name>
```

Full canonical dump saved at [`wiki/pulse-abi.json`](pulse-abi.json) as of 2026-04-15.

**Implication for migration tooling:** every tool that encodes / decodes system-contract actions (pulse-cli-ts, contract deploy scripts, multisig builders) should fetch + cache the live ABI, not inline shapes from the repo. Repo sources drift.

---

## 2026-04-15 — **`onblock` event is not handled in pulse yet** (confirmed by Glenn/Metallicus)

**Context:** `onblock` is the action that, on Antelope chains, fires at every block boundary inside the system contract. It handles producer reward distribution, block inflation, producer-schedule updates driven by accumulated votes, continuous-rate minting, etc. Our live-ABI decode shows `onblock` declared as an action on the `pulse` contract (input type `onblock{block_header}`), but Glenn confirmed on 2026-04-15 that **the chain-side callback that would invoke `onblock` at block boundaries is not yet wired up.** Not disabled by choice — just not finished.

**Consequences:**
- The producers table's `total_votes` column will never be updated even if a `voteproducer` action existed, because vote weight recalculation is normally the job of onblock.
- Block-producer rewards (inflation minted to BPs) don't happen.
- The Antelope-style producer schedule (top-21-by-vote consensus group) never rotates — because that rotation is traditionally an onblock output.
- Consequently, **block builder selection on A-Chain Alpine is happening entirely at the Avalanche / Snowman layer** — random sampling across the subnet validator set — not via an Antelope-style producer schedule. The `block.producer` field on each block is just a label assigned by whichever node the Snowman engine picked, based on that node's `chain-config.producer_name`.

**Implication for BP migration planning:** the canonical "Top 21 / rotating schedule" mental model from XPR Network's Antelope stack **does not apply on A-Chain Alpine today**. It may apply later when Metallicus wires up `onblock` + `voteproducer` + reward inflation. Until then, the producer-facing UX is a flat set of subnet validators picked roughly evenly by Snowman, with the on-chain `producers` table as a mostly-decorative registration record.

**Worth asking Metallicus:** what's the intended long-term block-builder selection mechanism? Re-implement Antelope's top-21 rotation, keep Snowman's random sampling as the canonical scheduler, or hybrid? This affects how XPR voter-weight semantics map during the migration.

---

## 2026-04-15 — **pulsevm-js `ABI.from(Buffer)` silently returns empty; use `@wharfkit/antelope`'s `Serializer.decode`**

**Symptom:** `pulsevm.getRawABI` returns a valid 11.5 KB base64 blob. Passing the bytes to pulsevm-js `ABI.from(buffer)` yields an object with `actions=[]`, `tables=[]`, `structs=[]` — silently, no error. Same family of decoder bugs as `getABI`, `getBlock`, and the push-tx wrapper we've documented.

**Cause:** pulsevm-js's `ABI.from` expects a JSON object or string, not the Antelope binary ABI format. Feeding raw binary bytes doesn't throw but parses as an empty ABI.

**Fix:** use `@wharfkit/antelope` for ABI binary decode:

```ts
import {ABI, Serializer} from '@wharfkit/antelope'
const raw = Buffer.from(abiBase64, 'base64')
const abi = Serializer.decode({data: raw, type: ABI})
// abi.actions, abi.tables, abi.structs now populated
```

Full decoded ABI for the `pulse` system account on A-Chain Alpine as of 2026-04-15 is saved at `wiki/pulse-abi.json` — 1548-line canonical reference. 16 actions, 28 tables, 56 structs. Notable findings from the decode:

- **No voteproducer / voteproxy / claimrewards / bidname / buyram / sellram actions.** The producers table tracks `total_votes` but nothing on-chain writes to it. Voting isn't implemented yet.
- XPR-specific scaffolding tables present (`delxpr`, `votersxpr`, `refundsxpr`, `globalsxpr`) — data structures staged for XPR-semantics but action surface not yet populated.
- `regproducer2` takes `block_signing_authority` (thresholded multi-key authority) instead of a single key — modern eosio.system style, available if we want stronger producer auth.
- Full REX table set exists (`rexpool`, `rexfund`, `rexbal`, `netloan`, etc.) but no REX actions either.

**Operator implication:** always decode ABIs via @wharfkit/antelope, not pulsevm-js. Worth PR'ing the fix upstream to pulsevm-js so `ABI.from` accepts both shapes.

---

## 2026-04-15 — **Default Snowman params can't form quorum on small subnets; set tuned `subnet-config`**

**Symptom:** Our node joins the A-Chain Alpine subnet validator set and connects to peers fine, but stays stuck at the height it had when it joined. Chain-specific log floods with:

```
WARN <...Chain> snowman/engine.go:885 dropped query for block
  {"reason": "insufficient number of validators", "blkID": "...", "size": 20}
```

`/ext/health` shows `healthy: false` with the subnet's lastAcceptedHeight far behind the public chain head. New blocks arrive but never finalise on our node.

**Cause:** Snowman's default sampling params target a large validator network. Defaults:

```
k=20, alphaPreference=15, alphaConfidence=15, beta=20
```

Meaning: sample 20 validators per poll, require 15 to agree to count the poll, and 20 consecutive passing polls to finalise. On a 6-validator subnet like A-Chain Alpine, `k=20` samples all 6, but 15 agreements is impossible with only 6 available. Every poll drops. Chain never finalises from the affected node's view.

Other validators on the subnet (`pulsebp1`..`5`) must be running tuned configs locally; they never published theirs, so new joiners silently inherit the impossible defaults. Our node is the sixth validator on this subnet, and was the first to hit this.

**Fix:** drop a subnet config at `~/.metalgo/configs/subnets/<subnetID>.json` (or point `--subnet-config-dir` elsewhere) with tuned consensus parameters. We used:

```json
{
  "validatorOnly": false,
  "consensusParameters": {
    "k": 5,
    "alphaPreference": 4,
    "alphaConfidence": 4,
    "beta": 6,
    "concurrentRepolls": 4,
    "optimalProcessing": 10,
    "maxOutstandingItems": 256,
    "maxItemProcessingTime": 30000000000
  },
  "proposerMinBlockDelay": 1000000000,
  "proposerNumHistoricalBlocks": 0
}
```

Meaning: sample 5 of 6, need 4/5 to agree, finalise after 6 consecutive passing polls. After a graceful SIGTERM restart we caught up from height 39 to 49 immediately.

**Lesson for the playbook:** Snowman subnet consensus params must be sized to the validator count. Whenever a BP joins a permissioned subnet, **they must either be handed the canonical subnet config by the subnet operator** or copy it from a healthy peer. Every XPR BP joining A-Chain will need this — worth asking Metallicus to publish the canonical config alongside the subnet ID.

**Also a side effect to watch:** the WASM runtime error `apply error: pulse assert failed: no balance object found` we also saw was caused by verifying blocks in a state where the prerequisite balance hadn't been applied — a downstream consequence of being unable to finalise in order.

---

## 2026-04-15 — **Never `kill -9` metalgo; Chainbase dirty flag kills PulseVM on restart**

**Symptom:** After an aggressive metalgo shutdown (SIGKILL / `kill -9` / killing the tmux session forcefully), metalgo restarts fine but the PulseVM subnet chain fails to create. Chain-specific log (`/var/log/metalgo/<chainID>.log`) shows:

```
[info] initializing controller with DB path: /var/lib/metalgo/chainData/<chainID>
terminate called after throwing an instance of 'boost::wrapexcept<std::system_error>'
  what():  Database dirty flag set
```

Plugin dies within ~100 ms of startup. Metalgo records `plugin handshake succeeded` then immediately `stdout/stderr collector shutdown` — the plugin exited. `/ext/bc/<chainID>/rpc` returns `404 page not found`. Metalgo's health API marks the subnet check failing with `failed to create chain ... Unavailable EOF`.

**Cause:** PulseVM uses **Chainbase** (C++ Boost multi-index DB) via FFI. Chainbase mmap's its state and sets a "dirty flag" when modifying. On graceful shutdown it clears the flag. If the process is SIGKILL'd mid-write, the flag stays set — next open raises `Database dirty flag set` and the process aborts to avoid corrupting state.

Exact thing we did wrong: `tmux kill-session -t mgo` + `pkill -9 metalgo` while the subnet plugin was writing blocks. Plugin died instantly, flag stuck.

**Recovery paths, in order of preference:**

1. **If you have state worth preserving** (mainnet validator, long chain history): *don't be in this situation.* Always graceful-shutdown metalgo (SIGTERM, wait for `finished node shutdown` log line). If you get here, pulsevm has no public "clear dirty flag" API yet; contact Metallicus or patch Chainbase to bypass the check after manual state verification.
2. **If state is replaceable** (testnet, subnet observer, dev box): delete `/var/lib/metalgo/chainData/<chainID>/` and restart. Metalgo re-syncs the subnet from peers. On Alpine with 38 blocks this takes seconds. This is what we did.
3. **Single-node devnet being torn down anyway:** wipe the whole data dir `/var/lib/metalgo/` and rebuild genesis.

**Operator rule:** to stop metalgo, use one of:

- `pkill -TERM metalgo` (SIGTERM, default kill signal) and `sleep 10` before doing anything destructive, OR
- `tmux send-keys -t mgo C-c` and wait for shutdown, OR
- under systemd, `systemctl stop metalgo` which waits up to `TimeoutStopSec`.

**Never** `kill -9` / SIGKILL. Watch for the `finished node shutdown` line in the log; that's your green light the mmap is closed cleanly.

**Migration playbook implication:** worth adding to the BP setup + the operator ops-runbook as a **bold must-read** item. Most BPs coming from leap/nodeos have reflexes that include hard-killing unresponsive nodes — on metalgo+PulseVM, that corrupts the state flag and forces a resync on every node.

---

## 2026-04-15 — **Tahoe primary-network validators must NOT run with `--partial-sync-primary-network=true`**

**Symptom:** After `platform.addPermissionlessValidator` Committed, `platform.getCurrentValidators` returned our validator record but with `connected: false` and slowly-climbing `uptime`. `info.peers` on Tahoe's public node showed us correctly peered but with `benched: ["C", "X"]`. Glenn's view: "says not connected."

**Cause:** We had started metalgo with `--partial-sync-primary-network=true` — a flag introduced to let subnet-only observer nodes skip C-Chain and X-Chain state bootstrap (saves disk + time). Perfect for a non-validating subnet node. **Incompatible** with being a primary-network validator, because the primary-network validator contract requires you to validate P-Chain + X-Chain + C-Chain. Other Tahoe validators bench you on C and X because you don't answer their consensus messages, and the aggregate `connected` metric never goes true.

**Fix:** Restart metalgo **without** `--partial-sync-primary-network`. It then bootstraps both remaining chains (C-Chain took 1616 blocks in ~1s on Tahoe, X-Chain 62 blocks in ~12ms — fast because Tahoe is tiny).

**Lesson for the migration playbook:** two node shapes with different flags.

- **Subnet-only observer** (any XPR community member wanting a read-only A-Chain node): full-sync skippable → faster to stand up, less disk. Add `--partial-sync-primary-network=true`.
- **Primary-network + subnet validator** (every A-Chain BP): must full-sync primary network.

Bake this branch into `scripts/bootstrap.sh` / the join-guide when we generalise for other BPs.

**Gotchas bundle discovered in the same onboarding sequence:**

- `metalgo v1.13+` removed the keystore API; generate P-Chain keypairs offline via metaljs/avalanchejs (see `scripts/metalgen.mjs`). Previous validator guides online that reference `keystore.createUser` are stale.
- `metaljs` `CChain.getBlockchainID()` returns the *alias* (`"tahoe"`) not the cb58 hash; `await cchain.refreshBlockchainID()` before anything that calls `cb58Decode(this.blockchainID)` internally.
- `metaljs` C-Chain keychain `.getAddresses()` returns the **Avalanche Bech32 20-byte form** (`ripemd160(sha256(pubkey))`). To get the EVM `0x...` address your MetaMask / Core wallet recognises, derive via `ethers.Wallet(hexPriv).address` (keccak256 of uncompressed pubkey). **Different address — sending METAL to the wrong one doesn't brick you but needs a follow-up move.**
- `platform.addPermissionlessValidator` requires a `Signer` wrapping a `ProofOfPossession(BLS_pubkey, BLS_sig)` with `typeID = PlatformVMConstants.SIGNERPRIMARYNETWORK = 28`. Signer built without this is rejected.
- `platform.getPendingValidators` RPC method was removed in metalgo v1.13. Use `platform.getCurrentValidators` after Committed (new entry appears with start time in the future and no uptime).
- C-Chain ExportTx with `fee = new BN(0)` is rejected as "insufficient funds" — pass an explicit fee (we used 1,000,000 nAVAX = 0.001 METAL).

---

## 2026-04-15 — **Account creation is pulse@active-only on A-Chain Alpine (WASM-enforced)**

**Symptom:** Signing `pulse@newaccount` from any account you control (other than `pulse`) fails with:

```
wasm runtime error: apply error: missing authority of pulse
```

**Cause:** The **WASM system contract deployed at `pulse`** (code hash `a351dd76…`, ABI hash `fd88bb2a…` on Alpine as of 2026-04-15) calls `require_auth(pulse)` during its `newaccount` handler. The **native** `newaccount` action itself accepts any payer — the restriction lives purely in the WASM system contract, identical to how eosio.system gates some actions on EOS. Since `pulse@active` is held by Metallicus, **Metallicus is the only party that can create accounts on A-Chain Alpine today.**

**What we verified:**
- A-Chain Alpine has no `bidname` / name auction surface exposed.
- No `freeaccount`-style action on a separate account (Proton's `eosio.proton::freeaccount` pattern) visible on the handful of accounts we've enumerated.
- No `linkauth` delegation on `pulse` routing `newaccount` to a sub-permission.
- The shared dev key `PVT_K1_2pjSq…` authorizes `hello@active` (and was the genesis initial key), but `hello` alone can't create accounts because of the WASM check above.

**Implication for BP migration:** Phase 3 (subnet validator add) AND Phase 4 (account creation) both route exclusively through Metallicus right now. The two-gate model documented in the playbook is real — no self-service path at either layer. Any XPR BP following the playbook should budget **~1 cycle of outreach-then-wait** before on-chain action.

**How this could change in the future:**
- Metallicus deploys a less strict system contract (`pulse@setcode`) — reduces to the native-only check (any payer).
- A parallel `freeaccount`-style contract is deployed at e.g. `pulse.proton`.
- A `pulse@linkauth` delegates `newaccount` to a rotatable sub-permission so it doesn't require cold-storage signing for routine onboarding.

Raising all three as options in the next Metallicus outreach.

---

## 2026-04-15 — **RPCChainVM protocol version mismatch** between MetalGo and PulseVM

**Symptom:** `control start` hangs, then nodes log:

```
failed to create chain on subnet ...: error while creating vm: handshake failed:
RPCChainVM protocol version mismatch between AvalancheGo and Virtual Machine plugin.
MetalGo version v1.12.2 implements RPCChainVM protocol version 39.
The VM located at .../pulsevm implements RPCChainVM protocol version 43.
```

**Cause:** AvalancheGo / MetalGo negotiates plugin protocol by exact version number. MetalGo **v1.12.2 (Etna.2, the current "Latest" release, tagged 2025-12-10)** speaks v39. **PulseVM v0.2.3 (tagged 2026-04-10)** was built against a newer upstream and speaks v43. They refuse to handshake.

**Fix:** Use **MetalGo v1.13.5-tahoe** (pre-release, tagged 2026-04-03, `metalgo/1.13.5 [... rpcchainvm=43 ...]`). It matches PulseVM v0.2.3.

```bash
wget https://github.com/MetalBlockchain/metalgo/releases/download/v1.13.5-tahoe/metalgo-linux-amd64-v1.13.5-tahoe.tar.gz
```

**Compatibility matrix (verified empirically, 2026-04-15):**

| MetalGo | rpcchainvm | Compatible PulseVM |
|---|---|---|
| v1.12.2 "Etna.2" | 39 | v0.1.0, v0.1.1 (likely) |
| v1.13.5-tahoe | 43 | v0.2.1, v0.2.2, v0.2.3 |

**Implication for BPs:** Tahoe is Metal's **testnet-branded pre-release**. It is *not* the current mainnet release. Running PulseVM today therefore means running a pre-release node. For production, wait for Metallicus to bless a stable MetalGo that implements rpcchainvm v43 (or whatever PulseVM mainnet targets).

**Lesson:** The `bootstrap.sh` must pin **both** metalgo and pulsevm together, and the comment should note the expected rpcchainvm version so future drift is obvious.

---

## 2026-04-15 — `metal-network-runner control start` default `--request-timeout=3m` is too short

**Symptom:** `control start` exits with `rpc error: code = DeadlineExceeded desc = context deadline exceeded` after 3 min. The runner tears down all nodes on exit — leaves you with nothing running.

**Cause:** Default client-side request timeout is 3 min. On a modest box (4 vCPU, 16 GB) booting 5 metalgo nodes, bootstrapping the primary network, creating the subnet, registering the pulsevm VM, and creating the A-Chain together take **4–6 min**, comfortably over the default.

**Fix:** Pass `--request-timeout=10m` (or more). The server side keeps working regardless of the client timeout; setting a generous value just lets the client wait.

```bash
/opt/bin/metal-network-runner control start \
  --request-timeout=10m \
  --endpoint="0.0.0.0:8080" \
  --number-of-nodes=5 \
  --avalanchego-path /opt/metalgo/metalgo \
  --plugin-dir /opt/pulsevm/plugins \
  --blockchain-specs '[{"vm_name":"pulsevm","genesis":"/path/to/genesis.json"}]'
```

---

## 2026-04-15 — `metal-network-runner` flag renamed: `--metalgo-path` → `--avalanchego-path`

**Symptom:** `pulsevm/README.md`'s "Run locally" example fails with `Error: unknown flag: --metalgo-path`.

**Cause:** `metal-network-runner` v1.9.0 (Apr 2026 release) uses the upstream Avalanche flag name `--avalanchego-path`, not the Metal-branded `--metalgo-path`. The pulsevm README was written against an older version.

**Fix:** Replace `--metalgo-path` with `--avalanchego-path` in all `control start` invocations. The value you pass is still the path to the `metalgo` binary — only the flag name changed.

```bash
/opt/bin/metal-network-runner control start \
  --log-level info \
  --endpoint="0.0.0.0:8080" \
  --number-of-nodes=5 \
  --avalanchego-path /opt/metalgo/metalgo \
  --plugin-dir /opt/pulsevm/plugins \
  --blockchain-specs '[{"vm_name":"pulsevm","genesis":"/path/to/genesis.json"}]'
```

---

## 2026-04-15 — `pkill -f <pattern>` inside an ssh-executed command kills its own shell

**Symptom:** `ssh host 'pkill -f metal-network-runner; echo done'` prints `done` is missing and `ssh` exits 255. Multi-command chains that start with `pkill -f` appear to "abort the SSH session."

**Cause:** When ssh runs a remote command, the shell's argv contains the literal pattern string (e.g. `bash -c 'pkill -f metal-network-runner; ...'`). `pkill -f` matches **against the full command line of every process**, so it matches its own parent shell's argv and sends SIGTERM to itself. The ssh connection then drops abruptly → ssh exits 255.

**Fix:** Don't use `pkill -f` patterns that also appear in your ssh wrapper command. Options:

- Use `pkill -x <binary>` — exact match on the `comm` field (process name only, not argv).
- Use `pgrep` first and explicitly exclude `$$`: `pgrep -f pattern | grep -v $$ | xargs -r kill`.
- Run `killall <binary>` (argv[0] only).
- Put the kill command in a script file on the server and `ssh host bash /path/to/cleanup.sh`.

---

## 2026-04-15 — PulseVM README says LLVM 18, CI actually uses LLVM 21

**Symptom:** `pulsevm/README.md` says "LLVM 18: used to compile and run WebAssembly contracts." If you install LLVM 18 and try to build from source, link fails or `llvm-sys` complains.

**Cause:** `.github/workflows/build.yml:30,55` installs `llvm-21-dev libpolly-21-dev` and exports `LLVM_SYS_211_PREFIX=/usr/lib/llvm-21`. The README was not updated when the CI bumped.

**Fix:** Install LLVM 21. Set `LLVM_SYS_211_PREFIX=/usr/lib/llvm-21`. Our `scripts/bootstrap.sh` handles this.

---

## 2026-04-15 — No prebuilt macOS binaries

**Symptom:** `pulsevm/scripts/install.sh` refuses to run on macOS (`Unsupported architecture` or fails at asset-lookup for a Mac tarball that doesn't exist).

**Cause:** `.github/workflows/build.yml` only matrices Linux amd64 and arm64. No darwin target.

**Fix:** Run PulseVM on Linux. For dev, use a remote Linux box via SSH (this wiki) or Colima/Docker Desktop with a Linux container. Building from source on Mac is possible per the README but CI doesn't prove it works.

---

## 2026-04-15 (update) — **pulsevm-hyperion's active branch is `release/3.6`, not `main`.** Most of the half-port issues below are already fixed there.

Glenn confirmed 2026-04-15 that `release/3.6` is where the PulseVM-specific work lives. Local clones via `git clone https://github.com/MetalBlockchain/pulsevm-hyperion` check out `main` by default — which is a stale snapshot with 18+ stale `/v1/chain/*` call sites and the genesis-adjacent `prev_block` crash documented below.

Swap to release/3.6:

```bash
cd pulsevm-hyperion
git fetch origin release/3.6:refs/remotes/origin/release/3.6
git checkout release/3.6
npm install && npm run build
```

Verified 2026-04-15: on release/3.6, Hyperion speaks `pulsevm-js` directly against a PulseVM RPC, no REST shim needed. The `prev_block` null-guard at `deserializer.ts:302` is already in place. ES indexing works end-to-end: 378 blocks + 436 actions + deltas + ABIs, `/v2/health` all-green (StateHistory / RabbitMq / NodeosRPC / Elasticsearch).

The six route handlers still showing one `fastify.antelope.chain.*` call each on 3.6 (`v2/health`, `v2-history/get_actions`, `v2-history/get_transaction`, `v1-history/get_actions`, `v1-history/get_transaction`, `v1-trace/get_block`) may be intentional fallbacks routed through `fastify.antelope` which is now a PulseAPI-backed shim on 3.6 — not the same bug as on main.

**Bottom line:** if you're standing up Hyperion for A-Chain today, start on `release/3.6`. The original writeup below describes the state on `main`, preserved for reference.

---

## 2026-04-15 — pulsevm-hyperion **core indexer + API** is also half-migrated (worse than initially thought)

**Symptom:** After configuring `config/connections.json` + `config/chains/alpine.config.json` and running `./run alpine-indexer`, the master process dies with:

```
[00_master] Chain API Error: HTTP 404 at /v1/chain/get_info
... (12 retries, 60s) ...
[00_master] Chain API not available, exiting...
```

**Cause:** Upstream fork commit `41223a0` ("update hyperion for pulsevm") only touched the deserializer and a handful of route handlers. The indexer master, lifecycle manager, fastify-antelope plugin, API server, v1 + v2 route handlers, v1-trace/get_block, sync-modules, and helpers/functions all **still call `this.rpc.v1.chain.*` / `fastify.antelope.chain.*`** — which goes via `@wharfkit/antelope`'s REST `APIClient`, which hits `/v1/chain/get_info` (does not exist on PulseVM).

Grep surface confirmed 2026-04-15: 18+ call sites still on the old API in these files:

- `src/indexer/modules/master.ts:845, 1542`
- `src/indexer/modules/lifecycleManager.ts:215, 333`
- `src/api/routes/v2/health/health.ts:129`
- `src/api/routes/v2-history/get_actions/get_actions.ts:76`
- `src/api/routes/v2-history/get_transaction/get_transaction.ts:34`
- `src/api/routes/v1-history/get_actions/get_actions.ts:274`
- `src/api/routes/v1-history/get_transaction/get_transaction.ts:53`
- `src/api/routes/v1-trace/get_block/get_block.ts:69`
- `src/api/server.ts:296`
- `src/api/plugins/fastify-antelope.ts:14`
- `src/cli/sync-modules/sync-permissions.ts:50`
- plus `src/api/routes.ts:99` calls `/v1/node/get_supported_apis`

**Implication:** `pulsevm-hyperion` is **not operational** against a PulseVM node without either:
1. A file-by-file patch of every stale call site (high maintenance burden), OR
2. A **REST → JSON-RPC compatibility shim** that accepts `/v1/chain/*` requests and translates to `pulsevm.*`. Hyperion points at the shim instead of the node. As a side benefit the shim also unlocks `cleos`, `proton-cli`, and any other Antelope tool against PulseVM with no per-tool changes.

**Recommended fix:** Path 2 (shim). Prototype is ~150 lines Fastify/Node or Go. Can be packaged as `pulsevm-rest-compat` and run under pm2 alongside the node.

**Until then:** Hyperion is parked. Stack (ES/Mongo/Rabbit/Redis) is healthy and ready — only the indexer & API can't talk to the chain.

---

## 2026-04-15 — pulsevm-hyperion CLI half-migrated to pulsevm-js

**Symptom:** `hyp-config`, `hyp-control`, `repair-cli/scan.ts`, `sync-modules/sync-*.ts` still import `@wharfkit/antelope` and call `api.v1.chain.*` methods, which don't exist on `PulseAPI`. They fail at runtime against a PulseVM node.

**Cause:** Commit `41223a0` ("update hyperion for pulsevm") only updated the indexer + API layers (`deserializer.ts`, `master.ts`, `fastify-antelope.ts`). CLI tools were not touched.

**Fix for now:** Avoid those CLI paths; drive Hyperion directly via config-file edits + pm2. When we port a contract or run the repair tool in anger, we'll need to patch these imports and method calls. See [03-pulsevm-hyperion.md](03-pulsevm-hyperion.md).

---

## 2026-04-15 — `pulsevm/scripts/install.sh` only installs pulsevm, not metalgo or metal-network-runner

**Symptom:** Running the repo's install script leaves you with a VM plugin binary and no way to actually run a chain.

**Cause:** By design — `install.sh` only installs the VM plugin into `~/.metalgo/plugins/<VM_ID>`. It assumes metalgo is already present.

**Fix:** Use our `scripts/bootstrap.sh` which installs all three binaries (metalgo + pulsevm plugin + metal-network-runner) and the full toolchain.

---

## 2026-04-15 — Boost git submodules make `pulsevm` clone huge (~1 GB, many minutes)

**Symptom:** `git clone --recurse-submodules https://github.com/MetalBlockchain/pulsevm` takes 5–10 min and spams hundreds of "Cloning into .../libs/<name>" lines.

**Cause:** `crates/pulsevm_ffi/pulsevm/libraries/boost/` pulls the full Boost monorepo as nested submodules. Needed for Chainbase C++ build.

**Fix:** Just wait the first time. `--depth=1 --shallow-submodules` is an option if the download is painful. If you only want to run prebuilt binaries (not rebuild PulseVM core), you can skip `--recurse-submodules` entirely.

---

## Reserved for next occurrence

When we hit something:
- Symptom: what you see
- Cause: what's actually wrong
- Fix: what makes it go away
