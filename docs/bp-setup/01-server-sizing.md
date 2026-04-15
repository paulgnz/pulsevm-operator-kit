# 01 — Server sizing

Specs for each role. Pick by role — don't run everything on one box in production.

## Roles

| Role | What it runs | Blast radius if it dies |
|---|---|---|
| **Producer node** | metalgo + pulsevm plugin; signing enabled | You miss block-building windows |
| **Full (non-producer) node** | metalgo + pulsevm plugin; signing disabled | A peer node drops; no production impact |
| **History / API node** | metalgo + pulsevm + pulsevm-hyperion (ES, Mongo, Rabbit, Redis) | Explorer / APIs degrade |
| **Dev / test box** | all of the above | Nothing, it's a dev box |

## Hardware recommendations

### Producer node (the one that signs)

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| CPU | 4 cores (3.0+ GHz) | **8 dedicated cores** (AMD EPYC / Xeon Gold) | WASM instruction-counter metering is deterministic, but producing a block in the 500 ms tick still wants real cores, not burstable vCPU |
| RAM | 8 GB | **16 GB** | Chainbase memory-maps state; headroom helps; add more as chain grows |
| Disk | 500 GB NVMe | **1 TB NVMe** (write-endurance rated) | State + metalgo DB + pulsevm DB; NVMe only, no SATA |
| Network | 100 Mbps | **1 Gbps symmetric, <50 ms RTT to majority of validators** | Snowman gossiping is chatty; high jitter hurts |
| Redundancy | — | hot standby with separate IP | Don't try to run two producers on one key — signing conflicts. Standby is warm-spare with chain state pre-synced |

### Full (non-producer) relay

| Resource | Recommended |
|---|---|
| CPU | 4–8 cores |
| RAM | 8–16 GB |
| Disk | 500 GB NVMe |
| Network | 1 Gbps |

Fine on a shared-vCPU plan — no real-time signing requirements.

### History / API node (Hyperion)

Elasticsearch is the whole story here.

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| CPU | 8 cores | **16 cores** | ES indexing, Hyperion workers (deser pool), API |
| RAM | 16 GB | **32–64 GB** | ES wants ~50% of RAM as heap, ~50% for page cache |
| Disk | 1 TB NVMe | **2–4 TB NVMe** for full XPR history | ES indices grow large; plan retention |
| Network | 1 Gbps | 1 Gbps | |

Separate from the producer node. Never run ES on a signing box.

### One-box testnet / rehearsal (what we're running today)

Single-machine doing everything: metalgo + pulsevm plugin + Hyperion (indexer + API + ES + Mongo + Rabbit + Redis) + rest-compat shim + nginx + TLS. Perfect for testnet, dev, rehearsal work. Hetzner CCX23 fits comfortably. See [11-split-architecture-for-mainnet.md](11-split-architecture-for-mainnet.md) for the production two-box pattern.

### Dev box (this is what we're building now)

Hetzner CCX23 is what you have: 4 AMD vCPU, 16 GB, 160 GB NVMe. Fine for:
- Single-node local devnet
- Contract build / deploy / test
- Small-scale Hyperion against a local devnet (a few hundred blocks)

Not enough for: indexing a real XPR snapshot, running a multi-node perf test.

## Cloud vs dedicated (for a real producer)

Short version: **go dedicated for production**, cloud is fine for dev/staging.

Dedicated wins for producers because:
- Determinism: zero hypervisor steal time on WASM-metered CPU.
- Disk IOPS ceilings: cloud plans throttle NVMe at surprising levels; dedicated does not.
- Cost: ~3–5× cheaper once the load is steady.

Decent dedicated options (early 2026 prices, check current):
- **Hetzner Robot / Auction**: AMD Ryzen 7000 boxes with 64–128 GB RAM + 2×NVMe ~€35–80/mo. Best price/perf on the planet.
- **OVH ScaleUp / Advance**: similar price band, better in some geos.
- **Equinix Metal**: overkill unless you need global anycast; $200+/mo.

Avoid for producers:
- AWS EC2 regular (expensive, throttled).
- DigitalOcean "shared CPU" droplets (noisy neighbours; billed CPU will be inconsistent).

## Network considerations

- **Public IPv4 + IPv6.** Metalgo negotiates peers over both.
- **Open inbound ports:** metalgo staking port (default 9651/tcp), RPC if public (9650/tcp), pulsevm state-history WS (default 9090/tcp, typically firewalled to local only).
- **No NAT for the producer's metalgo peering port** — get a proper static IP from your provider. Hetzner gives one per server.
- **Firewall (ufw/nftables):**
  - 9651/tcp — open (staking / peering)
  - 22/tcp — open (SSH; ideally restricted to bastion / VPN)
  - 9650/tcp — **closed publicly** for a producer; open only to Hyperion or API gateway
  - 9090/tcp — closed publicly; open to Hyperion internal IP only

## What the bootstrap expects

The [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) walkthrough assumes:
- Ubuntu 24.04 LTS (Noble Numbat) — CI is on this image; anything else is adventure
- root shell (cloud providers default to this)
- x86_64 or arm64
- Minimum 8 GB RAM, 40 GB free disk for the full install (Boost alone is ~1 GB post-clone)

If you're on Debian, most of it works, but LLVM repo URLs may need nudging. If you're on RHEL/Rocky, rewrite the apt sections for dnf.
