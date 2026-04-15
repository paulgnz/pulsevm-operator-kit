#!/usr/bin/env bash
# =============================================================================
# PulseVM / A-Chain BP bootstrap
# =============================================================================
# Idempotent. Safe to re-run. Two modes for two audiences:
#
#   GUIDED (default)    — prompts at each decision point with safe defaults
#                         and tips. Suitable for a first-time operator.
#
#   EXPRESS             — no prompts; takes everything from flags / env.
#                         Suitable for CI or operators who know what they
#                         want. Add --express (alias --non-interactive).
#
# Profiles
# --------
#   dev-onebox          Local devnet — build toolchain + MNR + Hyperion.
#   testnet-onebox      Public testnet validator on one box.
#   mainnet-signer      Production producer-only. Smallest surface.
#   mainnet-api         Production observer + Hyperion + nginx + TLS.
#   relay               Non-producing full node, peer-mesh contributor.
#
# Examples
# --------
#   curl -sSL .../bootstrap.sh | bash                              # guided menu
#   PROFILE=mainnet-signer bash bootstrap.sh                       # guided, profile preset
#   bash bootstrap.sh --profile testnet-onebox \                   # express, fully wired
#                     --domain a-chain.example.com \
#                     --email ops@example.com \
#                     --producer-name yourbp \
#                     --producer-key-file /root/.protonnz/active.priv \
#                     --express
#   bash bootstrap.sh --profile mainnet-signer --dry-run           # show plan, exit
#
# After bootstrap (any mode), the wizard will:
#   1. Generate metalgo + subnet config
#   2. (producer profiles) write per-chain producer config — key handled
#      via file path or pulse-keosd, never on the command line
#   3. (nginx-enabled profiles) deploy the landing page + nginx config
#      with your domain substituted, optionally run certbot for TLS
#   4. Install systemd unit for metalgo with proper SIGTERM handling
#   5. Print a summary with the exact start / watch commands
#
# Tested: Ubuntu 24.04 LTS, x86_64 / arm64, root shell.
# =============================================================================

set -euo pipefail

# ---------- pinned versions --------------------------------------------------
LLVM_VER=21
GO_VER=1.22.8
NODE_MAJOR=22
PROTOC_VER=27.1
RUST_CHANNEL=stable
PULSEVM_VER=v0.2.3            # rpcchainvm v43
METALGO_VER=v1.13.5-tahoe     # rpcchainvm v43 — MUST match pulsevm
MNR_VER=v1.9.0
VM_ID="rXcAFxZvio99epp6TzEwYfexCfPAbJuBTMsjUUoiT7PkVykNs"

# Known networks (built-in)
ALPINE_SUBNET_ID="zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW"
ALPINE_BLOCKCHAIN_ID="6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y"
ALPINE_CHAIN_ID="0d6f033e887fae475d641104b6e87762b6c869e87a101afeeb64d608ab376618"

METALGO_DIR=/opt/metalgo
PULSEVM_DIR=/opt/pulsevm
PLUGIN_DIR="${PULSEVM_DIR}/plugins"
BIN_DIR=/opt/bin
SRC_DIR=/root/pulsevm-src
LOG=/var/log/pulsevm-bootstrap.log
METALGO_HOME="${HOME}/.metalgo"

