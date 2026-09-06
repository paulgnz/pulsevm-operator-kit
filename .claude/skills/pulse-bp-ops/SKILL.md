---
name: pulse-bp-ops
description: Operate a PulseVM / A-Chain block producer node — bootstrap, key handling, joining the testnet, becoming a validator, regproducer, transfers, Hyperion stack, troubleshooting Snowman / rpcchainvm / unclean-shutdown issues. Use whenever the user mentions PulseVM, A-Chain, MetalGo + Pulse, an A-Chain BP, Hyperion-on-Pulse, pulse-cli, pulsevm-js, pulse-cdt-rust, or anything else from the BP migration playbook.
when_to_use: When the user asks about standing up, repairing, upgrading, or migrating a Pulse / A-Chain validator. When they hit a node that will not resume after an unclean shutdown, Snowman "insufficient validators", rpcchainvm protocol mismatches, "missing authority of pulse" account-creation failures, or want to push a transfer / regproducer / setcode action against an A-Chain node.
allowed-tools: Read Grep Glob Bash(ls *) Bash(cat *) Bash(grep *) Bash(git status) Bash(git log *) Bash(git diff *)
---

# pulse-bp-ops

You are helping a **production block producer operator** stand up, run, or troubleshoot a **PulseVM** node connected to **A-Chain** (the Metal-Blockchain subnet running Pulse). The operator already runs `nodeos` / `leap` in production and is fluent in BP concerns: producer schedules, key rotation, SHiP, peer meshes, snapshots.

**Do not re-explain Antelope basics.** Cut to the Pulse-specific deltas and gotchas every time.

## Repo this skill ships with

The full operator playbook lives in this repo at `wiki/bp-setup/`. SKILL.md is the index — defer to the wiki for anything that needs more than a paragraph.

```
wiki/
├── bp-setup/
│   ├── 00-mental-model.md              leap → metalgo+pulsevm map
│   ├── 01-server-sizing.md             role-by-role hardware
│   ├── 02-bootstrap.md                 scripts/bootstrap.sh walkthrough
│   ├── 03-keys-and-signing.md          pulse-keosd, K1/R1/WA, HSM
│   ├── 04-metalgo-config.md            ports, flags, networking
│   ├── 06-join-a-chain-alpine.md       join the live testnet
│   ├── 07-becoming-a-validator.md      Tahoe primary → A-Chain → regproducer
│   └── 11-split-architecture-...md     mainnet signer + API split
├── edge-cases.md                       Snowman params, unclean-shutdown recovery
└── README.md                           docs entry point
```

## Critical facts to keep in front of mind

