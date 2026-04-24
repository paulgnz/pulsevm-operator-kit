# Pulse CLIs — canonical `pulse` vs `pulse-cli-ts`

There are **two `pulse` CLIs** in the ecosystem today, and both are useful. They overlap a little. Don't fight about which one is "real" — pick by ergonomics. Metallicus has indicated the two are intended to coexist while the canonical Rust CLI matures.

## Canonical `pulse` (Metallicus)

**Source:** [`MetalBlockchain/pulsevm/crates/pulse`](https://github.com/MetalBlockchain/pulsevm/tree/main/crates/pulse)
**Binary:** `pulse` (Rust, statically linked)
**Distribution:** Built alongside the runtime and shipped with every pulsevm release as `pulse-cli-linux-{amd64,arm64}.tar.gz`.
**Stack:** Rust + `clap` + `tokio`, depends on `pulsevm_api_client`, `pulsevm_api_types`, and `pulsevm_keosd_client` from the same Cargo workspace
**Wallet model:** delegates to `pulse-keosd` daemon (also shipped in the same release)

Subcommands (v0.2.4):

```
pulse get info                           # chain head, chain ID, server version
pulse get account <name>                 # permissions, keys, resources, balances
pulse transfer <from> <to> <amount>      # token transfer with optional memo
pulse set url <url>                      # persist RPC endpoint to ~/.pulse-cli/config.json
pulse set code <account> <wasm-file>     # deploy WASM contract
pulse set abi <account> <abi-file>       # set contract ABI
pulse create account <creator> <name> <owner-key> [active-key]
pulse create key                         # generate K1 keypair
pulse wallet create / open / lock / unlock / import / list / keys / remove_key / create_key / stop
```

Persistent config via `pulse set url` stores the endpoint at `~/.pulse-cli/config.json` (no need to pass `--url` every time after first run).

This is the **reference CLI**. New subcommands land here first because the workspace gives them direct access to the canonical types and serialization.

## `pulse-cli-ts` (this repo)

**Source:** [`paulgnz/pulse-cli-ts`](https://github.com/paulgnz/pulse-cli-ts)
**Binary:** `pulse-ts` via npm/oclif (TypeScript, runs on Node.js 22)
**Distribution:** `git clone` + `npm install`; eventually published to npm
**Stack:** TypeScript + `@oclif/core` + `@metalblockchain/pulsevm-js` + native signing in-process
**Wallet model:** in-process via `pulsevm-js` `PrivateKey.signDigest` — no separate daemon

Subcommands today:

```
pulse-ts chain:info / chain:get
pulse-ts account <name>
pulse-ts table:rows <code> <scope> <table>
pulse-ts network / endpoint
pulse-ts transfer <from> <to> <quantity> [memo]
pulse-ts key:add / key:get / key:lock / key:unlock / key:reset
```

## When to use which

As of v0.2.4, the canonical CLI has caught up on reads + transfer. The two now overlap significantly on the read/write surface; the real difference is ecosystem + ergonomics.

| Task | Canonical `pulse` (v0.2.4) | `pulse-ts` |
|---|---|---|
| Read chain head / info | ✅ `get info` | ✅ `chain:info` |
| Read account | ✅ `get account` | ✅ `account <name>` |
| Push a transfer | ✅ `transfer` | ✅ `transfer` |
| Deploy contract (set code / abi) | ✅ `set code` / `set abi` | not yet |
| Create account on chain | ✅ `create account` | not yet |
| Generate keypair offline | ✅ `create key` | use `pulsevm-js` directly |
| BP-grade wallet + keosd | ✅ `wallet:*` + `pulse-keosd` | local encrypted keystore (no daemon) |
| Read contract tables | not yet | ✅ `table:rows` |
| Script against PulseVM from Node/JS | n/a | ✅ same lib the CLI is built on |
| proton-cli command shape (XPR migration) | different shape | ✅ same shape |
| npm install, no Rust toolchain | n/a | ✅ |

**The proton-cli migration story remains**: XPR developers porting dapps and scripts to Pulse can `npm install` and keep their existing command shapes. Production wallet + signing daemon + contract deployment → canonical `pulse`.

## Avoiding name collisions

`pulse-cli-ts` installs as `pulse-ts` to avoid collision with the canonical `pulse` binary. Both can coexist on the same `$PATH`. Recommended:

- Production / signing host: install **only** the canonical Rust `pulse` (it's part of the bootstrap; lives at `/opt/bin/pulse`)
- Dev / scripting host: install **only** `pulse-cli-ts` via npm
- If you need both: alias one — e.g. `alias pulse-ts='npx -p @metalblockchain/pulse-cli pulse'`

Our `scripts/bootstrap.sh` installs the canonical binary at `/opt/bin/pulse` and keeps a `/opt/bin/pulse-cli` symlink for backwards compatibility with older playbooks.

## Direction of travel

The canonical `pulse` is the long-term home of Antelope-shaped operator tooling. As it gains parity with `pulse-cli-ts`'s read/transfer surface, we'll fold `pulse-cli-ts` down to *only* what the canonical CLI doesn't ship:

- A pure-JS scripting library (already lives in `pulsevm-js`)
- A wharfkit-shaped session/signer for browser dapps (open question — track in `wiki/11-open-questions.md`)

Until then, both are maintained.