# ---------- arg parsing ------------------------------------------------------
PROFILE="${PROFILE:-}"
NON_INTERACTIVE=0
DRY_RUN=0
OPT_BUILD="${OPT_BUILD:-0}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
NETWORK="${NETWORK:-}"
PRODUCER_NAME="${PRODUCER_NAME:-}"
PRODUCER_KEY_FILE="${PRODUCER_KEY_FILE:-}"
SKIP_NGINX=0
SKIP_TLS=0
SKIP_SYSTEMD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)              PROFILE="$2"; shift 2 ;;
    --profile=*)            PROFILE="${1#*=}"; shift ;;
    --domain)               DOMAIN="$2"; shift 2 ;;
    --domain=*)             DOMAIN="${1#*=}"; shift ;;
    --email)                EMAIL="$2"; shift 2 ;;
    --email=*)              EMAIL="${1#*=}"; shift ;;
    --network)              NETWORK="$2"; shift 2 ;;
    --network=*)            NETWORK="${1#*=}"; shift ;;
    --producer-name)        PRODUCER_NAME="$2"; shift 2 ;;
    --producer-name=*)      PRODUCER_NAME="${1#*=}"; shift ;;
    --producer-key-file)    PRODUCER_KEY_FILE="$2"; shift 2 ;;
    --producer-key-file=*)  PRODUCER_KEY_FILE="${1#*=}"; shift ;;
    --skip-nginx)           SKIP_NGINX=1; shift ;;
    --skip-tls)             SKIP_TLS=1; shift ;;
    --skip-systemd)         SKIP_SYSTEMD=1; shift ;;
    --non-interactive|--express) NON_INTERACTIVE=1; shift ;;
    --opt-build)            OPT_BUILD=1; shift ;;
    --dry-run)              DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^[^#]/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ---------- output helpers ---------------------------------------------------
log()    { printf '\n\e[1;36m==> %s\e[0m\n'  "$*" | tee -a "$LOG"; }
step()   { printf '\n\e[1;35m▶ %s\e[0m\n'    "$*"; }
tip()    { printf '\e[1;33m  💡 %s\e[0m\n'   "$*"; }
warn()   { printf '\e[1;31m  ⚠ %s\e[0m\n'    "$*"; }
ok()     { printf '\e[1;32m  ✓ %s\e[0m\n'    "$*"; }

prompt() {
  # prompt "question" "default" VARNAME
  local msg="$1" default="${2:-}" varname="$3" val
  if [ "$NON_INTERACTIVE" = "1" ]; then
    eval "$varname=\"\${$varname:-\$default}\""
    return
  fi
  if [ -n "$default" ]; then
    read -rp "  $msg [$default]: " val
    val="${val:-$default}"
  else
    read -rp "  $msg: " val
  fi
  eval "$varname=\"\$val\""
}

confirm() {
  # confirm "question" "y|n" — returns 0 if yes
  local msg="$1" default="${2:-y}" ans hint
  if [ "$NON_INTERACTIVE" = "1" ]; then
    [ "$default" = "y" ]; return
  fi
  hint=$([ "$default" = "y" ] && echo "Y/n" || echo "y/N")
  read -rp "  $msg [$hint] " ans
  ans="${ans:-$default}"
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

require_express() {
  # In express mode, error out if a needed value wasn't provided.
  local what="$1" varname="$2"
  if [ "$NON_INTERACTIVE" = "1" ] && [ -z "${!varname:-}" ]; then
    echo "Error: --$what is required in express mode" >&2; exit 2
  fi
}

# ---------- profile selection ------------------------------------------------
PROFILES=(dev-onebox testnet-onebox mainnet-signer mainnet-api relay)

valid_profile() {
  local p="$1"; for x in "${PROFILES[@]}"; do [ "$x" = "$p" ] && return 0; done; return 1
}

if [ -z "$PROFILE" ]; then
  if [ "$NON_INTERACTIVE" = "1" ] || [ ! -t 0 ]; then
    echo "Error: PROFILE not set and stdin is not a TTY." >&2
    echo "Pass --profile <name> or set PROFILE=." >&2
    echo "Available: ${PROFILES[*]}" >&2
    exit 2
  fi
  printf '\n\e[1;36mPick an install profile:\e[0m\n\n'
  PS3=$'\n> '
  select choice in "${PROFILES[@]}"; do
    [ -n "${choice:-}" ] && PROFILE="$choice" && break
  done
fi

if ! valid_profile "$PROFILE"; then
  echo "invalid profile: $PROFILE (valid: ${PROFILES[*]})" >&2; exit 2
fi

# ---------- profile → toggles ------------------------------------------------
INSTALL_BUILD=0; INSTALL_NODE=0; INSTALL_DOCKER=0; INSTALL_GH=0
INSTALL_SOURCE=0; INSTALL_MNR=0; INSTALL_HYPERION=0; INSTALL_NGINX=0
ROLE_PRODUCER=0; ROLE_OBSERVER=0

case "$PROFILE" in
  dev-onebox)
    INSTALL_BUILD=1; INSTALL_NODE=1; INSTALL_DOCKER=1; INSTALL_GH=1
    INSTALL_SOURCE=1; INSTALL_MNR=1; INSTALL_HYPERION=1; INSTALL_NGINX=0
    ROLE_OBSERVER=1 ;;
  testnet-onebox)
    INSTALL_BUILD=$OPT_BUILD; INSTALL_NODE=1; INSTALL_DOCKER=1; INSTALL_GH=1
    INSTALL_SOURCE=1; INSTALL_HYPERION=1; INSTALL_NGINX=1
    ROLE_PRODUCER=1 ;;
  mainnet-signer)
    INSTALL_BUILD=$OPT_BUILD
    ROLE_PRODUCER=1 ;;
  mainnet-api)
    INSTALL_BUILD=$OPT_BUILD; INSTALL_NODE=1; INSTALL_DOCKER=1; INSTALL_GH=1
    INSTALL_SOURCE=1; INSTALL_HYPERION=1; INSTALL_NGINX=1
    ROLE_OBSERVER=1 ;;
  relay)
    ROLE_OBSERVER=1 ;;
