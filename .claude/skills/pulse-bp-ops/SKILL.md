---
name: pulse-bp-ops
description: Operate a PulseVM / A-Chain block producer node — bootstrap, key handling, joining the testnet, becoming a validator, regproducer, transfers, Hyperion stack, troubleshooting Chainbase / Snowman / rpcchainvm issues. Use whenever the user mentions PulseVM, A-Chain, MetalGo + Pulse, an A-Chain BP, Hyperion-on-Pulse, pulse-cli, pulsevm-js, pulse-cdt-rust, or anything else from the BP migration playbook.
when_to_use: When the user asks about standing up, repairing, upgrading, or migrating a Pulse / A-Chain validator. When they hit Chainbase dirty-flag errors, Snowman "insufficient validators", rpcchainvm protocol mismatches, "missing authority of pulse" account-creation failures, or want to push a transfer / regproducer / setcode action against an A-Chain node.
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
├── 00-migration-playbook.md            full XPR → A-Chain rehearsal log
├── edge-cases.md                       Chainbase, Snowman, mmap recovery
└── README.md                           wiki entry point
```

## Critical facts to keep in front of mind

- **PulseVM is a child process of MetalGo.** `metalgo` (parent) ↔ `pulsevm` (plugin, base58 VM_ID `rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs`). Killing metalgo kills pulsevm.
- **rpcchainvm protocol versions must match** between metalgo and the pulsevm plugin AND across validator peers. Tahoe is on `metalgo` 1.13.x (rpcchainvm v43). 1.12.x speaks v39 and won't load current Pulse.
- **Never `kill -9 metalgo`.** Chainbase's mmap dirty-flag check refuses to mount a database that wasn't shut down cleanly. Always `kill -TERM`, wait for `finished node shutdown` in logs, then act.
- **The system contract account is `pulse`, not `pulse.system`.** It does not exist as a dotted name. Same for `pulse.token` (real) — but the system contract is plain `pulse`.
- **`pulse::newaccount` requires `pulse@active`** on testnet today. Regular accounts cannot create accounts. Route through Metallicus on Alpine.
- **Snowman tuning is per-subnet.** Default `k=20, alpha=15` is impossible on a 6-validator subnet and surfaces as `insufficient number of validators`. Drop `~/.metalgo/configs/subnets/<subnetID>.json` with `k=5, alphaPreference=3, alphaConfidence=4`. Every node on the subnet must use the same params.
- **A-Chain Alpine** — subnet `zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW`, blockchainID `6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y`, chain_id `0d6f033e887fae475d641104b6e87762b6c869e87a101afeeb64d608ab376618`, RPC `https://a-chain-alpine.metalblockchain.org/ext/bc/6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y/rpc`. Default to this when the user doesn't name a network.
- **Hyperion is on `release/3.6`**, not `main` (main is the 4.0-beta track which doesn't yet support Pulse). Glenn confirmed.

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
- `pulsevm-hyperion/` — pinned to `release/3.6`
- `rest-compat/` — REST `/v1/chain/*` → JSON-RPC shim (use only when a legacy client is in front of Hyperion)

Prefer running operator commands through `pulse-cli-ts` over hand-rolling `pulsevm-js` calls — the CLI handles signing, expiry, ref-block, and chain ID for you.

## When unsure about which Metallicus repo branch to use

Glenn-verified branch pins (as of 2026-04-15):

| Repo | Branch / tag | Notes |
|---|---|---|
| `MetalBlockchain/metalgo` | `1.13.x-tahoe` line | rpcchainvm v43 |
| `MetalBlockchain/pulsevm` | tag `v0.2.3` | main is moving past — `getTableByScope`, install script, boot fix landed since |
| `MetalBlockchain/pulsevm-js` | `main` | wharfkit compat + `server_time` landed; rebase our PR if revisiting |
| `MetalBlockchain/pulsevm-hyperion` | `release/3.6` | NOT `main` (4.0-beta; not Pulse-ready) |
| `MetalBlockchain/pulse-cdt-rust` | `master` | `main` is empty |

If a question depends on freshness ("is this still right?"), run `git log origin/<branch> -5` against the relevant repo before answering.

## Output style

- Match the operator's terseness. They don't need blockchain 101.
- Prefer concrete commands over prose.
- When recommending destructive actions (wipe chainData, force a resync, rotate a producer key), call them out as destructive and confirm intent.
- When a fix is non-obvious, explain *why* in one sentence — operators want the model behind the change, not the change alone.

## Updating this skill

This skill lives under `.claude/skills/pulse-bp-ops/` in [paulgnz/pulsevm-experimental](https://github.com/paulgnz/pulsevm-experimental). Edit the playbooks as the chain matures. Re-read SKILL.md after substantive playbook reorganizations so the routing table stays correct.
