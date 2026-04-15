# pulsevm-operator-kit

A drop-in toolkit for running a [PulseVM](https://github.com/MetalBlockchain/pulsevm) / **A-Chain** node end-to-end on Linux. Bootstrap, configs, optional public landing page with TLS, agent-skill playbook, and operator reference docs in one place.

Targets the canonical Metallicus stack: `metalgo` 1.13.x-tahoe + `pulsevm` v0.2.x + `pulsevm-hyperion` `release/3.6`. Designed so a complete novice can curl-bash to a working node, and an experienced operator can one-line it for CI.

## Quick start

Fresh Ubuntu 24.04 box, root shell:

```bash
curl -sSL https://raw.githubusercontent.com/paulgnz/pulsevm-operator-kit/main/scripts/bootstrap.sh | bash
```

You'll get a profile menu. Pick one, answer 5–10 prompts, end up at a running node — optionally with a public TLS endpoint and an interactive landing page.

For a fully unattended install (CI / experienced operators):

```bash
bash bootstrap.sh \
  --profile testnet-onebox \
  --domain a-chain.example.com \
  --email ops@example.com \
  --producer-name yourbp \
  --producer-key-file /root/.keys/active.priv \
  --express
```

Full flag reference: `bash scripts/bootstrap.sh --help`.

## Profiles

| Profile | Build deps | Hyperion | nginx + TLS | Producer | For |
|---|---|---|---|---|---|
| `dev-onebox` | full | yes | no | no | Local devnet, contract dev |
| `testnet-onebox` | minimal | yes | yes | yes | Public testnet validator on one box |
| `mainnet-signer` | minimal | no | no | yes | Production producer, smallest surface |
| `mainnet-api` | minimal | yes | yes | no (observer) | Production API box |
| `relay` | minimal | no | no | no | Non-producing peer |

For mainnet, prefer the **signer + API split** (separate hosts) over `testnet-onebox`. See [`docs/bp-setup/11-split-architecture-for-mainnet.md`](docs/bp-setup/11-split-architecture-for-mainnet.md).

## What's in here

| Path | Purpose |
|---|---|
| [`scripts/bootstrap.sh`](scripts/bootstrap.sh) | The installer. Profile-driven, two-mode (guided / express), idempotent, ~760 lines, single file. |
| [`scripts/nginx-hyperion.conf`](scripts/nginx-hyperion.conf) | Reverse-proxy template — `/ext/*` → metalgo (with `/admin /keystore /auth` denied), `/v1/* /v2/*` and everything else → Hyperion. Substituted with your domain at install. |
| [`scripts/landing/index.html`](scripts/landing/index.html) | Interactive landing page template — live network status (auto-refreshes every 3 s), producer rotation strip, "▶ Try it" buttons that exercise the curl examples in-browser. Substituted with your domain + chain IDs at install. |
| [`docs/`](docs/) | Operator reference. Start at [`docs/README.md`](docs/README.md). Includes BP setup playbook, RPC reference, Antelope→Pulse delta, edge cases, glossary. |
| [`.claude/skills/pulse-bp-ops/`](.claude/skills/pulse-bp-ops/) | A Claude Code [agent skill](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) packaging the playbook + routing logic. Drop the repo on a machine using Claude Code and you get instant operator guidance. |
| [`hyperion/`](hyperion/) | docker-compose for the Hyperion ES + Mongo + Rabbit + Redis stack. `connections.json.example` shows the chain wiring; copy to `connections.json` and fill in. |

## Safety notes baked into the installer

- **Producer key never on the command line.** Pass via `--producer-key-file <path>`; the file is read once and the resulting per-chain config is `chmod 600`.
- **metalgo binds to 127.0.0.1 only.** Public exposure is exclusively through nginx with the sensitive `/ext/{admin,keystore,auth}` paths blocked at the proxy layer.
- **systemd unit uses `KillSignal=SIGTERM` + `TimeoutStopSec=120`** to give Chainbase time to flush. Always `systemctl stop metalgo` — never `kill -9` — or you'll trip the dirty-flag check on next start and have to resync.
- **Existing configs are detected and confirmed before overwriting.** Re-running with a different profile only adds what's missing.

## Network identity (A-Chain Alpine)

Pulse subnets have **four** identifiers, each addressing a different layer:

| ID | Used for |
|---|---|
| **Subnet ID** `zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW` | `track-subnets` in metalgo config |
| **Blockchain ID** `6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y` | URL paths: `/ext/bc/<id>/rpc`; per-chain config |
| **Chain ID** `0d6f033e887fae475d641104b6e87762b6c869e87a101afeeb64d608ab376618` | Mixed into every transaction signing digest |
| **Pulse VM ID** `rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs` | Plugin filename in `~/.metalgo/plugins/` |

Full explanation in [`docs/06-rpc-reference.md`](docs/06-rpc-reference.md) and on the deployed landing page.

## What `testnet-onebox` produces

A public TLS endpoint that exposes:
- The MetalGo node API at `/ext/*` (with `/admin /keystore /auth` blocked at the proxy)
- Hyperion REST + WS at `/v1/*`, `/v2/*`
- A landing page at `/` with **live network status** (auto-refreshes every 3 s), a **producer rotation strip** (visualizes Snowman pick distribution), and **"▶ Try it" buttons** that exercise the curl examples in-browser.

A live reference is at [`https://a-chain-testnet.protonnz.com`](https://a-chain-testnet.protonnz.com) — a community-operated testnet endpoint built with this kit.

## Companion repos

| Repo | Purpose |
|---|---|
| [`MetalBlockchain/pulsevm`](https://github.com/MetalBlockchain/pulsevm) | The runtime itself (Rust workspace; ships `pulse` CLI + `pulse-keosd` in its releases) |
| [`MetalBlockchain/metalgo`](https://github.com/MetalBlockchain/metalgo) | The MetalGo node binary that hosts Pulse as a subnet plugin |
| [`MetalBlockchain/pulsevm-js`](https://github.com/MetalBlockchain/pulsevm-js) | TypeScript JSON-RPC client + signing primitives |
| [`MetalBlockchain/pulsevm-hyperion`](https://github.com/MetalBlockchain/pulsevm-hyperion) | History indexer (use `release/3.6`) |
| [`MetalBlockchain/pulse-cdt-rust`](https://github.com/MetalBlockchain/pulse-cdt-rust) | Smart-contract toolchain (Rust → wasm32) |

## Contributing

Bug reports, pull requests, and operator pearls welcome. Please test on a throwaway box (`dev-onebox` profile) before opening a PR that touches the installer or nginx config.

## License

[MIT](LICENSE).
