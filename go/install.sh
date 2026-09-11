#!/usr/bin/env bash

set -euo pipefail

REPO="nooblk-98/singox_sh"
DEST="/usr/local/bin/singbox-menu"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="singbox-menu-linux-${ARCH}"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

echo "Downloading ${ASSET}..."
curl -fsSL "$URL" -o "$DEST"
chmod +x "$DEST"

"$DEST" install
