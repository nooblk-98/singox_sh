# singox_sh

**A single-binary installer and interactive manager for a [sing-box](https://sing-box.sagernet.org/) proxy relay server.**

`singox_sh` turns a fresh Linux VPS into a working sing-box relay in one command. It installs
the latest sing-box release, issues TLS certificates via Let's Encrypt, applies BBR and network
tuning, registers the systemd services it needs, and gives you a `singbox-menu` command for
day-to-day management — all from one static Go binary with no runtime dependencies.

Every inbound you add generates its own UUID, keys, and passwords, validates against
`sing-box check` before going live, and prints a client link you can paste straight into your app.

## Features

- **12 inbound types** from a single menu: VLESS (WS / gRPC / HTTPUpgrade / raw TCP / Reality / Reality+Vision), VMess+WS, Trojan (raw / WS), Shadowsocks (2022 AEAD or classic), Hysteria2, TUIC v5.
- **Automatic TLS** via Let's Encrypt HTTP-01 — issued and installed on the spot the moment a domain needs one.
- **Safe config edits.** Every change is checked against a temp file with `sing-box check`. A bad edit never reaches the live config, and the service is rolled forward only once it restarts cleanly.
- **Fresh secrets per install.** Nothing is hard-coded or shared between deployments.
- **Kernel tuning.** BBR + `fq`, TCP Fast Open, MTU probing, and larger buffers, written to `/etc/sysctl.d/99-network-tune.conf`.
- **Live traffic totals** via sing-box's Clash API, plus a status dashboard, log viewer, and one-command backup of config and certs.
- **Client links** saved to disk and viewable any time from the menu.
- **Daily certificate auto-renewal** via a systemd timer — no cron babysitting required.

## Install

On a fresh server, as root:

```sh
curl -fsSL https://raw.githubusercontent.com/nooblk-98/singox_sh/main/go/install.sh | sudo bash
```

This detects your server's architecture, downloads the matching release binary to
`/usr/local/bin/singbox-menu`, and runs `singbox-menu install`.

> [!NOTE]
> The installer is safe to re-run. It never overwrites an existing sing-box config — it only
> refreshes the sing-box binary, systemd units, and the menu tool itself.

### Requirements

- Linux (amd64, arm64, or armv7) with `systemd`
- Port **80** free during certificate issuance (HTTP-01), plus whatever ports your inbounds use
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
                               14) Update singox_sh
```

**Adding an inbound** — pick a protocol and a port. The UUID, keys, passwords, and TLS
certificate (issued on the spot if missing) are all handled for you, and the generated client
link is printed and saved.

**Certificates** — lists every issued cert with an expiry countdown, and lets you issue or
force-renew a domain on demand. Auto-renewal itself runs daily in the background.

## Updating

Two independent things get updated automatically or on demand:

- **singox_sh itself** — choose **Update singox_sh** (option 14) in the menu. It downloads the
  latest release from GitHub and relaunches. You can also re-run the install one-liner above at
  any time; it's idempotent.
- **Certificates** — a `singbox-renew.timer` installed alongside the tool checks daily and
  renews anything nearing expiry, restarting sing-box once if anything actually renewed. Trigger
  it manually with `singbox-menu renew-all`.

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/sing-box` | sing-box binary (latest release) |
| `/usr/local/bin/singbox-menu` | This tool — a single static binary |
| `/usr/local/etc/singbox-config.json` | Live configuration (never overwritten by the installer) |
| `/etc/systemd/system/sing-box.service` | systemd unit (`sing-box run -c …`) |
| `/etc/systemd/system/singbox-renew.{service,timer}` | Daily certificate renewal |
| `/etc/sysctl.d/99-network-tune.conf` | BBR + network tuning |
| `/usr/local/etc/singbox-links.txt` | Saved client links |
| `/root/cert/<domain>/` | Installed certificate + key per domain |
| `/root/.singbox-acme/account.json` | Let's Encrypt account key and registration |
| `/root/singbox-backups/` | Backup archives |

## Uninstall

From the menu, choose **Uninstall** (option 13). It stops and removes the service, binary,
config, and menu tool. Certificates and the sysctl tuning file are left in place unless you opt
to remove the certs when prompted.

## Repository layout

```
go/                     the Go module - see go/README.md for build, release, and package details
  cmd/singbox-menu/     entry point + subcommands (install, renew-all, menu)
  internal/             one package per concern (certs, config, inbounds, menu, ...)
  install.sh            curl one-liner that fetches the right release binary for your arch
.github/workflows/
  release-go.yml        cross-compiles and attaches binaries to a GitHub Release on a v*.*.* tag
  go-ci.yml             builds (all target arches) and vets on every push to main touching go/
```

> [!TIP]
> Building from source, cross-compiling, or cutting a release? See [go/README.md](go/README.md).
