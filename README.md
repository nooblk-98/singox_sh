<div align="center">

# singox_sh

**One-shot installer and interactive manager for a [sing-box](https://sing-box.sagernet.org/) proxy relay server.**

Bootstraps sing-box, issues TLS certificates, tunes the kernel for throughput, and gives you a
menu to add protocols and hand out ready-to-import client links, with no hand-editing of JSON.

</div>

---

> [!NOTE]
> This `development` branch is a single-binary **Go rewrite** of the tool (previously a set of
> bash scripts on `main`). It's been built and verified against a real server, but hasn't had
> the extended real-world mileage `main`'s bash version has - see [Status](#status).

`singox_sh` turns a fresh Ubuntu/Debian/Alpine VPS into a working sing-box relay in one run. It
installs the latest sing-box release, issues TLS certificates via Let's Encrypt, applies BBR and
network tuning, registers a systemd service, and installs a `singbox-menu` command for
day-to-day management - all from one static binary with no runtime dependencies.

Every inbound you add generates its own UUIDs, keys and passwords, validates against
`sing-box check` before going live, and prints a client link you can paste straight into your app.

## Why a rewrite

- **One binary, no runtime dependencies.** No more `jq`, `acme.sh`, or a `lib/*.sh` directory
  that has to travel with `menu.sh` and stay in sync.
- **Native ACME (Let's Encrypt)** via the [lego](https://github.com/go-acme/lego) library
  instead of shelling out to `acme.sh`. This removes a whole class of bugs the bash version hit
  in practice: ZeroSSL's EAB requirement, invalid/reserved contact emails, and stale CA config
  files getting out of sync with reality.
- **Typed JSON config editing** instead of string-templated `jq` calls.
- **Real bind checks** (`net.Listen`) for port-free detection, instead of parsing `ss` output -
  which caused a real false-negative bug in the bash version.
- **Self-update pulls a versioned GitHub Release binary** instead of a git sync, so there's no
  CDN-caching surprises to design around.

## Features

- **12 inbound types** from a single menu: VLESS (WS / gRPC / HTTPUpgrade / raw TCP / Reality / Reality+Vision), VMess+WS, Trojan (raw / WS), Shadowsocks (2022 AEAD or classic), Hysteria2, TUIC v5.
- **Automatic TLS** via Let's Encrypt HTTP-01, issued and installed on the spot when a domain needs one.
- **Safe config edits**: every change is checked against a temp file with `sing-box check`. A bad edit never reaches the live config, and the service is rolled forward only if it restarts cleanly.
- **Fresh secrets per install**: nothing is hard-coded or shared between deployments.
- **Kernel tuning**: BBR + `fq`, TCP Fast Open, MTU probing, and larger buffers written to `/etc/sysctl.d/99-network-tune.conf`.
- **Live traffic totals** via sing-box's Clash API, plus a status dashboard, log viewer, and one-command backup of config + certs.
- **Client links saved** and viewable any time from the menu.
- **Daily auto-renewal** via a systemd timer that calls `singbox-menu renew-all`.

## Getting started

On a fresh server, as root:

```sh
curl -fsSL https://raw.githubusercontent.com/nooblk-98/singox_sh/development/go/install.sh | sudo bash
```

This downloads the right release binary for your server's architecture to
`/usr/local/bin/singbox-menu` and runs `singbox-menu install`.

The installer is **safe to re-run**: it never overwrites an existing config, it only refreshes the
sing-box binary, systemd units, and the menu tool itself.

### Requirements

- Linux, amd64/arm64/armv7, with `systemd`
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
                               14) Update singox_sh (pull latest + relaunch)
```

**Adding an inbound**: pick a protocol and a port. UUID, keys, passwords and the TLS certificate
(issued on the spot if missing) are all handled for you. The generated client link is printed and
saved.

**Certificates**: lists every issued cert with an expiry countdown, and can issue or force-renew
a domain on demand - auto-renewal itself runs daily via a systemd timer.

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/sing-box` | sing-box binary (latest release) |
| `/usr/local/bin/singbox-menu` | This tool - a single static binary |
| `/usr/local/etc/singbox-config.json` | Live configuration (never overwritten by the installer) |
| `/etc/systemd/system/sing-box.service` | systemd unit (`sing-box run -c …`) |
| `/etc/systemd/system/singbox-renew.{service,timer}` | Daily certificate renewal |
| `/etc/sysctl.d/99-network-tune.conf` | BBR + network tuning |
| `/usr/local/etc/singbox-links.txt` | Saved client links |
| `/root/cert/<domain>/` | Installed certificate + key per domain |
| `/root/.singbox-acme/account.json` | Let's Encrypt account key/registration |
| `/root/singbox-backups/` | Backup archives |

## Uninstall

From the menu, choose **Uninstall** (option 13). It stops and removes the service, binary, config,
and menu tool. Certificates and the sysctl tuning file are left in place unless you opt to remove
the certs when prompted.

## Status

Core flows are implemented and have been run against a real production server: install, all 12
inbound types, cert issuance/renewal, add/remove inbounds with live config validation and service
restart, the status dashboard, and self-update. Treat it as verified-but-young compared to the
bash version it replaces.

## Repository layout

```
go/                     the Go module - see go/README.md for build/release details
  cmd/singbox-menu/     entry point + subcommands (install, renew-all, menu)
  internal/             one package per concern (certs, config, inbounds, menu, ...)
  install.sh            curl-one-liner bootstrap that fetches the right release binary
.github/workflows/
  release-go.yml        cross-compiles + attaches binaries to a GitHub Release on a v*.*.* tag
  go-ci.yml             go build + go vet on every push to development touching go/
```
