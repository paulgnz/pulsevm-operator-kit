# Split-architecture for mainnet (signer + API)

Testnet runs everything on one box. Mainnet should split into two: a signer node (block production only) and an API node (Hyperion + public endpoints). Full doc: `wiki/bp-setup/11-split-architecture-for-mainnet.md`.

## Why split

- **Key isolation** — production producer key never lives on a public-facing box.
- **Independent failure domains** — API outages don't threaten block production (which is what pays rewards).
- **Standby promotion path** — warm spare can take over signer role with a config edit.

## Shape

```
SIGNER NODE                        API NODE
- metalgo + pulsevm                - metalgo + pulsevm (observer)
- producer_name + producer_key     - no producer config
- ports: 9651 (peer), 22 (SSH)     - ports: 443 (api), 9651, 22
- NO Hyperion, no nginx, no CLI    - Hyperion + ES + nginx + TLS
                                    - reads ITS OWN local SHiP, not the
                                      signer's — that's the design
```

**Both boxes run their own metalgo + pulsevm.** They do NOT share a SHiP stream over the network. Hyperion reads its local plugin. That way the signer can reboot, be key-rotated, be replaced — and the public API keeps serving.

## Sizing

| Role | CPU | RAM | Disk |
|---|---|---|---|
| Signer | 4–8 dedicated cores | 16–32 GB | 500 GB NVMe |
| API | 8–16 cores | **64 GB** (Elasticsearch) | 1–2 TB NVMe |

API is bigger than signer (counter-intuitive coming from leap). ES is the glutton.

## Three things to never get wrong

1. **Version parity.** Both boxes must run identical metalgo + pulsevm versions. Upgrade API first (lower blast radius), observe 24h, then signer.
2. **Subnet config parity.** Both `subnets/<subnetID>.json` must have identical Snowman params or you fork against yourself.
3. **Key handling.** On-disk `producer_key` is fine for testnet, an audit finding for mainnet. Use `pulse-keosd` or a hardware signer.

## Migration from one-box

1. Provision the API box with `scripts/bootstrap.sh`.
2. Set `track-subnets`, leave `producer_name` unset.
3. Let it sync (hours on mainnet).
4. Stand up Hyperion + nginx + TLS on it.
5. DNS-cutover from the single-box IP to the API box IP.
6. Lock down the signer box: close 80/443/7000/9650 externally, only 22 + 9651 open.
7. Rotate the producer key (`pulse@updateauth`) since it was briefly exposed on a multi-role box.

Total wall clock: ~1 day counting DNS propagation.
