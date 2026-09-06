# Bootstrap a fresh Pulse node

Goal: from a blank Ubuntu 24.04 box to `metalgo` + `pulsevm` plugin running and reachable on JSON-RPC.

## One-shot path (recommended)

```bash
curl -sSL https://raw.githubusercontent.com/paulgnz/pulsevm-operator-kit/main/scripts/bootstrap.sh | bash
```

The script is idempotent. It lays down:

```
/opt/metalgo/metalgo                          # node daemon
/opt/pulsevm/plugins/<VM_ID>                  # the VM plugin
/opt/bin/pulse-cli  /opt/bin/pulse-keosd      # signing / CLI tools
~/.metalgo/                                    # data root
~/.metalgo/plugins/                            # symlinked from /opt
```

Detailed walkthrough: `wiki/bp-setup/02-bootstrap.md`.

## Pre-flight assumptions

- Ubuntu 24.04 LTS (Noble Numbat). Anything else is adventure — Debian mostly works (LLVM repo URLs need nudging); RHEL/Rocky needs `apt`→`dnf` rewrite.
- root or `sudo` access.
- 8 GB RAM, 40 GB free disk minimum; building from source needs LLVM 22 (`LLVM_SYS_221_PREFIX=/usr/lib/llvm-22`) — the node is pure Rust since v0.7.0, no Boost/C++ toolchain.
- Outbound internet for apt, GitHub, and crates.io.

## Verify after bootstrap

```bash
metalgo --version          # confirm 1.13.x-tahoe class
ls /opt/pulsevm/plugins/   # confirm rXcAFxZv... VM_ID file present
pulse-cli --version
```

Then start metalgo (no producer config yet — observer mode):

```bash
metalgo --config-file=~/.metalgo/config.json
```

In another shell:

```bash
curl -X POST -H 'content-type: application/json' --data '{
  "jsonrpc":"2.0","method":"info.getNodeID","params":{},"id":1
}' http://127.0.0.1:9650/ext/info | jq
```

Should return your NodeID. If it returns "context deadline exceeded" — the plugin failed to load, almost always rpcchainvm version mismatch. Check `~/.metalgo/logs/` for the gRPC handshake error.

## Next

→ `playbooks/join-alpine.md` to point the node at A-Chain Alpine.
