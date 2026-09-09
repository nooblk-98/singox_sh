<div align="center">

# singox_sh

**One-shot installer and interactive manager for a [sing-box](https://sing-box.sagernet.org/) proxy relay server.**

Bootstraps sing-box, issues TLS certificates, tunes the kernel for throughput, and gives you a
menu to add protocols and hand out ready-to-import client links, with no hand-editing of JSON.

</div>

---

`singox_sh` turns a fresh Ubuntu/Debian/Alpine VPS into a working sing-box relay in one run. It
installs the latest sing-box release, sets up `acme.sh` for automatic certificate management,
applies BBR and network tuning, registers a systemd service, and installs a `singbox-menu`
command for day-to-day management.

Every inbound you add generates its own UUIDs, keys and passwords, validates against
`sing-box check` before going live, and prints a client link you can paste straight into your app.

## Features

- **12 inbound types** from a single menu: VLESS (WS / gRPC / HTTPUpgrade / raw TCP / Reality / Reality+Vision), VMess+WS, Trojan (raw / WS), Shadowsocks (2022 AEAD or classic), Hysteria2, TUIC v5.
- **Automatic TLS** via `acme.sh` standalone HTTP-01. Certificates are issued, installed, and wired to reload the service on renewal.
- **Reload-hook verification**: the certificate view checks that each `acme.sh` renewal hook actually reloads *this* server's service, catching the classic "cert renews but the process never picks it up" failure.
- **Safe config edits**: every change is checked against a temp file with `sing-box check`. A bad edit never reaches the live config, and the service is rolled forward only if it restarts cleanly.
- **Fresh secrets per install**: nothing is hard-coded or shared between deployments.
- **Kernel tuning**: BBR + `fq`, TCP Fast Open, MTU probing, and larger buffers written to `/etc/sysctl.d/99-network-tune.conf`.
- **Live traffic totals** via sing-box's Clash API, plus a status dashboard, log viewer, and one-command backup of config + certs.
- **Client links saved** to `/usr/local/etc/singbox-links.txt` and viewable any time from the menu.

## Getting started

On a fresh server, as root:

```sh
git clone https://github.com/nooblk-98/singox_sh.git
cd singox_sh
sudo ./install.sh
```

> [!NOTE]
> The installer copies `lib/menu.sh` from the checkout, so clone the repo rather than piping a
> single file. `gh repo clone nooblk-98/singox_sh` works too.

The installer is **safe to re-run**: it never overwrites an existing config, it only refreshes the
binary, service, and menu tool.

### Requirements

- Ubuntu / Debian (`apt`) or Alpine (`apk`); root access
- Ports **80** free during certificate issuance (HTTP-01), plus whatever ports your inbounds listen on
- A domain pointed at the server for any TLS-based inbound (Reality and Shadowsocks need no certificate)

## Usage

Run the menu at any time:

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
```

**Adding an inbound**: pick a protocol and a port. UUID, keys, passwords and the TLS certificate
(issued on the spot if missing) are all handled for you. The generated client link is printed and
saved.

**Certificates**: lists every issued cert with an expiry countdown and a reload-hook status
(`OK` / `MISMATCH`), and can issue, force-renew, or repair hooks for one or all domains.

> [!TIP]
> For "SNI camouflage" setups where the SNI shown to clients differs from the real certificate
> domain, the client must set `verifyPeerCertByName` to the real cert domain. Modern Xray-core
> removed `allowInsecure`. The menu warns you whenever you configure a mismatched SNI.

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/sing-box` | sing-box binary (latest release) |
| `/usr/local/etc/singbox-config.json` | Live configuration (never overwritten by the installer) |
| `/etc/systemd/system/sing-box.service` | systemd unit (`sing-box run -c …`) |
| `/etc/sysctl.d/99-network-tune.conf` | BBR + network tuning |
| `/usr/local/lib/singox_sh/menu.sh` | Management menu (symlinked as `singbox-menu`) |
| `/usr/local/etc/singbox-links.txt` | Saved client links |
| `/root/cert/<domain>/` | Installed certificate + key per domain |
| `/root/singbox-backups/` | Backup archives |

## Uninstall

From the menu, choose **Uninstall** (option 13). It stops and removes the service, binary, config,
and menu tool. Certificates and the sysctl tuning file are left in place unless you opt to remove
the certs when prompted.

## Repository layout

```
install.sh      # bootstrap: deps, sing-box, acme.sh, sysctl, systemd, menu
lib/menu.sh     # the singbox-menu management tool
```
