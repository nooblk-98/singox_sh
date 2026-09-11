#!/usr/bin/env bash

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

status_dashboard() {
  echo ""
  echo "== Status =="
  systemctl is-active --quiet "$SERVICE" && echo -e "Service:      ${c_g}active${c_0}" || echo -e "Service:      ${c_r}inactive${c_0}"
  echo "singox_sh:    v${VERSION}"
  echo "sing-box:     $("$BIN" version 2>/dev/null | head -1)"
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
