#!/usr/bin/env bash

update_singox() {
  command -v git >/dev/null 2>&1 || { err "git is required to update but was not found."; return; }
  log "Fetching latest singox_sh via git (raw.githubusercontent.com is CDN-cached, so we don't use it here)..."
  if [ -d "$SRC_DIR/.git" ]; then
    if ! { git -C "$SRC_DIR" fetch --depth 1 origin main >/dev/null 2>&1 \
        && git -C "$SRC_DIR" reset --hard origin/main >/dev/null 2>&1; }; then
      warn "git update of $SRC_DIR failed, re-cloning..."
      rm -rf "$SRC_DIR"
    fi
  fi
  if [ ! -d "$SRC_DIR/.git" ]; then
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || { err "git clone failed."; return; }
  fi
  log "Running installer (updates sing-box binary, deps, and this menu)..."
  if bash "$SRC_DIR/install.sh" --update; then
    log "Update complete. Relaunching menu..."
    sleep 1
    exec /usr/local/bin/singbox-menu
  else
    err "Update failed - see output above. Your existing install is untouched."
  fi
}
