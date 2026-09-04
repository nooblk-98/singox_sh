#!/usr/bin/env bash
# singox_sh menu - interactive manager for a sing-box relay server.
# Installed by install.sh as `singbox-menu`.

set -uo pipefail

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

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
command -v jq >/dev/null || { echo "jq is required."; exit 1; }
touch "$LINKS_FILE"

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

port_free() { ! ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }

ensure_clash_api() {
  if jq -e '.experimental.clash_api' "$CONF" >/dev/null 2>&1; then
    return 0
  fi
  log "Enabling sing-box's Clash API (needed for live traffic totals)..."
  jq --arg addr "$CLASH_API_ADDR" \
    '.experimental = {"clash_api": {"external_controller": $addr}, "cache_file": {"enabled": true}}' \
    "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json
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

show_traffic() {
  ensure_clash_api || return
  echo ""
  echo "== Live traffic (since last sing-box restart) =="
  local json; json=$(curl -s --max-time 3 "http://${CLASH_API_ADDR}/connections")
  if [ -z "$json" ]; then
    err "Could not reach Clash API at $CLASH_API_ADDR - is sing-box running?"
    return
  fi
  local up down active
  up=$(echo "$json" | jq -r '.uploadTotal // 0')
  down=$(echo "$json" | jq -r '.downloadTotal // 0')
  active=$(echo "$json" | jq -r '.connections | length')
  echo "Upload total:    $(bytes_human "$up")"
  echo "Download total:  $(bytes_human "$down")"
  echo "Active connections: $active"
  if [ "$active" -gt 0 ]; then
    echo ""
    echo "Active connections by inbound:"
    echo "$json" | jq -r '.connections[].metadata.type' | sed 's#.*/##' | sort | uniq -c | sort -rn
  fi
  echo ""
  warn "This counter resets whenever sing-box restarts (e.g. after adding/removing an inbound) - it's not persisted historical usage."
}

cert_expiry_line() {
  # Prints "<enddate>|<days>" for a valid cert, or "INVALID|" for an
  # unreadable/empty one (e.g. a failed acme.sh issuance).
  local f="$1" enddate
  enddate=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
  if [ -z "$enddate" ]; then
    echo "INVALID|"
    return
  fi
  local days=$(( ( $(date -d "$enddate" +%s) - $(date +%s) ) / 86400 ))
  echo "${enddate}|${days}"
}

ask_port() {
  local default="${1:-}" p
  while true; do
    p=$(ask "Port" "$default")
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { warn "Invalid port."; continue; }
    if jq -e --argjson p "$p" '.inbounds[] | select(.listen_port==$p)' "$CONF" >/dev/null 2>&1; then
      warn "Port $p already used by an existing inbound."
      continue
    fi
    if ! port_free "$p"; then
      warn "Port $p appears to be in use on the system."
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

# ---------- certificates ----------

decode_reload_hook() {
  local domain="$1" conf="/root/.acme.sh/${domain}_ecc/${domain}.conf"
  [ -f "$conf" ] || { echo ""; return; }
  grep Le_ReloadCmd "$conf" 2>/dev/null | sed 's/.*START_//;s/__ACME.*//' | base64 -d 2>/dev/null
}

ensure_cert() {
  local domain="$1"
  local certdir="$CERT_BASE/$domain"
  if [ -f "$certdir/fullchain.pem" ]; then
    local hook; hook=$(decode_reload_hook "$domain")
    if [ "$hook" != "systemctl restart $SERVICE" ]; then
      warn "Reload hook for $domain is '${hook:-<none>}', not 'systemctl restart $SERVICE'. Fixing..."
      "$ACME" --install-cert -d "$domain" --ecc \
        --key-file "$certdir/privkey.pem" \
        --fullchain-file "$certdir/fullchain.pem" \
        --reloadcmd "systemctl restart $SERVICE" >/dev/null 2>&1
      log "Reload hook fixed for $domain."
    fi
    return 0
  fi
  log "No cert found for $domain, issuing via acme.sh (needs port 80 free)..."
  if ! port_free 80; then
    warn "Port 80 is in use - acme.sh --standalone needs it free to issue via HTTP-01."
    [ "$(ask "Continue anyway? (y/N)" "n")" = "y" ] || return 1
  fi
  "$ACME" --issue -d "$domain" --standalone --keylength ec-256 || { err "Cert issuance failed for $domain."; return 1; }
  mkdir -p "$certdir"
  "$ACME" --install-cert -d "$domain" --ecc \
    --key-file "$certdir/privkey.pem" \
    --fullchain-file "$certdir/fullchain.pem" \
    --reloadcmd "systemctl restart $SERVICE"
  log "Cert issued and installed for $domain."
}

cert_menu() {
  while true; do
    echo ""
    echo "== Certificates =="
    if compgen -G "$CERT_BASE/*/fullchain.pem" >/dev/null; then
      for f in "$CERT_BASE"/*/fullchain.pem; do
        local domain; domain=$(basename "$(dirname "$f")")
        local line enddate days hookstatus
        line=$(cert_expiry_line "$f")
        enddate="${line%%|*}"; days="${line##*|}"
        if [ "$enddate" = "INVALID" ]; then
          printf "  %-30s ${c_r}INVALID/EMPTY cert - issuance likely failed${c_0}\n" "$domain"
          continue
        fi
        hookstatus="OK"
        [ "$(decode_reload_hook "$domain")" = "systemctl restart $SERVICE" ] || hookstatus="MISMATCH"
        printf "  %-30s expires %s (%s days)  reload-hook:%s\n" "$domain" "$enddate" "$days" "$hookstatus"
      done
    else
      echo "  (none yet)"
    fi
    echo ""
    echo "  1) Issue/repair cert for a domain"
    echo "  2) Force-renew a domain now"
    echo "  3) Verify + fix reload hooks for all domains"
    echo "  0) Back"
    case "$(ask "Choose" "0")" in
      1) ensure_cert "$(ask "Domain")"; pause ;;
      2) local d; d=$(ask "Domain"); "$ACME" --renew -d "$d" --ecc --force; pause ;;
      3)
        if compgen -G "$CERT_BASE/*/fullchain.pem" >/dev/null; then
          for f in "$CERT_BASE"/*/fullchain.pem; do
            local domain; domain=$(basename "$(dirname "$f")")
            ensure_cert "$domain"
          done
        fi
        pause ;;
      0) return ;;
    esac
  done
}

# ---------- inbound builders ----------

gen_uuid() { "$BIN" generate uuid; }
gen_hex()  { "$BIN" generate rand "${1:-8}" --hex; }
gen_b64()  { "$BIN" generate rand "${1:-16}" --base64; }

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

save_link() {
  local tag="$1" uri="$2"
  # remove any existing line for this tag, then append
  grep -v "^${tag}	" "$LINKS_FILE" > "${LINKS_FILE}.tmp" 2>/dev/null || true
  mv "${LINKS_FILE}.tmp" "$LINKS_FILE" 2>/dev/null || true
  printf '%s\t%s\n' "$tag" "$uri" >> "$LINKS_FILE"
  echo ""
  log "Client link (also saved, view any time via menu -> List links):"
  echo "$uri"
}

add_vless_ws_tls() {
  local port; port=$(ask_port)
  local domain; domain=$(ask "Certificate domain (real domain with a valid cert)")
  ensure_cert "$domain" || return
  local sni; sni=$(ask "SNI to present to clients (decoy domain, e.g. m.youtube.com; blank = same as cert domain)" "$domain")
  local path; path=$(ask "WS path" "/$(gen_hex 6)")
  local uuid; uuid=$(gen_uuid)
  local tag="vless-ws-tls-$port"
  local certdir="$CERT_BASE/$domain"
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --arg path "$path" --arg sni "$sni" --arg cert "$certdir/fullchain.pem" --arg key "$certdir/privkey.pem" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,tcp_fast_open:true,
     users:[{uuid:$uuid,flow:""}],
     transport:{type:"ws",path:$path,max_early_data:2048,early_data_header_name:"Sec-WebSocket-Protocol"},
     multiplex:{enabled:true},
     tls:{enabled:true,server_name:$sni,min_version:"1.2",max_version:"1.3",alpn:["h2","http/1.1"],certificate_path:$cert,key_path:$key}}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local uri="vless://${uuid}@${addr}:${port}?type=ws&security=tls&path=$(urlenc "$path")&sni=${sni}&fp=chrome#${tag}"
  save_link "$tag" "$uri"
  [ "$sni" != "$domain" ] && warn "SNI differs from cert domain - client must set verifyPeerCertByName=$domain (Xray) or the equivalent for its core, since allowInsecure is removed in modern Xray."
}

add_vless_transport_tls() {  # grpc / httpupgrade, shared shape
  local transport="$1" label="$2"
  local port; port=$(ask_port)
  local domain; domain=$(ask "Certificate domain (real domain with a valid cert)")
  ensure_cert "$domain" || return
  local sni; sni=$(ask "SNI to present to clients" "$domain")
  local uuid; uuid=$(gen_uuid)
  local tag="vless-${transport}-tls-$port"
  local certdir="$CERT_BASE/$domain"
  local transport_json extra_qs
  if [ "$transport" = "grpc" ]; then
    local svc; svc=$(ask "gRPC service name" "grpc$(gen_hex 4)")
    transport_json=$(jq -n --arg s "$svc" '{type:"grpc",service_name:$s}')
    extra_qs="type=grpc&serviceName=$(urlenc "$svc")"
  else
    local path; path=$(ask "HTTP-Upgrade path" "/$(gen_hex 6)")
    transport_json=$(jq -n --arg p "$path" '{type:"httpupgrade",path:$p}')
    extra_qs="type=httpupgrade&path=$(urlenc "$path")"
  fi
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --argjson transport "$transport_json" --arg sni "$sni" --arg cert "$certdir/fullchain.pem" --arg key "$certdir/privkey.pem" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,tcp_fast_open:true,
     users:[{uuid:$uuid,flow:""}],
     transport:$transport,
     tls:{enabled:true,server_name:$sni,min_version:"1.2",max_version:"1.3",certificate_path:$cert,key_path:$key}}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local uri="vless://${uuid}@${addr}:${port}?security=tls&sni=${sni}&fp=chrome&${extra_qs}#${tag}"
  save_link "$tag" "$uri"
  [ "$sni" != "$domain" ] && warn "SNI differs from cert domain - client must set verifyPeerCertByName=$domain."
}

add_vless_reality() {
  local with_vision="$1"  # y/n
  local port; port=$(ask_port)
  local hs_domain; hs_domain=$(ask "Real site to mimic (Reality handshake target)" "m.youtube.com")
  local hs_port; hs_port=$(ask "Handshake port" "443")
  local uuid; uuid=$(gen_uuid)
  local keys priv pub
  keys=$("$BIN" generate reality-keypair)
  priv=$(echo "$keys" | awk -F': ' '/PrivateKey/{print $2}')
  pub=$(echo "$keys" | awk -F': ' '/PublicKey/{print $2}')
  local shortid; shortid=$(gen_hex 8)
  local flow=""; local tagsuffix="reality"
  [ "$with_vision" = "y" ] && { flow="xtls-rprx-vision"; tagsuffix="reality-vision"; }
  local tag="vless-${tagsuffix}-$port"
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" \
    --arg hs "$hs_domain" --argjson hsport "$hs_port" --arg priv "$priv" --arg sid "$shortid" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,tcp_fast_open:true,
     users:[{uuid:$uuid,flow:$flow}],
     tls:{enabled:true,server_name:$hs,
          reality:{enabled:true,handshake:{server:$hs,server_port:$hsport},private_key:$priv,short_id:["",$sid]}}}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local flowqs=""; [ -n "$flow" ] && flowqs="&flow=$flow"
  local uri="vless://${uuid}@${addr}:${port}?type=tcp&security=reality${flowqs}&sni=${hs_domain}&fp=chrome&pbk=${pub}&sid=${shortid}&encryption=none#${tag}"
  save_link "$tag" "$uri"
}

add_vmess_ws_tls() {
  local port; port=$(ask_port)
  local domain; domain=$(ask "Certificate domain")
  ensure_cert "$domain" || return
  local sni; sni=$(ask "SNI to present to clients" "$domain")
  local path; path=$(ask "WS path" "/$(gen_hex 6)")
  local uuid; uuid=$(gen_uuid)
  local tag="vmess-ws-tls-$port"
  local certdir="$CERT_BASE/$domain"
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --arg path "$path" --arg sni "$sni" --arg cert "$certdir/fullchain.pem" --arg key "$certdir/privkey.pem" '
    {type:"vmess",tag:$tag,listen:"::",listen_port:$port,
     users:[{uuid:$uuid,alterId:0}],
     transport:{type:"ws",path:$path},
     tls:{enabled:true,server_name:$sni,certificate_path:$cert,key_path:$key}}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local vmess_json; vmess_json=$(jq -n --arg v "2" --arg ps "$tag" --arg add "$addr" --arg port "$port" \
    --arg id "$uuid" --arg aid "0" --arg net "ws" --arg type "none" --arg host "$sni" \
    --arg path "$path" --arg tls "tls" --arg sni "$sni" \
    '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:$aid,net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$sni}')
  local uri="vmess://$(echo -n "$vmess_json" | base64 -w0)"
  save_link "$tag" "$uri"
  [ "$sni" != "$domain" ] && warn "SNI differs from cert domain - client must set verifyPeerCertByName=$domain."
}

add_trojan() {
  local with_ws="$1"  # y/n
  local port; port=$(ask_port)
  local domain; domain=$(ask "Certificate domain")
  ensure_cert "$domain" || return
  local sni; sni=$(ask "SNI to present to clients" "$domain")
  local password; password=$(gen_b64 16)
  local certdir="$CERT_BASE/$domain"
  local transport_json="null" qs="" tagsuffix="tls"
  if [ "$with_ws" = "y" ]; then
    local path; path=$(ask "WS path" "/$(gen_hex 6)")
    transport_json=$(jq -n --arg p "$path" '{type:"ws",path:$p}')
    qs="&type=ws&path=$(urlenc "$path")"
    tagsuffix="ws-tls"
  fi
  local tag="trojan-${tagsuffix}-$port"
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg pw "$password" \
    --argjson transport "$transport_json" --arg sni "$sni" --arg cert "$certdir/fullchain.pem" --arg key "$certdir/privkey.pem" '
    {type:"trojan",tag:$tag,listen:"::",listen_port:$port,
     users:[{password:$pw}],
     tls:{enabled:true,server_name:$sni,certificate_path:$cert,key_path:$key}}
    * (if $transport != null then {transport:$transport} else {} end)')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local uri="trojan://${password}@${addr}:${port}?security=tls&sni=${sni}${qs}#${tag}"
  save_link "$tag" "$uri"
  [ "$sni" != "$domain" ] && warn "SNI differs from cert domain - client must set verifyPeerCertByName=$domain."
}

add_shadowsocks() {
  local port; port=$(ask_port)
  echo "Methods: 1) 2022-blake3-aes-128-gcm  2) 2022-blake3-aes-256-gcm  3) aes-256-gcm  4) chacha20-ietf-poly1305"
  local m; m=$(ask "Choose method" "2")
  local method; case "$m" in
    1) method="2022-blake3-aes-128-gcm" ;;
    2) method="2022-blake3-aes-256-gcm" ;;
    3) method="aes-256-gcm" ;;
    4) method="chacha20-ietf-poly1305" ;;
    *) method="2022-blake3-aes-256-gcm" ;;
  esac
  local password
  if [[ "$method" == 2022-* ]]; then password=$(gen_b64 32); else password=$(gen_b64 16); fi
  local tag="ss-$port"
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg pw "$password" '
    {type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$pw}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local userinfo; userinfo=$(echo -n "${method}:${password}" | base64 -w0 | tr -d '\n')
  local uri="ss://${userinfo}@${addr}:${port}#${tag}"
  save_link "$tag" "$uri"
}

add_hysteria2() {
  local port; port=$(ask_port)
  local domain; domain=$(ask "Certificate domain")
  ensure_cert "$domain" || return
  local password; password=$(gen_b64 16)
  local masq; masq=$(ask "Masquerade URL (decoy site shown to probers)" "https://m.youtube.com")
  local tag="hysteria2-$port"
  local certdir="$CERT_BASE/$domain"
  local up; up=$(ask "Declared up_mbps (server upload to client)" "200")
  local down; down=$(ask "Declared down_mbps (server download from client)" "200")
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg pw "$password" \
    --argjson up "$up" --argjson down "$down" --arg masq "$masq" \
    --arg sni "$domain" --arg cert "$certdir/fullchain.pem" --arg key "$certdir/privkey.pem" '
    {type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,up_mbps:$up,down_mbps:$down,
     users:[{password:$pw}],
     masquerade:{type:"proxy",url:$masq},
     tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:$cert,key_path:$key}}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local uri="hysteria2://${password}@${addr}:${port}/?sni=${domain}&alpn=h3#${tag}"
  save_link "$tag" "$uri"
}

add_tuic() {
  local port; port=$(ask_port)
  local domain; domain=$(ask "Certificate domain")
  ensure_cert "$domain" || return
  local uuid; uuid=$(gen_uuid)
  local password; password=$(gen_b64 16)
  local tag="tuic-$port"
  local certdir="$CERT_BASE/$domain"
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg pw "$password" \
    --arg sni "$domain" --arg cert "$certdir/fullchain.pem" --arg key "$certdir/privkey.pem" '
    {type:"tuic",tag:$tag,listen:"::",listen_port:$port,
     users:[{uuid:$uuid,password:$pw}],congestion_control:"bbr",
     tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:$cert,key_path:$key}}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local uri="tuic://${uuid}:${password}@${addr}:${port}?congestion_control=bbr&alpn=h3&sni=${domain}#${tag}"
  save_link "$tag" "$uri"
}

add_inbound_menu() {
  echo ""
  echo "== Add inbound - choose type =="
  echo "  1) VLESS + WS + TLS            (CDN-friendly camouflage)"
  echo "  2) VLESS + gRPC + TLS"
  echo "  3) VLESS + HTTPUpgrade + TLS"
  echo "  4) VLESS + Reality + Vision     (fastest in our benchmarks, no cert needed)"
  echo "  5) VLESS + Reality (no Vision, less padding overhead)"
  echo "  6) VMess + WS + TLS"
  echo "  7) Trojan + TLS (raw)"
  echo "  8) Trojan + WS + TLS"
  echo "  9) Shadowsocks (2022 / classic AEAD)"
  echo " 10) Hysteria2 (QUIC/UDP)"
  echo " 11) TUIC v5 (QUIC/UDP)"
  echo "  0) Back"
  case "$(ask "Choose" "0")" in
    1) add_vless_ws_tls ;;
    2) add_vless_transport_tls grpc "gRPC" ;;
    3) add_vless_transport_tls httpupgrade "HTTPUpgrade" ;;
    4) add_vless_reality y ;;
    5) add_vless_reality n ;;
    6) add_vmess_ws_tls ;;
    7) add_trojan n ;;
    8) add_trojan y ;;
    9) add_shadowsocks ;;
    10) add_hysteria2 ;;
    11) add_tuic ;;
    0) return ;;
    *) warn "Invalid choice." ;;
  esac
  pause
}

list_inbounds() {
  echo ""
  echo "== Inbounds =="
  jq -r '.inbounds[] | "\(.tag)\t\(.type)\tport \(.listen_port)"' "$CONF" 2>/dev/null | column -t -s$'\t' || echo "(none)"
}

remove_inbound() {
  local tags=(); while IFS= read -r t; do tags+=("$t"); done < <(jq -r '.inbounds[].tag' "$CONF" 2>/dev/null)
  [ "${#tags[@]}" -eq 0 ] && { warn "No inbounds to remove."; return; }
  echo ""
  echo "== Inbounds =="
  local i=1 t type port
  for t in "${tags[@]}"; do
    type=$(jq -r --arg t "$t" '.inbounds[] | select(.tag==$t) | .type' "$CONF")
    port=$(jq -r --arg t "$t" '.inbounds[] | select(.tag==$t) | .listen_port' "$CONF")
    printf "  %d) %-30s %-12s port %s\n" "$i" "$t" "$type" "$port"
    i=$((i+1))
  done
  local sel tag
  sel=$(ask "Number to remove (or type exact tag)")
  if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#tags[@]}" ]; then
    tag="${tags[$((sel-1))]}"
  else
    tag="$sel"
  fi
  jq -e --arg t "$tag" '.inbounds[] | select(.tag==$t)' "$CONF" >/dev/null 2>&1 || { err "No such tag."; return; }
  jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  grep -v "^${tag}	" "$LINKS_FILE" > "${LINKS_FILE}.tmp" 2>/dev/null || true
  mv "${LINKS_FILE}.tmp" "$LINKS_FILE" 2>/dev/null || true
  log "Removed $tag."
}

list_links() {
  echo ""
  echo "== Saved client links =="
  if [ -s "$LINKS_FILE" ]; then
    while IFS=$'\t' read -r tag uri; do
      echo "-- $tag --"
      echo "$uri"
      echo ""
    done < "$LINKS_FILE"
  else
    echo "(none yet)"
  fi
}

status_dashboard() {
  echo ""
  echo "== Status =="
  systemctl is-active --quiet "$SERVICE" && echo -e "Service:      ${c_g}active${c_0}" || echo -e "Service:      ${c_r}inactive${c_0}"
  echo "Version:      $("$BIN" version 2>/dev/null | head -1)"
  echo "Uptime:       $(systemctl show -p ActiveEnterTimestamp "$SERVICE" 2>/dev/null | cut -d= -f2)"
  echo "Address:      $(get_address)"
  echo "Inbounds:     $(jq '.inbounds | length' "$CONF" 2>/dev/null) (menu option 2 for details)"
  if jq -e '.experimental.clash_api' "$CONF" >/dev/null 2>&1; then
    local tj up down active
    tj=$(curl -s --max-time 1 "http://${CLASH_API_ADDR}/connections")
    if [ -n "$tj" ]; then
      up=$(echo "$tj" | jq -r '.uploadTotal // 0')
      down=$(echo "$tj" | jq -r '.downloadTotal // 0')
      active=$(echo "$tj" | jq -r '.connections | length')
      echo "Traffic:      up $(bytes_human "$up") / down $(bytes_human "$down")  (${active} active, since last restart)"
    fi
  fi
  echo ""
  echo "Certificates:"
  if compgen -G "$CERT_BASE/*/fullchain.pem" >/dev/null; then
    for f in "$CERT_BASE"/*/fullchain.pem; do
      local domain line enddate days
      domain=$(basename "$(dirname "$f")")
      line=$(cert_expiry_line "$f")
      enddate="${line%%|*}"; days="${line##*|}"
      if [ "$enddate" = "INVALID" ]; then
        echo -e "  $domain: ${c_r}INVALID/EMPTY cert${c_0}"
      else
        echo "  $domain: $days days left"
      fi
    done
  else
    echo "  (none)"
  fi
}

kernel_tuning_menu() {
  echo ""
  echo "== Kernel / network tuning =="
  if [ -f "$SYSCTL_FILE" ]; then
    echo "File: $SYSCTL_FILE"
    cat "$SYSCTL_FILE"
  else
    warn "Tuning file not present."
  fi
  echo ""
  echo "Live values:"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_fastopen 2>/dev/null
  echo ""
  [ "$(ask "Re-apply sysctl --system now? (y/N)" "n")" = "y" ] && sysctl --system
}

backup_now() {
  mkdir -p "$BACKUP_DIR"
  local f="$BACKUP_DIR/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar czf "$f" "$CONF" "$CERT_BASE" "$SYSCTL_FILE" "$LINKS_FILE" 2>/dev/null
  log "Backup saved: $f"
}

view_logs() {
  journalctl -u "$SERVICE" -n 200 --no-pager
  pause
}

uninstall_all() {
  warn "This stops and removes sing-box, its config, service, and the menu tool."
  [ "$(ask "Also delete certificates under $CERT_BASE? (y/N)" "n")" = "y" ] && rm -rf "$CERT_BASE"
  [ "$(ask "Type YES to confirm full uninstall" "no")" = "YES" ] || { warn "Cancelled."; return; }
  systemctl stop "$SERVICE" 2>/dev/null
  systemctl disable "$SERVICE" 2>/dev/null
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  rm -f "$BIN" "$CONF" /usr/local/bin/singbox-menu
  rm -rf /usr/local/lib/singox_sh
  log "Uninstalled. Certs (if kept) remain under $CERT_BASE; sysctl tuning left in place."
  exit 0
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    status_dashboard
    echo ""
    echo -e "${c_b}=== singox_sh manager ===${c_0}"
    echo " 1) Refresh"
    echo " 2) List inbounds"
    echo " 3) Add inbound"
    echo " 4) Remove inbound"
    echo " 5) List saved client links"
    echo " 6) Certificates"
    echo " 7) Set public address/domain for links"
    echo " 8) Kernel/network tuning"
    echo " 9) View logs"
    echo "10) Backup config+certs now"
    echo "11) Restart service"
    echo "12) Live traffic totals"
    echo "13) Uninstall"
    echo " 0) Exit"
    case "$(ask "Choose" "1")" in
      1) : ;;
      2) list_inbounds; pause ;;
      3) add_inbound_menu ;;
      4) remove_inbound; pause ;;
      5) list_links; pause ;;
      6) cert_menu ;;
      7) set_address; pause ;;
      8) kernel_tuning_menu ;;
      9) view_logs ;;
      10) backup_now; pause ;;
      11) systemctl restart "$SERVICE" && log "Restarted." || err "Restart failed."; pause ;;
      12) show_traffic; pause ;;
      13) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main_menu
