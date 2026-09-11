#!/usr/bin/env bash

decode_reload_hook() {
  local domain="$1" conf="/root/.acme.sh/${domain}_ecc/${domain}.conf"
  [ -f "$conf" ] || { echo ""; return; }
  grep Le_ReloadCmd "$conf" 2>/dev/null | sed 's/.*START_//;s/__ACME.*//' | base64 -d 2>/dev/null
}

cert_expiry_line() {
  local f="$1" enddate
  enddate=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
  if [ -z "$enddate" ]; then
    echo "INVALID|"
    return
  fi
  local days=$(( ( $(date -d "$enddate" +%s) - $(date +%s) ) / 86400 ))
  echo "${enddate}|${days}"
}

acme_cron_installed() {
  crontab -l 2>/dev/null | grep -qE 'acme\.sh.*--cron'
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
  local blocker="" rc=0
  if ! port_free 80; then
    warn "Port 80 is in use - acme.sh --standalone needs it free to issue via HTTP-01."
    for svc in nginx apache2 httpd caddy; do
      if systemctl is-active --quiet "$svc" 2>/dev/null; then blocker="$svc"; break; fi
    done
    if [ -n "$blocker" ] && [ "$(ask "Temporarily stop $blocker to issue the cert, then start it back up? (Y/n)" "y")" != "n" ]; then
      systemctl stop "$blocker"
    else
      [ "$(ask "Continue anyway? (y/N)" "n")" = "y" ] || return 1
      blocker=""
    fi
  fi
  "$ACME" --issue -d "$domain" --standalone --keylength ec-256; rc=$?
  [ -n "$blocker" ] && { systemctl start "$blocker" || warn "Failed to restart $blocker - start it manually."; }
  if [ "$rc" -ne 0 ] && [ ! -f "/root/.acme.sh/${domain}_ecc/fullchain.cer" ]; then
    err "Cert issuance failed for $domain."
    return 1
  fi
  mkdir -p "$certdir"
  "$ACME" --install-cert -d "$domain" --ecc \
    --key-file "$certdir/privkey.pem" \
    --fullchain-file "$certdir/fullchain.pem" \
    --reloadcmd "systemctl restart $SERVICE"
  log "Cert issued and installed for $domain."
}

cert_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "== Certificates =="
    if acme_cron_installed; then
      echo -e "Auto-renewal cron: ${c_g}installed${c_0}"
    else
      echo -e "Auto-renewal cron: ${c_r}NOT installed${c_0} (option 4 to fix)"
    fi
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
    echo "  4) Install/repair auto-renewal cron job"
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
      4)
        "$ACME" --install-cronjob >/dev/null 2>&1 \
          && log "Auto-renewal cron job installed." \
          || err "Failed to install cron job - check manually with '$ACME --install-cronjob'."
        pause ;;
      0) return ;;
    esac
  done
}