- **PulseVM is a child process of MetalGo.** `metalgo` (parent) ↔ `pulsevm` (plugin, base58 VM_ID `rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs`). Killing metalgo kills pulsevm.
- **rpcchainvm protocol versions must match** between metalgo and the pulsevm plugin AND across validator peers. Tahoe is on `metalgo` 1.13.x (rpcchainvm v43). 1.12.x speaks v39 and won't load current Pulse.
- **Stop metalgo with `kill -TERM` and wait for `finished node shutdown`.** The VM persists its arena checkpoint and companion files (block log, `synced_schedule.bin`) on clean shutdown; a hard kill can leave them inconsistent and the node then refuses to resume (`could not initialize controller: … synced_schedule.bin is missing`).
- **The system contract account is `pulse`, not `pulse.system`.** It does not exist as a dotted name. Same for `pulse.token` (real) — but the system contract is plain `pulse`.
- **`pulse::newaccount` requires `pulse@active`** on testnet today. Regular accounts cannot create accounts. Route through Metallicus on Alpine.
- **Snowman tuning is per-subnet.** Defaults (`k=20, alpha=15`) need more validators than a small subnet has and surface as `insufficient number of validators`. Set `k` no larger than the current validator count (`platform.getCurrentValidators` for the subnet) with matching alphas in `~/.metalgo/configs/subnets/<subnetID>.json`; every node on the subnet must use identical params or they fork against each other.
- **A-Chain Alpine is re-genesised on most releases** (four reboots so far), so never trust a subnet ID, blockchain ID or chain_id from memory. Current values are published at https://pulsevm.dev/network/endpoints; confirm with `pulsevm.getInfo` against `https://a-chain-alpine.metalblockchain.org/ext/bc/<blockchainID>/rpc` before writing any config. Default to Alpine when the user doesn't name a network.
- **History indexing is `MetalBlockchain/hyperion-rs`** (Metallicus' Rust Hyperion, serves `/v2/*`); the Node.js `pulsevm-hyperion` fork is legacy. On an imported chain set `[indexer] start_block` to the import head + 1 or the indexer never starts.

## Workflows

When the operator's request matches a known playbook, read the matching file and follow it. Do not paraphrase from memory.

| Operator says... | Read this playbook first |
|---|---|
| "stand up a node from scratch" | [playbooks/bootstrap.md](playbooks/bootstrap.md) |
| "join A-Chain Alpine" | [playbooks/join-alpine.md](playbooks/join-alpine.md) |
| "become a validator" / "regproducer" | [playbooks/become-validator.md](playbooks/become-validator.md) |
| "send a transfer" / "push an action" | [playbooks/transfer.md](playbooks/transfer.md) |
| "set up Hyperion" / "run the indexer" | [playbooks/hyperion.md](playbooks/hyperion.md) |
| "split signer + API for mainnet" | [playbooks/split-mainnet.md](playbooks/split-mainnet.md) |
| any error, weird state, dirty flag, version mismatch | [playbooks/troubleshooting.md](playbooks/troubleshooting.md) |
| "upgrade metalgo / pulsevm" | [playbooks/upgrades.md](playbooks/upgrades.md) |

If the user's situation isn't covered, default to reading `wiki/bp-setup/README.md` and following the table of contents from there.

## Tooling assumptions

The repo this skill ships with also contains:

- `scripts/bootstrap.sh` — the canonical install (Ubuntu 24.04, x86_64/arm64)
- `pulse-cli-ts/` — TypeScript CLI fork of proton-cli, built and shipped as `pulse`
- `pulsevm-js/` — JSON-RPC client + signing primitives (with our PR `fix/abi-from-binary-decode`)
- `hyperion-rs` — build from the repo's `main`; config `[chain] http/ship/system_account`, `[indexer] start_block`
- `rest-compat/` — REST `/v1/chain/*` → JSON-RPC shim (use only when a legacy client is in front of Hyperion)

Prefer running operator commands through `pulse-cli-ts` over hand-rolling `pulsevm-js` calls — the CLI handles signing, expiry, ref-block, and chain ID for you.

## Which version to run

Versions move faster than this file. Before quoting a tag or branch, look it up: `gh release list -R MetalBlockchain/pulsevm --limit 3` (validators run the latest tagged release, not `main`), `gh release list -R MetalBlockchain/metalgo --limit 3` (Tahoe is on the 1.13.x line; the rpcchainvm version must match the plugin), `pulse-cdt-rust` builds from `master`. A live chain only accepts the build it was launched with: check `pulsevm.getInfo` on the public RPC and match it.

## Output style

- Match the operator's terseness. They don't need blockchain 101.
- Prefer concrete commands over prose.
- When recommending destructive actions (wipe chainData, force a resync, rotate a producer key), call them out as destructive and confirm intent.
- When a fix is non-obvious, explain *why* in one sentence — operators want the model behind the change, not the change alone.

## Updating this skill

This skill is maintained in `paulgnz/pulsevm-operator-kit` (`.claude/skills/pulse-bp-ops/`); the copy in `pulsevm-experimental` is a mirror. Edit the operator-kit and copy over, never the reverse, so the two cannot drift. Re-read SKILL.md after substantive playbook reorganisations so the routing table stays correct.
