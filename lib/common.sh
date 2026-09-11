#!/usr/bin/env bash

BIN="/usr/local/bin/sing-box"
CONF="/usr/local/etc/singbox-config.json"
SERVICE="sing-box"
SYSCTL_FILE="/etc/sysctl.d/99-network-tune.conf"
CERT_BASE="/root/cert"
ACME="/root/.acme.sh/acme.sh"
ADDR_FILE="/usr/local/etc/singbox-address"
LINKS_FILE="/usr/local/etc/singbox-links.txt"
CLASH_API_ADDR="127.0.0.1:9090"
BACKUP_DIR="/root/singbox-backups"
REPO_URL="https://github.com/nooblk-98/singox_sh.git"
SRC_DIR="/usr/local/lib/singox_sh/src"
VERSION_FILE="/usr/local/lib/singox_sh/VERSION"
VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")"

c_g="\033[1;32m"; c_y="\033[1;33m"; c_r="\033[1;31m"; c_b="\033[1;34m"; c_0="\033[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
err()  { echo -e "${c_r}[x]${c_0} $*"; }
pause() { read -r -p "Press Enter to continue..." _; }

ask() {
  local prompt="$1" default="${2:-}" val
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " val
    echo "${val:-$default}"
  else
    read -r -p "$prompt: " val
    echo "$val"
  fi
}

port_free() {
  local port="$1" net="${2:-tcp}" flag="-tln"
  [ "$net" = "udp" ] && flag="-uln"
  ! ss $flag 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

ask_port() {
  local default="${1:-}" net="${2:-tcp}" p
  while true; do
    p=$(ask "Port" "$default")
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { warn "Invalid port."; continue; }
    if jq -e --argjson p "$p" --arg net "$net" '
        .inbounds[] | select(.listen_port==$p) |
        select((if (.type=="hysteria2" or .type=="tuic") then "udp" else "tcp" end) == $net)
      ' "$CONF" >/dev/null 2>&1; then
      warn "Port $p/$net already used by an existing inbound."
      continue
    fi
    if ! port_free "$p" "$net"; then
      warn "Port $p/$net appears to be in use on the system."
      [ "$(ask "Use it anyway? (y/N)" "n")" = "y" ] && { echo "$p"; return; } || continue
    fi
    echo "$p"; return
  done
}

get_address() {
  if [ -f "$ADDR_FILE" ]; then cat "$ADDR_FILE"; return; fi
  local ip
  ip=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsSL --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  echo "$ip" > "$ADDR_FILE"
  echo "$ip"
}

default_address_to_domain() {
  local domain="$1"
  [ -f "$ADDR_FILE" ] && return 0
  echo "$domain" > "$ADDR_FILE"
  log "Using $domain as your public address for client links (menu option 7 to change)."
}

set_address() {
  local cur; cur=$(get_address)
  local new; new=$(ask "Public address/domain clients should connect to" "$cur")
  echo "$new" > "$ADDR_FILE"
  log "Saved. Existing links printed earlier won't auto-update - re-view them if needed."
}

validate_and_apply() {
  local tmp="$1"
  if ! "$BIN" check -c "$tmp" 2>/tmp/singbox_check.err; then
    err "Config validation failed, not applying:"
    cat /tmp/singbox_check.err
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONF"
  systemctl restart "$SERVICE"
  sleep 1
  if systemctl is-active --quiet "$SERVICE"; then
    log "Applied and $SERVICE restarted successfully."
  else
    err "$SERVICE failed to start after applying config! Check: journalctl -u $SERVICE -n 50"
    return 1
  fi
}

check_reachability() {
  local addr="$1" port="$2" net="${3:-tcp}"
  if [ "$net" != "tcp" ]; then
    warn "UDP reachability isn't checked automatically - test with a real client, or check your firewall/security group for UDP $port."
    return
  fi
  log "Checking external reachability of ${addr}:${port} (best-effort, via check-host.net)..."
  local resp req_id
  resp=$(curl -s -H "Accept: application/json" --max-time 8 "https://check-host.net/check-tcp?host=${addr}:${port}&max_nodes=1" 2>/dev/null)
  req_id=$(echo "$resp" | jq -r '.request_id // empty' 2>/dev/null)
  if [ -z "$req_id" ]; then
    warn "Reachability check unavailable right now - verify manually if clients can't connect."
    return
  fi
  local attempt status="null" result
  for attempt in 1 2 3 4; do
    sleep 3
    result=$(curl -s --max-time 8 "https://check-host.net/check-result/${req_id}" 2>/dev/null)
    status=$(echo "$result" | jq -r 'to_entries[0].value[0][0] // "null"' 2>/dev/null)
    [ "$status" != "null" ] && [ -n "$status" ] && break
  done
  if [ "$status" = "1" ]; then
    log "Port ${port} is reachable from outside."
  else
    warn "Port ${port} does NOT appear reachable from outside - check firewall/security group rules (ufw, cloud provider firewall, NAT) before sharing this link."
  fi
}

bytes_human() {
  local b="$1"
  awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}