esac

# Honor --skip-* opt-outs
[ "$SKIP_NGINX" = "1" ] && INSTALL_NGINX=0

# ---------- arch detection ---------------------------------------------------
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
  x86_64|amd64)   ARCH=amd64 ;;
  aarch64|arm64)  ARCH=arm64 ;;
  *) echo "unsupported arch $ARCH_UNAME" >&2; exit 1 ;;
esac

# ---------- show plan + confirm ---------------------------------------------
yn() { [ "$1" = "1" ] && echo yes || echo no; }
cat <<EOF

================================================================
  Bootstrap plan
================================================================
  Profile:               $PROFILE
  Mode:                  $([ "$NON_INTERACTIVE" = "1" ] && echo "express (no prompts)" || echo "guided (will prompt)")
  Arch:                  $ARCH
  Build toolchain:       $(yn $INSTALL_BUILD)   (LLVM 21, Rust+wasm32, Go, protoc, Boost)
  Node.js 22:            $(yn $INSTALL_NODE)
  Docker + compose:      $(yn $INSTALL_DOCKER)
  gh CLI:                $(yn $INSTALL_GH)
  Source checkouts:      $(yn $INSTALL_SOURCE)
  metal-network-runner:  $(yn $INSTALL_MNR)
  Hyperion stack:        $(yn $INSTALL_HYPERION)
  nginx + landing:       $(yn $INSTALL_NGINX)
  Role:                  $([ $ROLE_PRODUCER = 1 ] && echo "producer (signs blocks)" || echo "observer (read-only)")

  Always installs:       metalgo $METALGO_VER, pulsevm $PULSEVM_VER plugin,
                         pulse + pulse-keosd from pulsevm release
================================================================
EOF

if [ "$DRY_RUN" = "1" ]; then echo "Dry run — exiting."; exit 0; fi

if [ "$NON_INTERACTIVE" != "1" ] && [ -t 0 ]; then
  read -rp "Proceed? [Y/n] " ans
  case "${ans:-y}" in y|Y|yes|YES) ;; *) echo "aborted"; exit 0 ;; esac
fi

# ---------- common setup -----------------------------------------------------
mkdir -p "$METALGO_DIR" "$PULSEVM_DIR" "$PLUGIN_DIR" "$BIN_DIR" "$SRC_DIR"
mkdir -p "$METALGO_HOME/configs/chains" "$METALGO_HOME/configs/subnets"
export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# Phase A: install packages + binaries
# ============================================================================

# ---------- 1. base system (always) -----------------------------------------
log "1/N apt base packages"
apt-get update -y >>"$LOG" 2>&1
apt-get install -y >>"$LOG" 2>&1 \
    git curl wget jq ripgrep \
    unzip tar xz-utils \
    ca-certificates software-properties-common lsb-release gnupg \
    tmux htop net-tools dnsutils iproute2

# ---------- 2. build toolchain (conditional) --------------------------------
if [ "$INSTALL_BUILD" = "1" ]; then
  log "2/N apt build toolchain + LLVM ${LLVM_VER} + Rust + Go + protoc"
  apt-get install -y >>"$LOG" 2>&1 \
      build-essential cmake pkg-config ninja-build \
      libssl-dev libgmp-dev zlib1g-dev libcurl4-openssl-dev \
      libboost-all-dev libffi-dev zstd libzstd-dev \
      gcc-13 g++-13
  update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100 >>"$LOG" 2>&1 || true
  update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100 >>"$LOG" 2>&1 || true

  if ! dpkg -s llvm-${LLVM_VER}-dev >/dev/null 2>&1; then
      install -d /usr/share/keyrings
      curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
          | gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg
      cat >/etc/apt/sources.list.d/llvm.list <<EOF
deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-${LLVM_VER} main
EOF
      apt-get update -y >>"$LOG" 2>&1
      apt-get install -y >>"$LOG" 2>&1 \
          llvm-${LLVM_VER} llvm-${LLVM_VER}-dev libpolly-${LLVM_VER}-dev \
          clang-${LLVM_VER} lld-${LLVM_VER}
  fi
  cat >/etc/profile.d/pulsevm-llvm.sh <<EOF
export LLVM_SYS_${LLVM_VER}1_PREFIX=/usr/lib/llvm-${LLVM_VER}
export PATH="/usr/lib/llvm-${LLVM_VER}/bin:\$PATH"
EOF

  if ! command -v rustc >/dev/null 2>&1; then
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
          | sh -s -- -y --default-toolchain "${RUST_CHANNEL}" --profile minimal >>"$LOG" 2>&1
  fi
  source "$HOME/.cargo/env"
  rustup target add wasm32-unknown-unknown >>"$LOG" 2>&1
  rustup component add clippy rustfmt rust-src >>"$LOG" 2>&1
  cat >/etc/profile.d/pulsevm-rust.sh <<'EOF'
