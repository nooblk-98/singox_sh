#!/usr/bin/env bash

gen_uuid() { "$BIN" generate uuid; }
gen_hex()  { "$BIN" generate rand "${1:-8}" --hex; }
gen_b64()  { "$BIN" generate rand "${1:-16}" --base64; }

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

save_link() {
  local tag="$1" uri="$2"
  grep -v "^${tag}	" "$LINKS_FILE" > "${LINKS_FILE}.tmp" 2>/dev/null || true
  mv "${LINKS_FILE}.tmp" "$LINKS_FILE" 2>/dev/null || true
  printf '%s\t%s\n' "$tag" "$uri" >> "$LINKS_FILE"
  echo ""
  log "Client link (also saved, view any time via menu -> List links):"
  echo "$uri"
}

add_vless_ws_tls() {
  local port; port=$(ask_port)
  local domain; domain=$(ask "Domain (must already point DNS to this server; cert issued automatically if missing)")
  ensure_cert "$domain" || return
  default_address_to_domain "$domain"
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

add_vless_raw_tls() {
  local port; port=$(ask_port)
  local domain; domain=$(ask "Domain (must already point DNS to this server; cert issued automatically if missing)")
  ensure_cert "$domain" || return
  default_address_to_domain "$domain"
  local sni; sni=$(ask "SNI to present to clients (decoy domain, e.g. m.youtube.com; blank = same as cert domain)" "$domain")
  local uuid; uuid=$(gen_uuid)
  local tag="vless-tcp-tls-$port"
  local certdir="$CERT_BASE/$domain"
  local inbound
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --arg sni "$sni" --arg cert "$certdir/fullchain.pem" --arg key "$certdir/privkey.pem" '
    {type:"vless",tag:$tag,listen:"::",listen_port:$port,tcp_fast_open:true,
     users:[{uuid:$uuid,flow:""}],
     tls:{enabled:true,server_name:$sni,min_version:"1.2",max_version:"1.3",certificate_path:$cert,key_path:$key}}')
  jq --argjson nb "$inbound" '.inbounds += [$nb]' "$CONF" > /tmp/singbox_new.json
  validate_and_apply /tmp/singbox_new.json || return
  local addr; addr=$(get_address)
  local uri="vless://${uuid}@${addr}:${port}?type=tcp&security=tls&sni=${sni}&fp=chrome#${tag}"
  save_link "$tag" "$uri"
  [ "$sni" != "$domain" ] && warn "SNI differs from cert domain - client must set verifyPeerCertByName=$domain (Xray) or use the sing-box core, whose native insecure flag handles this without that workaround."
}

add_vless_transport_tls() {
  local transport="$1" label="$2"
  local port; port=$(ask_port)
  local domain; domain=$(ask "Domain (must already point DNS to this server; cert issued automatically if missing)")
  ensure_cert "$domain" || return
  default_address_to_domain "$domain"
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
  local with_vision="$1"
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
  local domain; domain=$(ask "Domain (must already point DNS to this server; cert issued automatically if missing)")
  ensure_cert "$domain" || return
  default_address_to_domain "$domain"
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
  local with_ws="$1"
  local port; port=$(ask_port)
  local domain; domain=$(ask "Domain (must already point DNS to this server; cert issued automatically if missing)")
  ensure_cert "$domain" || return
  default_address_to_domain "$domain"
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
  local port; port=$(ask_port "" udp)
  local domain; domain=$(ask "Domain (must already point DNS to this server; cert issued automatically if missing)")
  ensure_cert "$domain" || return
  default_address_to_domain "$domain"
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
  local port; port=$(ask_port "" udp)
  local domain; domain=$(ask "Domain (must already point DNS to this server; cert issued automatically if missing)")
  ensure_cert "$domain" || return
  default_address_to_domain "$domain"
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
  clear 2>/dev/null || true
  echo "== Add inbound - choose type =="
  echo "  1) VLESS + WS + TLS            (CDN-friendly camouflage)"
  echo "  2) VLESS + gRPC + TLS"
  echo "  3) VLESS + HTTPUpgrade + TLS"
  echo "  4) VLESS + TCP (raw) + TLS      (plain TLS, no WS framing)"
  echo "  5) VLESS + Reality + Vision     (fastest in our benchmarks, no cert needed)"
  echo "  6) VLESS + Reality (no Vision, less padding overhead)"
  echo "  7) VMess + WS + TLS"
  echo "  8) Trojan + TLS (raw)"
  echo "  9) Trojan + WS + TLS"
  echo " 10) Shadowsocks (2022 / classic AEAD)"
  echo " 11) Hysteria2 (QUIC/UDP)"
  echo " 12) TUIC v5 (QUIC/UDP)"
  echo "  0) Back"
  case "$(ask "Choose" "0")" in
    1) add_vless_ws_tls ;;
    2) add_vless_transport_tls grpc "gRPC" ;;
    3) add_vless_transport_tls httpupgrade "HTTPUpgrade" ;;
    4) add_vless_raw_tls ;;
    5) add_vless_reality y ;;
    6) add_vless_reality n ;;
    7) add_vmess_ws_tls ;;
    8) add_trojan n ;;
    9) add_trojan y ;;
    10) add_shadowsocks ;;
    11) add_hysteria2 ;;
    12) add_tuic ;;
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
