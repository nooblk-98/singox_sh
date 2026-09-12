# singox_sh

[![CI](https://github.com/nooblk-98/singox_sh/actions/workflows/go-ci.yml/badge.svg)](https://github.com/nooblk-98/singox_sh/actions/workflows/go-ci.yml)
[![Release](https://img.shields.io/github/v/release/nooblk-98/singox_sh)](https://github.com/nooblk-98/singox_sh/releases/latest)

A single-binary installer and manager for [sing-box](https://sing-box.sagernet.org/) proxy relay
servers. Point it at a fresh Linux box and it installs sing-box, issues TLS certificates, tunes
the kernel, and gives you a `singbox-menu` command for everything else — no `jq`, no `acme.sh`,
no runtime dependencies.

Every inbound gets its own UUID, keys, and password, is checked with `sing-box check` before it
goes live, and comes with a ready-to-import client link.

## Features

- 12 inbound types: VLESS (WS, gRPC, HTTPUpgrade, raw TCP, Reality, Reality+Vision), VMess+WS, Trojan (raw/WS), Shadowsocks, Hysteria2, TUIC v5
- Automatic TLS via Let's Encrypt, issued the moment a domain needs one
- Every config change is validated against a temp file before it touches the live config, and rolled forward only if the service restarts cleanly
- Fresh secrets on every install — nothing shared or hard-coded
- BBR, `fq`, TCP Fast Open, and larger buffers applied automatically
- Live and all-time traffic totals, a status dashboard, log viewer, and one-command backups
- Client links saved and browsable from the menu
- Certificates and the tool itself both update on their own — daily renewal, one-command self-update

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/nooblk-98/singox_sh/main/go/install.sh | sudo bash
```

Detects your architecture, drops the matching release binary at `/usr/local/bin/singbox-menu`,
and runs `singbox-menu install`. Safe to re-run any time — it refreshes the binary, systemd
units, and sing-box itself without touching an existing config.

### Requirements

- Linux (amd64, arm64, or armv7) with systemd
- Port 80 free during certificate issuance, plus whatever ports your inbounds use
- A domain pointed at the server for any TLS-based inbound (Reality and Shadowsocks need none)

## Usage

```sh
singbox-menu
```

```
=== singox_sh manager ===
 1) Refresh                     7) Set public address/domain for links
 2) List inbounds               8) Kernel/network tuning
 3) Add inbound                 9) View logs
 4) Remove inbound             10) Backup config+certs now
 5) List saved client links    11) Restart service
 6) Certificates               12) Live traffic totals
                               13) Uninstall
                               14) Update singox_sh
```

Adding an inbound just asks for a protocol and a port — keys, passwords, and the certificate are
handled for you, and the client link is printed and saved. The certificates screen lists every
issued cert with its expiry, and can issue or force-renew on demand; auto-renewal itself runs
daily in the background.

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/sing-box` | sing-box binary |
| `/usr/local/bin/singbox-menu` | This tool |
| `/usr/local/etc/singbox-config.json` | Live configuration |
| `/usr/local/etc/singbox.db` | Public address, saved links, all-time traffic totals |
| `/etc/systemd/system/sing-box.service` | The sing-box service |
| `/etc/systemd/system/singbox-{renew,stats}.timer` | Daily cert renewal, per-minute traffic collection |
| `/etc/sysctl.d/99-network-tune.conf` | BBR + network tuning |
| `/root/cert/<domain>/` | Certificate + key per domain |
| `/root/.singbox-acme/account.json` | Let's Encrypt account |
| `/root/singbox-backups/` | Backup archives |

## Updating

- **The tool** — option 14 in the menu, or re-run the install command above; both pull the
  latest release and relaunch.
- **Certificates** — a systemd timer checks daily and renews anything close to expiry. Trigger it
  manually with `singbox-menu renew-all`.

## Uninstall

Menu option 13. Stops and removes the service, binary, config, and menu tool. Certificates and
the sysctl tuning file are left in place unless you opt to remove them when prompted.

---

Building from source or cutting a release? See [go/README.md](go/README.md).