export PATH="$HOME/.cargo/bin:$PATH"
EOF

  if ! command -v go >/dev/null 2>&1 || ! go version | grep -q "go${GO_VER}"; then
      wget -qO /tmp/go.tgz "https://go.dev/dl/go${GO_VER}.linux-${ARCH}.tar.gz"
      rm -rf /usr/local/go
      tar -C /usr/local -xzf /tmp/go.tgz
      rm /tmp/go.tgz
  fi
  cat >/etc/profile.d/pulsevm-go.sh <<'EOF'
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
export GOPATH="$HOME/go"
EOF

  if ! command -v protoc >/dev/null 2>&1 || ! protoc --version | grep -q "${PROTOC_VER}"; then
      PROTOC_ARCH=$([ "$ARCH" = amd64 ] && echo x86_64 || echo aarch_64)
      wget -qO /tmp/protoc.zip \
          "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VER}/protoc-${PROTOC_VER}-linux-${PROTOC_ARCH}.zip"
      unzip -oq /tmp/protoc.zip -d /usr/local
      rm /tmp/protoc.zip
  fi
fi

# ---------- 3. Node.js (conditional) ----------------------------------------
if [ "$INSTALL_NODE" = "1" ]; then
  log "3/N Node.js ${NODE_MAJOR}"
  if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q "^v${NODE_MAJOR}\."; then
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >>"$LOG" 2>&1
      apt-get install -y nodejs >>"$LOG" 2>&1
  fi
fi

# ---------- 4. Docker (conditional) -----------------------------------------
if [ "$INSTALL_DOCKER" = "1" ]; then
  log "4/N Docker"
  if ! command -v docker >/dev/null 2>&1; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
          | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
          >/etc/apt/sources.list.d/docker.list
      apt-get update -y >>"$LOG" 2>&1
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>"$LOG" 2>&1
      systemctl enable --now docker >>"$LOG" 2>&1
  fi
fi

# ---------- 5. gh CLI (conditional) -----------------------------------------
if [ "$INSTALL_GH" = "1" ]; then
  log "5/N gh CLI"
  if ! command -v gh >/dev/null 2>&1; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          >/etc/apt/sources.list.d/github-cli.list
      apt-get update -y >>"$LOG" 2>&1
      apt-get install -y gh >>"$LOG" 2>&1
  fi
fi

# ---------- 6. source checkouts (conditional) -------------------------------
if [ "$INSTALL_SOURCE" = "1" ]; then
  log "6/N clone MetalBlockchain repos into ${SRC_DIR}"
  cd "$SRC_DIR"
  for r in pulsevm pulse-cdt-rust pulsevm-hyperion pulsevm-js; do
      if [ -d "$r/.git" ]; then
          git -C "$r" fetch --tags --prune >>"$LOG" 2>&1 || true
      else
          git clone --recurse-submodules "https://github.com/MetalBlockchain/${r}.git" >>"$LOG" 2>&1
      fi
  done
  if [ -d pulsevm-hyperion/.git ]; then
      git -C pulsevm-hyperion fetch origin release/3.6:refs/remotes/origin/release/3.6 >>"$LOG" 2>&1 || true
      git -C pulsevm-hyperion checkout release/3.6 >>"$LOG" 2>&1 || true
  fi
fi

# ---------- 7. metalgo + pulsevm binaries (always) --------------------------
log "7/N metalgo ${METALGO_VER}"
if [ ! -x "${METALGO_DIR}/metalgo" ] || ! "${METALGO_DIR}/metalgo" --version 2>/dev/null | grep -q "${METALGO_VER#v}"; then
    METALGO_ASSET="metalgo-linux-${ARCH}-${METALGO_VER}.tar.gz"
    wget -qO /tmp/metalgo.tgz \
        "https://github.com/MetalBlockchain/metalgo/releases/download/${METALGO_VER}/${METALGO_ASSET}"
    rm -rf /tmp/metalgo-extract && mkdir -p /tmp/metalgo-extract
    tar -xzf /tmp/metalgo.tgz -C /tmp/metalgo-extract
    rm /tmp/metalgo.tgz
    EXTRACTED=$(find /tmp/metalgo-extract -maxdepth 1 -mindepth 1 -type d | head -1)
    cp -r "${EXTRACTED}/." "${METALGO_DIR}/"
