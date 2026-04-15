# 11 — Split architecture: signer vs API (for mainnet)

## When to split

| Environment | Recommended shape | Why |
|---|---|---|
| **Testnet / rehearsal / dev** | **One machine** — signer + API + Hyperion + nginx all on one box (what we're running now) | Low-stakes, cheap, fast to iterate. If it breaks you rebuild from `scripts/bootstrap.sh`. No blast radius. |
| **Mainnet / production** | **Two machines** — signer box + API box | Key isolation, independent failure domains, public API keeps serving during signer maintenance, standby promotion path |

Testnet-on-one-box is exactly what every XPR BP following this playbook should start with. The moment you're running a mainnet A-Chain producer with real stakes, switch to the two-box pattern below.

## The two-box shape

```
         ┌───────────────────── SIGNER NODE ──────────────────────┐
         │                                                        │
         │  metalgo (Tahoe primary + A-Chain subnet validator)    │
         │  └ pulsevm plugin                                      │
         │     · producer_name: <your-bp-account>                 │
         │     · producer_key: PVT_K1_... (locked down)           │
         │     · signs blocks when Snowman picks this NodeID      │
         │                                                        │
         │  ports open: 22/tcp (SSH, IP-allowlisted)              │
         │              9651/tcp (staking peer port, public)      │
         │  ports closed publicly: 9650 RPC, 9090 SHiP            │
         │                                                        │
         │  no Hyperion, no ES, no nginx, no pulse-cli on box     │
         └────────────────────────────────────────────────────────┘


         ┌──────────────────── API NODE ─────────────────────────┐
         │                                                        │
         │  metalgo (Tahoe observer + A-Chain subnet observer)    │
         │  └ pulsevm plugin                                      │
         │     · producer_name: observer                          │
         │     · producer_key: (throwaway testnet key; not        │
         │        needed for block production on an observer)     │
         │     · syncs the chain independently from the signer    │
         │       — does not depend on signer being reachable      │
         │                                                        │
         │  pulsevm state-history WS on 127.0.0.1:9090            │
         │     → read by local Hyperion indexer                   │
         │                                                        │
         │  Hyperion indexer + API (ES9 + Mongo + Rabbit + Redis) │
         │  nginx :443 → Hyperion :7000 (public, TLS)             │
         │                                                        │
         │  ports public: 22/tcp (IP-allowlisted), 443/tcp (api), │
         │                9651/tcp (regular metalgo peer)         │
         └────────────────────────────────────────────────────────┘
```

**Crucial design choice:** each box runs its own metalgo + pulsevm plugin. They do NOT share a SHiP stream over the network. Hyperion reads its own local plugin's stream. That way the API node is independent — the signer can reboot, be key-rotated, be replaced with a hot standby — and the public API keeps serving uninterrupted.

## What does NOT run on the signer box

| Component | Why kept off |
|---|---|
| Hyperion indexer + API | Public-facing surface; signer should have no public query API |
| Elasticsearch + Mongo + Rabbit + Redis | Memory hog; doesn't belong on a latency-sensitive producer |
| nginx | No public HTTP on a signer |
| pulse-cli / dev tooling | Attack surface; signer is append-only |
| REST compat shim | Serves clients; lives on API box |
| Transfer / heartbeat / activity scripts | All signing done with non-producer keys; move to API box or ops laptop |

Signer does one thing: receive BuildBlock from metalgo, sign with `producer_key`, return.

## What does NOT run on the API box

| Component | Why |
|---|---|
| The production `producer_key` | No private BP-signing material on a public-facing box |
| Any producer configuration (`producer_name: <yourBP>`) | Observer mode only — if Snowman somehow selected this NodeID it'd build a rejected block, but it won't because the NodeID isn't registered as a subnet validator |

## Sizing recommendations

| Role | CPU | RAM | Disk | Network |
|---|---|---|---|---|
| **Signer** | 4–8 dedicated cores (deterministic CPU metering benefits from real cores — no steal time) | 16–32 GB | 500 GB NVMe | 1 Gbps symmetric, <50 ms RTT to validator peers |
| **API / Hyperion** | 8–16 cores | **64 GB** (Elasticsearch is the glutton) | 1–2 TB NVMe (history grows) | 1 Gbps, close to your dapp users |

API box is much **bigger than signer** because Elasticsearch dominates. Counter-intuitive if you're coming from nodeos-only XPR ops where the producer was the heavier box.

Concrete options (early 2026 pricing, spot-check current):

- Hetzner dedicated auction `AX41-NVMe` class for signer — ~€35/mo for AMD Ryzen 7 + 64 GB + 2×NVMe.
- Hetzner dedicated auction `AX62-NVMe` / `AX101` class for API — ~€70–120/mo.
- Alternative: OVH SoYouStart / Advance; Equinix Metal; dedicated Vultr. Same tier.
- Cloud equivalents (Hetzner CCX53, etc.) work but are ~3× price for the same real CPU.

## Operational bonuses this shape unlocks

- **Key rotation / incident response:** can wipe and rebuild the API node in an afternoon without risking the signing key. Hyperion state is regenerable from the chain.
- **Standby signer (warm spare):** a third box that's a full chain node with the producer key imported, but `producer_name` set so Snowman doesn't pick it. Promote by editing one config line + restarting. Two-line procedure for emergency failover.
- **Different regions:** signer in a well-peered Avalanche-friendly DC (Ashburn, Frankfurt), API in a DC close to your dapp customers (Sydney, Singapore).
- **Different hosting providers:** signer on Hetzner, API on OVH. Correlated outages become impossible.
- **Public-API SLA:** API box failures don't threaten block production. Your BP uptime (which is what pays rewards on mainnet) is decoupled from dapp-facing availability.

## Gotchas to flag

### Version parity

**Both boxes' metalgo must be on the same version.** rpcchainvm protocol version must match between MetalGo and the PulseVM plugin, AND across validator peers. When upgrading:

1. Upgrade the API box first (lower blast radius — no signing).
2. Observe 24 h that it's stable.
3. Upgrade the signer box.

Never upgrade the signer first. Never let the two drift.

### Subnet config parity

**Both boxes must have the same `subnet-config.json`** (the Snowman `k / alphaPreference / alphaConfidence` tuning — see [edge-cases.md](../edge-cases.md)). Different params mean the two nodes can disagree on what's accepted, causing our own fork.

### Key handling

Producer signing key lives in `/etc/metalgo/chains/<blockchainID>/config.json` on the signer. Real production setup should replace this filesystem approach with:

- `pulse-keosd` / a dedicated signing daemon
- A hardware signer (Ledger / YubiHSM)
- A remote-signing service (rare but possible)

The filesystem approach is fine for testnet but is an audit finding on mainnet. Plan ahead.

If the API box ever needs to become the signer in emergency (warm-spare promotion), it needs access to the producer_key. **Keep that key in 1Password or a hardware signer, not on the API box filesystem permanently.** Copy it at promotion time, not before.

### Graceful shutdown

Everything in [edge-cases.md](../edge-cases.md) about Chainbase dirty-flag applies 2× on a split setup — you have two chain-state directories to protect. Always `kill -TERM`, wait for `finished node shutdown`, then do anything destructive. Rebuilding a mainnet signer chain state from the network takes hours; rebuilding API + Hyperion state takes days.

## Migration from single-box (what we have today) to split

When you're ready:

1. Provision the API box with `scripts/bootstrap.sh`.
2. Point its metalgo at the same subnet (`track-subnets`), keep `producer_name: observer`.
3. Let it sync a fresh copy of the chain (hours on mainnet).
4. Once it's caught up, stand up its Hyperion + nginx + TLS from scratch (same flow we used on the single-box, just now fresh on the API box).
5. DNS-cutover: point `a-chain.<your-domain>` from the signer's IP (current single-box IP) to the API box's IP.
6. Now the signer box is producer-only. Close ports 80/443 + 7000 + 9650 externally. Tighten ufw / firewall to SSH + 9651 only.
7. Rotate the producer key (via `pulse@updateauth`) since it was briefly exposed on a multi-role box. Optional but recommended.

Total wall clock: ~1 day counting DNS propagation.

## The one-box rule-of-thumb (testnet/dev)

For testnet or any dev-grade BP, one box is fine. What we're running now:

- Hetzner CCX23 (~€32/mo): 4 AMD dedicated vCPU, 16 GB, 160 GB NVMe
- metalgo + pulsevm + Hyperion + ES stack + nginx + rest-compat shim + heartbeat — all on one
- TLS via Let's Encrypt + certbot
- pm2 supervising 4 node processes; 4 docker containers
- Publicly exposed at `https://a-chain-testnet.protonnz.com`

This stays healthy for testnet-scale workloads (hundreds of blocks, tens of GB Hyperion indices). It's a perfect starter / rehearsal topology.

When the chain has real activity (tens of thousands of blocks, hundreds of GB indices, paying dapp users) — split. Before then — don't bother.
