# 02 — Bootstrap script walkthrough

The canonical install is [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) at the project root. This page explains **what it does, why, and how to verify each piece individually** so you can skip or replace sections for your own stack.

It is designed to be:
- **Idempotent** — re-run any time; existing installs are detected and skipped.
- **Version-pinned** — every tool has an explicit version. Bump centrally in the `# pin everything` block.
- **Ubuntu 24.04 native** — matches CI. Adapt the apt sections for other distros.

## Invoke

```bash
# On the target Linux box, as root:
scp bootstrap.sh root@host:/root/
ssh root@host 'bash /root/bootstrap.sh 2>&1 | tee /var/log/pulsevm-bootstrap.stdout'

# Or, since the script redirects most output itself:
ssh root@host 'nohup bash /root/bootstrap.sh > /var/log/pulsevm-bootstrap.stdout 2>&1 < /dev/null &'
```

Total runtime on a Hetzner CCX23-class box: ~6–12 min (limited by apt mirrors and the Boost submodule clone).

## Sections, in order

### 1. Base apt packages

Installs the C/C++ toolchain + build utilities + networking tools:

```
build-essential cmake pkg-config ninja-build
libssl-dev libgmp-dev zlib1g-dev libcurl4-openssl-dev
libboost-all-dev libffi-dev zstd libzstd-dev
gcc-13 g++-13
git curl wget jq ripgrep fd-find tree
unzip tar xz-utils
tmux htop net-tools dnsutils iproute2
```

**Why gcc-13 specifically:** CI builds with `CXX=/usr/bin/g++-13`. Chainbase's C++ code relies on some g++-13 intrinsics and std extensions that older compilers don't ship.

**Verify:** `gcc --version` → `gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`.

### 2. LLVM 21

PulseVM's WASM runtime is Wasmer's LLVM compiler backend. The `llvm-sys` Rust crate that binds LLVM expects the shared libraries at a specific major version — CI pins **LLVM 21** via `LLVM_SYS_211_PREFIX=/usr/lib/llvm-21`.

> Note: the pulsevm README still says "LLVM 18." It's stale. See [edge-cases.md](../edge-cases.md).

Installed via apt.llvm.org's signed repo. Drops `/etc/profile.d/pulsevm-llvm.sh` to export `LLVM_SYS_211_PREFIX` and prepend `/usr/lib/llvm-21/bin` to PATH for the whole system.

**Verify:** `clang-21 --version` prints a version starting with `21.`.

### 3. Rust (stable) + wasm32 target

Installs rustup in non-interactive mode (`-y --default-toolchain stable --profile minimal`) and adds:

- `wasm32-unknown-unknown` target — used by `pulse-cdt-rust` contract builds
- `clippy`, `rustfmt`, `rust-src` components

Writes `/etc/profile.d/pulsevm-rust.sh` to put `$HOME/.cargo/bin` on PATH.

**Verify:**
```bash
rustc --version       # stable 1.94 or later
cargo --version
rustup target list --installed | grep wasm32
```

### 4. Go 1.22.8

Downloaded as a tarball (not apt, because Ubuntu's apt version lags). Installed to `/usr/local/go`.

`/etc/profile.d/pulsevm-go.sh` exports `PATH` and `GOPATH=$HOME/go`.

**Why 1.22.8:** metalgo v1.12.2 ships as a prebuilt binary so Go is optional for *running* it, but if you ever need to build metalgo from source, it pins `go 1.22.*` in its `go.mod`.

**Verify:** `go version` → `go version go1.22.8 linux/amd64`.

### 5. protoc 27.1

pulsevm_grpc's `build.rs` shells out to `protoc` to compile `.proto` files at build time. Required only if you rebuild PulseVM core from source. Pinned at 27.1 because that's what CI uses.

**Verify:** `protoc --version` → `libprotoc 27.1`.

### 6. Node.js 22 (NodeSource)

Needed for:
- `pulsevm-hyperion` (requires Node 22+)
- `pulsevm-js` (builds with Rollup)
- Any local dev script

Installed from NodeSource's deb repo (`setup_22.x`). Ships npm.

**Verify:** `node --version` → `v22.22.x`.

### 7. Docker + compose plugin

Required for the Hyperion stack (Elasticsearch 9, Mongo, RabbitMQ, Redis).

Installed from docker.com's official apt repo (not Ubuntu's `docker.io` package which is older). Includes `docker-compose-plugin` so `docker compose` (v2, space-separated) works.