fi
ln -sfn "${METALGO_DIR}/metalgo" "${BIN_DIR}/metalgo"

log "7/N pulsevm ${PULSEVM_VER}"
if [ ! -x "${PLUGIN_DIR}/${VM_ID}" ]; then
    wget -qO /tmp/pulsevm.tgz \
        "https://github.com/MetalBlockchain/pulsevm/releases/download/${PULSEVM_VER}/pulsevm-linux-${ARCH}.tar.gz"
    rm -rf /tmp/pulsevm-extract && mkdir -p /tmp/pulsevm-extract
    tar -xzf /tmp/pulsevm.tgz -C /tmp/pulsevm-extract
    rm /tmp/pulsevm.tgz
    PULSEVM_BIN=$(find /tmp/pulsevm-extract -maxdepth 2 -type f -name 'pulsevm' | head -1)
    install -m 0755 "$PULSEVM_BIN" "${PLUGIN_DIR}/${VM_ID}"
    mkdir -p "${METALGO_DIR}/plugins"
    ln -sfn "${PLUGIN_DIR}/${VM_ID}" "${METALGO_DIR}/plugins/${VM_ID}"
fi

log "7/N pulse + pulse-keosd"
for asset in pulse-cli pulse-keosd; do
    case "$asset" in
        pulse-cli)   target="${BIN_DIR}/pulse" ;;
        pulse-keosd) target="${BIN_DIR}/pulse-keosd" ;;
    esac
    if [ ! -x "$target" ]; then
        url="https://github.com/MetalBlockchain/pulsevm/releases/download/${PULSEVM_VER}/${asset}-linux-${ARCH}.tar.gz"
        if wget -q --spider "$url"; then
            wget -qO /tmp/${asset}.tgz "$url"
            rm -rf /tmp/${asset}-extract && mkdir /tmp/${asset}-extract
            tar -xzf /tmp/${asset}.tgz -C /tmp/${asset}-extract
            BIN=$(find /tmp/${asset}-extract -maxdepth 2 -type f -executable | head -1)
            [ -n "$BIN" ] && install -m 0755 "$BIN" "$target"
            rm -f /tmp/${asset}.tgz
        fi
    fi
done
[ -x "${BIN_DIR}/pulse" ] && ln -sfn "${BIN_DIR}/pulse" "${BIN_DIR}/pulse-cli"

# ---------- 8. metal-network-runner (conditional) ---------------------------
if [ "$INSTALL_MNR" = "1" ]; then
    log "8/N metal-network-runner ${MNR_VER}"
    if [ ! -x "${BIN_DIR}/metal-network-runner" ]; then
        MNR_ASSET="metal-network-runner_${MNR_VER#v}_linux_${ARCH}.tar.gz"
        wget -qO /tmp/mnr.tgz \
            "https://github.com/MetalBlockchain/metal-network-runner/releases/download/${MNR_VER}/${MNR_ASSET}"
        rm -rf /tmp/mnr-extract && mkdir /tmp/mnr-extract
        tar -xzf /tmp/mnr.tgz -C /tmp/mnr-extract
        rm /tmp/mnr.tgz
        MNR_BIN=$(find /tmp/mnr-extract -maxdepth 2 -type f -name 'metal-network-runner' | head -1)
        install -m 0755 "$MNR_BIN" "${BIN_DIR}/metal-network-runner"
    fi
fi

# ---------- 9. Hyperion source (conditional) --------------------------------
if [ "$INSTALL_HYPERION" = "1" ]; then
    log "9/N Hyperion source (release/3.6)"
    HYPERION_DIR=/opt/hyperion
    mkdir -p "$HYPERION_DIR"
    if [ ! -d "$HYPERION_DIR/pulsevm-hyperion/.git" ]; then
        git clone -b release/3.6 https://github.com/MetalBlockchain/pulsevm-hyperion "$HYPERION_DIR/pulsevm-hyperion" >>"$LOG" 2>&1
    else
        git -C "$HYPERION_DIR/pulsevm-hyperion" fetch origin release/3.6 >>"$LOG" 2>&1 || true
        git -C "$HYPERION_DIR/pulsevm-hyperion" checkout release/3.6 >>"$LOG" 2>&1 || true
    fi
fi

# ---------- 10. PATH for root -----------------------------------------------
PATHLINES="export PATH=\"${BIN_DIR}:\$PATH\""
[ "$INSTALL_BUILD" = "1" ] && PATHLINES="${PATHLINES}
export PATH=\"/usr/local/go/bin:\$HOME/.cargo/bin:\$HOME/go/bin:/usr/lib/llvm-${LLVM_VER}/bin:\$PATH\"
export LLVM_SYS_${LLVM_VER}1_PREFIX=/usr/lib/llvm-${LLVM_VER}
export GOPATH=\"\$HOME/go\""
echo "$PATHLINES" >/etc/profile.d/pulsevm-paths.sh
export PATH="${BIN_DIR}:${PATH}"

