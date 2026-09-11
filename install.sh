#!/usr/bin/env bash
# singox_sh installer - bootstraps a sing-box relay server (VLESS/VMess/Trojan/
# Shadowsocks/Hysteria2/TUIC) with acme.sh certificate management, BBR/network
# tuning, and installs the `singbox-menu` management command.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nooblk-98/singox_sh/main/install.sh | bash
#   or: ./install.sh
#
# When run via the curl one-liner (no lib/menu.sh alongside this script), the
# installer fetches the repo itself via git into a persistent checkout to
# pick up lib/menu.sh - git (unlike raw.githubusercontent.com, which sits
# behind a caching CDN) always serves the current commit.
#
# Safe to re-run: will NOT overwrite an existing sing-box config, only ensures
# the binary/service/menu tool are up to date, then launches the menu.

set -euo pipefail

REPO_URL="https://github.com/nooblk-98/singox_sh.git"
APP_DIR="/usr/local/lib/singox_sh"
SRC_DIR="$APP_DIR/src"
BIN="/usr/local/bin/sing-box"
CONF="/usr/local/etc/singbox-config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SYSCTL_FILE="/etc/sysctl.d/99-network-tune.conf"
MENU_LINK="/usr/local/bin/singbox-menu"

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root."

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing dependencies (apt)..."
    apt-get update -qq || warn "apt-get update had errors (bad mirror/signature?) - continuing with cached package lists."
    apt-get install -y -qq curl jq openssl tar cron git >/dev/null \
      || die "apt-get install failed. Check the apt-get update warnings above - a broken repo/mirror on this host is the likely cause."
  elif command -v apk >/dev/null 2>&1; then
    log "Installing dependencies (apk)..."
    apk add --no-cache curl jq openssl tar git >/dev/null
  else
    warn "Unknown package manager - ensure curl, jq, openssl, tar, git are installed."
  fi
}

install_singbox_binary() {
  if [ -x "$BIN" ]; then
    log "sing-box already installed: $("$BIN" version | head -1)"
    read -r -p "Update to latest sing-box release? [y/N] " ans
    [ "${ans,,}" = "y" ] || return 0
  fi
  local arch tag url tmp
  arch=$(detect_arch)
  log "Fetching latest sing-box release info..."
  tag=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  [ -n "$tag" ] && [ "$tag" != "null" ] || die "Could not determine latest sing-box version."
  local ver="${tag#v}"
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
  tmp=$(mktemp -d)
  log "Downloading sing-box ${tag} (${arch})..."
  curl -fsSL "$url" -o "$tmp/sb.tar.gz" || die "Download failed: $url"
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp"
  find "$tmp" -type f -name "sing-box" -exec install -m 755 {} "$BIN" \;
  rm -rf "$tmp"
  log "Installed: $("$BIN" version | head -1)"
}

install_acme_sh() {
  if [ -x "/root/.acme.sh/acme.sh" ]; then
    log "acme.sh already installed."
    return 0
  fi
  log "Installing acme.sh..."
  curl -fsSL https://get.acme.sh | sh -s email="admin@$(hostname -f 2>/dev/null || echo example.com)" >/dev/null 2>&1 \
    || warn "acme.sh installer had warnings - check manually if cert issuance fails."
}

apply_sysctl_tuning() {
  if [ -f "$SYSCTL_FILE" ]; then
    log "Network tuning already present at $SYSCTL_FILE"
  else
    log "Writing network tuning to $SYSCTL_FILE"
    cat > "$SYSCTL_FILE" <<'SYSCTL'
# BBR congestion control + fair queueing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Larger TCP buffers for higher bandwidth-delay-product paths
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Misc
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
SYSCTL
  fi
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported issues, check manually."
}

write_base_config() {
  if [ -f "$CONF" ]; then
    log "Existing config found at $CONF - leaving inbounds untouched."
    return 0
  fi
  log "Writing base config skeleton to $CONF"
  mkdir -p "$(dirname "$CONF")"
  cat > "$CONF" <<'JSON'
{
  "log": { "level": "warn", "timestamp": true },
  "experimental": {
    "clash_api": { "external_controller": "127.0.0.1:9090" },
    "cache_file": { "enabled": true }
  },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
JSON
}

install_systemd_service() {
  log "Installing systemd service..."
  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${BIN} run -c ${CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1
  systemctl restart sing-box || warn "sing-box failed to start - check 'journalctl -u sing-box' (likely empty inbounds, that's fine until you add one)."
}

FETCHED_SRC_DIR=""

fetch_repo() {
  # Sets FETCHED_SRC_DIR directly (not via command substitution/subshell).
  local script_dir
  script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  if [ -n "$script_dir" ] && [ -f "$script_dir/lib/menu.sh" ]; then
    FETCHED_SRC_DIR="$script_dir"
    return 0
  fi
  command -v git >/dev/null 2>&1 || die "git is required to fetch lib/menu.sh but was not found."
  if [ -d "$SRC_DIR/.git" ]; then
    log "Updating cached singox_sh checkout at $SRC_DIR..."
    if ! { git -C "$SRC_DIR" fetch --depth 1 origin main >/dev/null 2>&1 \
        && git -C "$SRC_DIR" reset --hard origin/main >/dev/null 2>&1; }; then
      warn "git update of $SRC_DIR failed, re-cloning..."
      rm -rf "$SRC_DIR"
    fi
  fi
  if [ ! -d "$SRC_DIR/.git" ]; then
    log "Cloning singox_sh source into $SRC_DIR..."
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 \
      || die "Failed to clone $REPO_URL"
  fi
  FETCHED_SRC_DIR="$SRC_DIR"
}

install_menu() {
  mkdir -p "$APP_DIR"
  fetch_repo
  local src_dir="$FETCHED_SRC_DIR"
  [ -f "$src_dir/lib/menu.sh" ] || die "lib/menu.sh not found in $src_dir after fetch."
  cp "$src_dir/lib/menu.sh" "$APP_DIR/menu.sh"
  cp "$src_dir/VERSION" "$APP_DIR/VERSION" 2>/dev/null || echo "0.0.0" > "$APP_DIR/VERSION"
  chmod +x "$APP_DIR/menu.sh"
  ln -sf "$APP_DIR/menu.sh" "$MENU_LINK"
  log "Management command installed: run 'singbox-menu' any time (version $(cat "$APP_DIR/VERSION"))."
}

main() {
  install_deps
  install_singbox_binary
  install_acme_sh
  apply_sysctl_tuning
  write_base_config
  install_systemd_service
  install_menu
  echo ""
  log "Install complete."
  echo "    Run:  singbox-menu"
  echo "    to add inbounds, manage certificates, and view status."
  echo ""
  # --update: called from the menu's "Update" option, which relaunches the
  # menu itself afterward - skip the prompt/exec here to avoid nesting.
  [ "${1:-}" = "--update" ] && return 0
  read -r -p "Launch the menu now? [Y/n] " ans
  if [ "${ans,,}" != "n" ]; then
    exec "$MENU_LINK"
  fi
}

main "$@"