**Verify:**
```bash
docker --version            # Docker 29.x
docker compose version
systemctl is-active docker  # active
```

### 8. gh CLI

Convenience for downloading release assets (`gh release download`), triaging issues, opening PRs. Some bootstrap operations could use it, though for reproducibility the script sticks to `wget` + fixed release URLs.

**Verify:** `gh --version`.

### 9. Source checkouts

Clones the four repos into `/root/pulsevm-experimental/`:
- `pulsevm` — VM core (Rust + C++ FFI). **Includes Boost as a git submodule**, adding ~1 GB and many minutes to the clone. See [edge-cases.md](../edge-cases.md).
- `pulse-cdt-rust` — Contract SDK.
- `pulsevm-hyperion` — History indexer.
- `pulsevm-js` — Client SDK.

Re-runs do `git fetch --tags --prune` instead of re-cloning.

### 10. Prebuilt binaries

Three artifacts downloaded and laid out:

```
/opt/metalgo/metalgo                       metalgo v1.12.2 (~75 MB)
/opt/pulsevm/plugins/<VM_ID>               pulsevm plugin v0.2.3 (~110 MB)
/opt/bin/metal-network-runner              MNR v1.9.0 (~44 MB)
/opt/bin/pulse-cli                         CLI tool (if the asset exists)
/opt/bin/pulse-keosd                       key daemon (if the asset exists)
```

`<VM_ID>` is the 32-byte base58 id `rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs`. **metalgo locates plugins by that exact filename** in the `--plugin-dir`, so renaming is not optional.

`/opt/metalgo/plugins/<VM_ID>` is a symlink to `/opt/pulsevm/plugins/<VM_ID>` so you can point `--plugin-dir` at either.

**Verify:**
```bash
ls -la /opt/bin /opt/metalgo /opt/pulsevm/plugins
/opt/metalgo/metalgo --version
/opt/bin/metal-network-runner --version
```

### 11. Version manifest

The last step writes `/opt/versions.txt` with every installed tool's version. Useful for:
- Confirming nothing got silently skipped
- Snapshotting the state before an upgrade
- Including in bug reports

**Verify:** `cat /opt/versions.txt`.

## Profile PATH

The script adds three files under `/etc/profile.d/`:

```
pulsevm-llvm.sh    — LLVM_SYS_211_PREFIX, PATH for clang-21
pulsevm-rust.sh    — $HOME/.cargo/bin on PATH
pulsevm-go.sh      — /usr/local/go/bin, $HOME/go/bin, GOPATH
pulsevm-paths.sh   — composite: /opt/bin, go, cargo, llvm — for login shells
```

These only load in **login shells**. If you `ssh host 'command'` (non-login), they don't run. Either use `ssh -t host 'bash -l -c "..."'` or refer to binaries by full path (`/opt/bin/metal-network-runner`, etc.).

## Re-running

Safe to re-run: every section is guarded by an "is it already installed" check. The only thing that re-fetches is the repo clones (via `git fetch`).

If you want to force a reinstall of a specific piece:
- Rust: `rustup self uninstall -y` then re-run
- Go: `rm -rf /usr/local/go` then re-run
- metalgo / pulsevm: delete the binary then re-run
- apt-installed: `apt purge <package>` then re-run

## Security notes for BPs

This script runs as root and installs into `/opt`. For a production signing node, you should:

1. **Create a dedicated service user**, e.g. `pulse`, and run everything under `systemd` units with `User=pulse`.
2. **Firewall 22/tcp** to a bastion or VPN CIDR only.
3. **Disable root SSH login** after the install (`PermitRootLogin no` in `/etc/ssh/sshd_config`).
4. **Don't leave `/root/pulsevm-experimental/` on the box** — source code is attack surface. Keep it on a dev machine.
5. **Signing keys live in `pulse-keosd`, not in environment variables.** See [03-keys-and-signing.md](03-keys-and-signing.md).

The dev box we just provisioned is fine with the defaults — this list is for the day you stand up a real producer node.