# ============================================================================
# Phase B: configuration wizard
# ============================================================================

step "Configuration wizard — let's wire your node"

# ---------- B1. network ------------------------------------------------------
[ -z "$NETWORK" ] && NETWORK="alpine"
if [ "$NON_INTERACTIVE" != "1" ] && [ -t 0 ]; then
  prompt "Pulse network (alpine|mainnet|custom)" "$NETWORK" NETWORK
fi
case "$NETWORK" in
  alpine)
    SUBNET_ID="$ALPINE_SUBNET_ID"
    BLOCKCHAIN_ID="$ALPINE_BLOCKCHAIN_ID"
    CHAIN_ID="$ALPINE_CHAIN_ID"
    ok "A-Chain Alpine selected"
    tip "~6 active validators today; the public RPC is at https://a-chain-alpine.metalblockchain.org"
    ;;
  mainnet)
    warn "Mainnet IDs not yet finalized — falling back to Alpine"
    SUBNET_ID="$ALPINE_SUBNET_ID"; BLOCKCHAIN_ID="$ALPINE_BLOCKCHAIN_ID"; CHAIN_ID="$ALPINE_CHAIN_ID"
    NETWORK="alpine"
    ;;
  custom)
    require_express "subnet-id"     SUBNET_ID
    require_express "blockchain-id" BLOCKCHAIN_ID
    require_express "chain-id"      CHAIN_ID
    [ "$NON_INTERACTIVE" != "1" ] && {
      prompt "Subnet ID" "" SUBNET_ID
      prompt "Blockchain ID" "" BLOCKCHAIN_ID
      prompt "Chain ID" "" CHAIN_ID
    }
    ;;
  *) echo "unknown network: $NETWORK" >&2; exit 2 ;;
esac

# ---------- B2. metalgo config + Snowman tuning ------------------------------
step "Generate metalgo config"

CONFIG_FILE="$METALGO_HOME/config.json"
if [ -f "$CONFIG_FILE" ] && ! confirm "$CONFIG_FILE exists. Overwrite?" n; then
  ok "Keeping existing $CONFIG_FILE"
else
  cat >"$CONFIG_FILE" <<EOF
{
  "track-subnets": "$SUBNET_ID",
  "http-host": "127.0.0.1",
  "log-level": "info"
}
EOF
  ok "Wrote $CONFIG_FILE"
  tip "http-host is 127.0.0.1 — only nginx (next step) can hit metalgo. Public exposure goes through nginx with the /ext/{admin,keystore,auth} paths denied."
fi

SUBNET_CFG="$METALGO_HOME/configs/subnets/${SUBNET_ID}.json"
cat >"$SUBNET_CFG" <<'EOF'
{
  "consensusParameters": {
    "k": 5,
    "alphaPreference": 3,
    "alphaConfidence": 4
  }
}
EOF
ok "Wrote $SUBNET_CFG"
tip "Snowman tuned to k=5/α=3 — required on small subnets (<20 validators), fatal mismatch if peers use different values."

