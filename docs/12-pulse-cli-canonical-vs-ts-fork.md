# Pulse CLIs — canonical `pulse` vs `pulse-cli-ts`

There are **two `pulse` CLIs** in the ecosystem today, and both are useful. They overlap a little. Don't fight about which one is "real" — pick by ergonomics. Metallicus has indicated the two are intended to coexist while the canonical Rust CLI matures.

## Canonical `pulse` (Metallicus)

**Source:** [`MetalBlockchain/pulsevm/crates/pulse`](https://github.com/MetalBlockchain/pulsevm/tree/main/crates/pulse)
**Binary:** `pulse` (33 MB statically-linked Rust binary)
**Distribution:** Built alongside the runtime and shipped with every pulsevm release as `pulse-cli-linux-{amd64,arm64}.tar.gz`.
**Stack:** Rust + `clap` + `tokio`, depends on `pulsevm_api_client` and `pulsevm_keosd_client` from the same Cargo workspace
**Wallet model:** delegates to `pulse-keosd` daemon (also shipped in the same release)

Subcommands today (v0.2.3):

```
pulse create account     # newaccount via pulse@active
pulse create key         # generate K1 keypair
pulse wallet create / open / lock / unlock / import / list / keys / remove_key / create_key / stop
```

Default `--url` is `http://127.0.0.1:8888` (legacy nodeos shape), so for an A-Chain node use `--url http://127.0.0.1:9650/ext/bc/<blockchainID>/rpc`.

This is the **reference CLI**. As Pulse evolves, expect new subcommands to land here first because the workspace gives them direct access to the canonical types and serialization.

## `pulse-cli-ts` (this repo)

**Source:** [`pulse-cli-ts/`](../pulse-cli-ts/)
**Binary:** `pulse` via npm/oclif (TypeScript, runs on Node.js 22)
**Distribution:** local checkout for now; eventually `git subtree split` → `paulgnz/pulse-cli-ts` → npm
**Stack:** TypeScript + `@oclif/core` + `@metalblockchain/pulsevm-js` + native signing in-process
**Wallet model:** in-process via `pulsevm-js` `PrivateKey.signDigest` — no separate daemon

Subcommands today:

```
pulse chain:info / chain:get
pulse account <name>
pulse table:rows <code> <scope> <table>
pulse network / endpoint
pulse transfer <from> <to> <quantity> [memo]
pulse key:add / key:get / key:lock / key:unlock / key:reset
```

## When to use which

| Task | Canonical `pulse` | `pulse-cli-ts` |
|---|---|---|
| Create a new account on chain | ✅ `create account` | (not implemented; would proxy to canonical anyway) |
| Generate a fresh keypair offline | ✅ `create key` | use `pulsevm-js` `PrivateKey.generate()` directly |
| BP-grade key management with a daemon | ✅ `wallet:*` + `pulse-keosd` | not yet — uses on-disk encrypted keystore |
| Quick read: chain head, account, table | parity coming | ✅ `chain:info` / `account` / `table:rows` |
| Push a transfer / arbitrary action | parity coming | ✅ `transfer` (today) |
| Script against PulseVM from Node | n/a | ✅ same JS lib the CLI is built on |
| Live BP toolchain (multi-key, HSM) | ✅ this is its lane | not its lane |

## Avoiding name collisions

`pulse-cli-ts` is published as the npm package `@metalblockchain/pulse-cli` and exposes the same `pulse` binary name. Two `pulse` binaries on the same `$PATH` is a footgun. Recommended:

- Production / signing host: install **only** the canonical Rust `pulse` (it's part of the bootstrap; lives at `/opt/bin/pulse`)
- Dev / scripting host: install **only** `pulse-cli-ts` via npm
- If you need both: alias one — e.g. `alias pulse-ts='npx -p @metalblockchain/pulse-cli pulse'`

Our `scripts/bootstrap.sh` installs the canonical binary at `/opt/bin/pulse` and keeps a `/opt/bin/pulse-cli` symlink for backwards compatibility with older playbooks.

## Direction of travel

The canonical `pulse` is the long-term home of Antelope-shaped operator tooling. As it gains parity with `pulse-cli-ts`'s read/transfer surface, we'll fold `pulse-cli-ts` down to *only* what the canonical CLI doesn't ship:

- A pure-JS scripting library (already lives in `pulsevm-js`)
- A wharfkit-shaped session/signer for browser dapps (open question — track in `wiki/11-open-questions.md`)

Until then, both are maintained.
