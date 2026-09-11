#!/usr/bin/env bash

write_kernel_tuning() {
  cat > "$SYSCTL_FILE" <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
SYSCTL
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported issues, check manually."
}

kernel_tuning_menu() {
  clear 2>/dev/null || true
  echo "== Kernel / network tuning =="
  if [ -f "$SYSCTL_FILE" ]; then
    echo "File: $SYSCTL_FILE"
    cat "$SYSCTL_FILE"
  else
    warn "Tuning file not present - BBR is not currently configured."
    if [ "$(ask "Write and apply the BBR/network tuning file now? (Y/n)" "y")" != "n" ]; then
      write_kernel_tuning
      log "Wrote and applied $SYSCTL_FILE."
      cat "$SYSCTL_FILE"
    fi
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