# ---------- B3. producer config (producer profiles only) ---------------------
if [ "$ROLE_PRODUCER" = "1" ]; then
  step "Producer configuration"
  warn "If this is a mainnet box, on-disk private keys are an audit finding. Prefer pulse-keosd or a hardware signer for production."

  if [ -z "$PRODUCER_NAME" ] && [ "$NON_INTERACTIVE" != "1" ] && [ -t 0 ]; then
    prompt "Your BP account name (or blank to skip producer setup)" "" PRODUCER_NAME
  fi

  if [ -n "$PRODUCER_NAME" ]; then
    CHAIN_CFG="$METALGO_HOME/configs/chains/${BLOCKCHAIN_ID}.json"

    if [ -z "$PRODUCER_KEY_FILE" ] && [ "$NON_INTERACTIVE" != "1" ] && [ -t 0 ]; then
      echo "  Key handling:"
      echo "    1) On-disk plaintext (testnet OK; audit finding on mainnet)"
      echo "    2) Defer — leave producer_key blank; wire pulse-keosd later"
      prompt "Choice" "1" KEY_OPT
    else
      KEY_OPT=$([ -n "$PRODUCER_KEY_FILE" ] && echo 1 || echo 2)
    fi

    case "$KEY_OPT" in
      1)
        if [ -z "$PRODUCER_KEY_FILE" ]; then
          prompt "Path to file containing the PVT_K1_... key (we'll read it; never logged)" "" PRODUCER_KEY_FILE
        fi
        if [ -f "$PRODUCER_KEY_FILE" ]; then
          PVT_KEY=$(tr -d '[:space:]' < "$PRODUCER_KEY_FILE")
          if echo "$PVT_KEY" | grep -qE '^PVT_(K1|R1)_'; then
            cat >"$CHAIN_CFG" <<EOF
{
  "producer_name": "$PRODUCER_NAME",
  "producer_key": "$PVT_KEY"
}
EOF
            chmod 600 "$CHAIN_CFG"
            ok "Wrote $CHAIN_CFG (mode 600)"
            tip "Backup this file securely. Never commit. Rotate via pulse@updateauth if it's ever exposed."
          else
            warn "Key file content doesn't look like PVT_K1_/PVT_R1_ — skipping config write."
          fi
        else
          warn "Key file not found: $PRODUCER_KEY_FILE — skipping config write."
        fi
        ;;
      *)
        cat >"$CHAIN_CFG" <<EOF
{
  "producer_name": "$PRODUCER_NAME"
}
EOF
        ok "Wrote $CHAIN_CFG without producer_key"
        tip "Wire signing later via pulse-keosd (see wiki/bp-setup/03-keys-and-signing.md)."
        ;;
    esac
  else
    ok "Skipped producer config — node will start in observer mode"
    tip "Edit $METALGO_HOME/configs/chains/${BLOCKCHAIN_ID}.json later when you're ready to sign."
  fi
fi

# ---------- B4. nginx + landing page (nginx-enabled profiles only) ----------
if [ "$INSTALL_NGINX" = "1" ]; then
  step "Public endpoint (nginx + landing page)"

  if [ -z "$DOMAIN" ] && [ "$NON_INTERACTIVE" != "1" ] && [ -t 0 ]; then
    prompt "Domain name pointed at this box (or blank to skip nginx)" "" DOMAIN
  fi

  if [ -n "$DOMAIN" ]; then
    if ! command -v nginx >/dev/null 2>&1; then
      apt-get install -y nginx >>"$LOG" 2>&1
    fi

    LANDING_DIR="/var/www/${DOMAIN}"
    mkdir -p "$LANDING_DIR"

    LANDING_SRC="${SRC_DIR}/scripts/landing/index.html"
    if [ -f "$LANDING_SRC" ]; then
      sed -e "s|a-chain-testnet\.protonnz\.com|${DOMAIN}|g" \
          -e "s|6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y|${BLOCKCHAIN_ID}|g" \
          -e "s|zT2upfR4BSC55bvxLSbkuHBAcWL7jeG9aJwo8BdEGvV7NCxLW|${SUBNET_ID}|g" \
          -e "s|0d6f033e887fae475d641104b6e87762b6c869e87a101afeeb64d608ab376618|${CHAIN_ID}|g" \
          "$LANDING_SRC" > "${LANDING_DIR}/index.html"
      chown -R www-data:www-data "$LANDING_DIR"
      ok "Landing page deployed to ${LANDING_DIR}/index.html (your IDs substituted)"
    else
      warn "Landing template not found at $LANDING_SRC — skipping page deploy"
    fi

    NGINX_SRC="${SRC_DIR}/scripts/nginx-hyperion.conf"
    if [ -f "$NGINX_SRC" ]; then
      sed -e "s|a-chain-testnet\.protonnz\.com|${DOMAIN}|g" \
          -e "s|/var/www/a-chain-testnet|${LANDING_DIR}|g" \
          -e "s|6v9NieZiX3e8eQz3CyJMtXB6YzV2RtnxcRyLAmSgFWWk5Qs6y|${BLOCKCHAIN_ID}|g" \
          "$NGINX_SRC" > "/etc/nginx/sites-available/${DOMAIN}"
      ln -sfn "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
      rm -f /etc/nginx/sites-enabled/default

      # Strip TLS-specific directives until certbot adds them back
      sed -i '/ssl_certificate/d;/ssl_dhparam/d;/options-ssl-nginx/d;/listen.*443/d;/return 301/d' \
          "/etc/nginx/sites-available/${DOMAIN}"

      if nginx -t >>"$LOG" 2>&1; then
        systemctl reload nginx
        ok "nginx serving HTTP on port 80 — http://${DOMAIN}/"
      else
        warn "nginx config failed validation — see $LOG"
      fi
    fi

    # ---------- B5. TLS via certbot ------------------------------------------
    if [ "$SKIP_TLS" != "1" ]; then
      if [ -z "$EMAIL" ] && [ "$NON_INTERACTIVE" != "1" ] && [ -t 0 ]; then
        prompt "Email for Let's Encrypt (blank to skip TLS)" "" EMAIL
      fi
      if [ -n "$EMAIL" ]; then
        if confirm "Run certbot to issue a Let's Encrypt cert for ${DOMAIN}?" y; then
          apt-get install -y certbot python3-certbot-nginx >>"$LOG" 2>&1
          if certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect >>"$LOG" 2>&1; then
            ok "TLS live at https://${DOMAIN}/ — auto-renew via certbot.timer"
            tip "Cloudflare must be DNS-only (grey cloud) for the HTTP-01 challenge. Re-enable proxy after if you want."
          else
            warn "certbot failed — check $LOG. Common cause: DNS not yet propagated, or Cloudflare orange-cloud blocking the challenge."
          fi
        fi
      fi
    fi
  else
    ok "Skipped nginx — re-run with --domain to wire it up later"
  fi
