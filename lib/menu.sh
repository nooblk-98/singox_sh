#!/usr/bin/env bash

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for f in common certs inbounds status system update; do
  source "$LIB_DIR/$f.sh"
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
command -v jq >/dev/null || { echo "jq is required."; exit 1; }
touch "$LINKS_FILE"

main_menu() {
  while true; do
    clear 2>/dev/null || true
    status_dashboard
    echo ""
    echo -e "${c_b}=== singox_sh manager (v${VERSION}) ===${c_0}"
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
    echo "14) Update singox_sh (pull latest + relaunch)"
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
      14) update_singox ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main_menu
