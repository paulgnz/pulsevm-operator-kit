# BP Setup — running a PulseVM validator & dev node

This section is written for a working **XPR Network block producer operator** (you already run `leap`/`nodeos` in production and have opinions about key rotation, SHiP, snapshots, and peer meshes) who wants to stand up a PulseVM dev node today and will eventually run a PulseVM-based A-Chain validator.

It assumes deep Antelope/Leap operational knowledge. It will not re-explain block production, LIB, producer schedules, or why you should never co-locate your signing key with your SSH key.

Read order:

| # | Page | Purpose |
|---|---|---|
| 00 | [Mental model — leap → metalgo+pulsevm](00-mental-model.md) | What maps, what doesn't, what's new |
| 01 | [Server sizing](01-server-sizing.md) | Hardware / VM specs per role |
| 02 | [Bootstrap script walkthrough](02-bootstrap.md) | The canonical install — section by section |
| 03 | [Keys & signing](03-keys-and-signing.md) | `pulsevm-keosd`, key types, HSM options |
| 04 | [MetalGo config & flags](04-metalgo-config.md) | Node config, ports, networking |
| 05 | [PulseVM plugin](05-pulsevm-plugin.md) | VM_ID, plugin-dir, genesis, chain ID |
| 06 | [Local devnet](06-local-devnet.md) | Single-node and metal-network-runner multi-node |
| 07 | [Becoming a validator](07-becoming-a-validator.md) | The real lived sequence — Tahoe primary, A-Chain subnet add, regproducer, chain config, first block. Verified end-to-end on Alpine. |
| 11 | [Split architecture for mainnet](11-split-architecture-for-mainnet.md) | Testnet = one box. Mainnet = signer + API split. Shape, sizing, gotchas, migration path. |
| 08 | [Hyperion stack](08-hyperion.md) | Indexer + ES + Mongo + Rabbit + Redis + APIs |
| 09 | [Monitoring](09-monitoring.md) | Prometheus, Grafana, alerts, dashboards |
| 10 | [Upgrades](10-upgrades.md) | Release tracking, rolling upgrade procedure |
| 11 | [Backup & DR](11-backup-dr.md) | State backup, key rotation, disaster recovery |
| 12 | [Troubleshooting](12-troubleshooting.md) | Known issues + fixes |
| 13 | [Tips & tricks](13-tips-and-tricks.md) | Operator pearls |

## Quick-reference (for when you're deep in a shell and can't be reading prose)

```bash
# Paths the bootstrap lays down
/opt/metalgo/metalgo                          # the node daemon
/opt/pulsevm/plugins/<VM_ID>                  # the VM plugin
/opt/bin/metal-network-runner                 # local multi-node orchestrator
/opt/bin/pulse-cli  /opt/bin/pulse-keosd      # signing / CLI tools
/root/pulsevm-experimental/                    # source checkouts

# The magic VM_ID
rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs

# Service-ish things
~/.metalgo/                                    # metalgo data root (staking, db, configs)
~/.metalgo/plugins/                            # where metalgo actually looks (symlink from /opt)
~/.metalgo/staking/                            # staker.key, staker.crt — protect like BP keys
```

## Delta cheat-sheet — leap → PulseVM

| Leap thing | PulseVM equivalent |
|---|---|
| `nodeos` | `metalgo` + `pulsevm` plugin (two processes) |
| `cleos` | `pulsevm-js` over JSON-RPC, or `pulse-cli` where shipped |
| `keosd` | `pulse-keosd` (Rust rewrite) |
| `eosio.cdt` | `pulse-cdt-rust` |
| Hyperion | `pulsevm-hyperion` (thin fork) |
| Block producer signing key | Same — K1/R1/WA all supported, unchanged |
| `config.ini` producer block | Config goes via genesis + metalgo config JSON (no producer schedule) |
| 21-BP schedule | Gone. Snowman picks the building node per-block |
| `state-history_plugin` | Built in; WS on `WS_BIND` (default `:9090`) |
| `/v1/chain/*` REST | `pulsevm.*` JSON-RPC on metalgo RPC port |
| `eosio` system account | `pulse` |
| `eosio.token` | `pulse.token` (reference contract in `reference_contracts/`) |
| `$CHAIN/config.ini` | `~/.metalgo/configs/chains/<chainID>.json` per-subnet |
| `nodeos --snapshot` | Metal state-sync (when enabled) or cold sync |
| Snapshot .bin/.zst | Not yet — PulseVM cold-syncs today (see open questions) |

## The single most important fact

**PulseVM is a child process of MetalGo.** Your "BP node" runs two binaries: `metalgo` (parent) and `pulsevm` (plugin, named with a base58 VM_ID). Killing metalgo kills pulsevm. Monitoring must cover both processes.