fi

# ---------- B6. systemd unit ------------------------------------------------
if [ "$SKIP_SYSTEMD" != "1" ]; then
  step "systemd unit"
  if confirm "Install metalgo systemd unit (auto-start at boot, proper SIGTERM shutdown)?" y; then
    cat >/etc/systemd/system/metalgo.service <<EOF
[Unit]
Description=MetalGo node (PulseVM subnet)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${METALGO_DIR}/metalgo --config-file=${CONFIG_FILE}
Restart=on-failure
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=120
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable metalgo >>"$LOG" 2>&1
    ok "metalgo enabled at boot"
    tip "ALWAYS use 'systemctl stop metalgo' (sends SIGTERM, waits 120 s). NEVER kill -9 — Chainbase dirty-flag check will refuse to mount the DB on next start."
  fi
fi

# ---------- version manifest -------------------------------------------------
{
  echo "# Installed $(date -Iseconds)"
  echo "profile:            $PROFILE"
  echo "network:            $NETWORK"
  echo "subnet_id:          $SUBNET_ID"
  echo "blockchain_id:      $BLOCKCHAIN_ID"
  echo "chain_id:           $CHAIN_ID"
  [ -n "${DOMAIN:-}" ] && echo "public_endpoint:    https://${DOMAIN}/"
  [ -n "${PRODUCER_NAME:-}" ] && echo "producer_name:      $PRODUCER_NAME"
  echo "metalgo:            $(${METALGO_DIR}/metalgo --version 2>/dev/null | head -1 || echo 'missing')"
  echo "pulsevm plugin:     ${PLUGIN_DIR}/${VM_ID}   ($(stat -c%s ${PLUGIN_DIR}/${VM_ID} 2>/dev/null || echo 0) bytes)"
} | tee /opt/versions.txt >/dev/null

# ============================================================================
# Phase C: post-install summary
# ============================================================================

cat <<EOF

================================================================
  Setup complete — $PROFILE on $(hostname)
================================================================

  Network:          $NETWORK
  Subnet ID:        $SUBNET_ID
  Blockchain ID:    $BLOCKCHAIN_ID
  Chain ID:         $CHAIN_ID
EOF
[ -n "${DOMAIN:-}" ]        && echo "  Public endpoint:  https://${DOMAIN}/"
[ -n "${PRODUCER_NAME:-}" ] && echo "  Producer name:    $PRODUCER_NAME"
[ "$ROLE_PRODUCER" = "1" ] && [ -z "${PRODUCER_NAME:-}" ] && \
  warn "Producer profile but no producer name configured — node will run as observer"

cat <<EOF

  Next steps:
    systemctl start metalgo                 # start the node
    journalctl -u metalgo -f                # watch sync (Ctrl-C to stop tailing)
    pulse chain:info --url http://127.0.0.1:9650/ext/bc/${BLOCKCHAIN_ID}/rpc

EOF

[ -n "${DOMAIN:-}" ] && cat <<EOF
  Visit https://${DOMAIN}/ — your live status panel + curl examples.

EOF

[ "$ROLE_PRODUCER" = "1" ] && [ -n "${PRODUCER_NAME:-}" ] && cat <<EOF
  To register on-chain (regproducer): wiki/bp-setup/07-becoming-a-validator.md

EOF

[ "$INSTALL_HYPERION" = "1" ] && cat <<EOF
  Hyperion is cloned at /opt/hyperion/pulsevm-hyperion (release/3.6) but
  not started — it needs its connections.json wired to your local SHiP
  before docker compose up. See wiki/bp-setup/08-hyperion.md.

EOF

cat <<EOF
  Bootstrap log:    $LOG
  Version manifest: /opt/versions.txt
  Docs / playbook:  https://github.com/paulgnz/pulsevm-operator-kit
================================================================
EOF
