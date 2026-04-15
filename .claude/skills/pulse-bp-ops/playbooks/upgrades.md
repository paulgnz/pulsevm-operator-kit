# Upgrading metalgo / pulsevm

## The cardinal rule

`metalgo` and `pulsevm` are **paired binaries**. Their rpcchainvm protocol version must match. You upgrade them together, never in isolation.

## When to upgrade

- A new tagged release on `MetalBlockchain/pulsevm` (currently latest: `v0.2.3`)
- A Tahoe-line metalgo bump (e.g. `1.13.5-tahoe` → `1.13.6-tahoe`)
- A coordinated network upgrade announcement

Don't chase `main` on either repo for a producer node. Watch tags.

## Audit before upgrading

```bash
cd ~/src/pulsevm && git fetch --tags && git tag --sort=-creatordate | head -5
cd ~/src/metalgo && git fetch --tags && git tag --sort=-creatordate | head -5
```

Read both repos' release notes for the rpcchainvm version line. They must agree.

## Single-box procedure

```bash
# 1. Stop cleanly
kill -TERM $(pgrep -x metalgo)
# wait for "finished node shutdown" in logs

# 2. Backup chainData (rsync, snapshot, whatever)
rsync -a ~/.metalgo/chainData/ /backup/chainData-$(date +%F)/

# 3. Rebuild both
cd ~/src/metalgo && git pull && ./scripts/build.sh
cd ~/src/pulsevm && git fetch --tags && git checkout v0.2.4 && cargo build --release  # or matching tag

# 4. Replace binaries
sudo cp metalgo/build/metalgo /opt/metalgo/
sudo cp pulsevm/target/release/<plugin-binary> /opt/pulsevm/plugins/<VM_ID>

# 5. Restart
metalgo --config-file=~/.metalgo/config.json
```

Watch logs for plugin handshake. If you see "context deadline exceeded", versions don't match.

## Split-architecture procedure

1. Upgrade **API box first** (lower blast radius).
2. Observe for 24h — chain sync, RPC behavior, Hyperion ingest.
3. Then upgrade signer box.
4. Never let the two drift across a release boundary.

## Rolling back

If the new version misbehaves:

1. Stop cleanly.
2. Restore prior binaries (you do keep them under `/opt/metalgo/metalgo.bak`, right?).
3. Restore chainData from your pre-upgrade backup (only if the new version touched the DB schema; it usually doesn't).
4. Restart.

A roll-back where the chain itself moved past your backup means you'll resync from peers — slow but correct.
