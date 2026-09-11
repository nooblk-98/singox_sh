# singox_sh (Go rewrite - work in progress)

A single-binary rewrite of the `singbox-menu` tool, replacing the bash
implementation on `main`. Lives on the `development` branch until it has
real-world testing behind it.

## Why

- **One binary, no runtime dependencies.** No more `jq`, `acme.sh`, or a
  `lib/*.sh` directory that has to travel with `menu.sh` and stay in sync.
- **Native ACME (Let's Encrypt) via [lego](https://github.com/go-acme/lego)**
  instead of shelling out to `acme.sh`. This removes an entire class of bugs
  hit in the bash version: ZeroSSL's EAB requirement, invalid/reserved
  contact emails, and stale `CA_EMAIL`/`ACCOUNT_EMAIL` config files getting
  out of sync with reality.
- **Typed JSON config editing** instead of `jq` string templates.
- **A real HTTP client with actual bind checks** for port-free detection
  (`net.Listen`), instead of parsing `ss` output - which caused a real
  false-negative bug in the bash version.
- Self-update pulls a versioned GitHub Release binary instead of `git
  fetch`, so there's no CDN-caching surprises to design around (the
  `raw.githubusercontent.com` issue the bash version had to work around).

## Status

Core flows are implemented: install, all 12 inbound types, cert
issuance/renewal, the status dashboard, kernel tuning, backups, uninstall,
and self-update. It has **not** yet been run against a real server the way
the bash version was throughout this project - treat it as a first pass
that needs real testing before it replaces `main`.

## Building

```sh
cd go
go build -o singbox-menu ./cmd/singbox-menu
```

Cross-compile for a target arch:

```sh
GOOS=linux GOARCH=arm64 go build -o singbox-menu-linux-arm64 ./cmd/singbox-menu
```

## Installing on a server

```sh
curl -fsSL https://raw.githubusercontent.com/nooblk-98/singox_sh/development/go/install.sh | sudo bash
```

This downloads the right release binary for the server's arch to
`/usr/local/bin/singbox-menu` and runs `singbox-menu install`.

## Releasing

Pushing a tag matching `v*.*.*` triggers `.github/workflows/release-go.yml`,
which cross-compiles `linux/amd64`, `linux/arm64`, and `linux/armv7`
binaries and attaches them to a GitHub Release as
`singbox-menu-linux-<arch>`. `.github/workflows/go-ci.yml` runs `go build`
and `go vet` on every push to `development` that touches `go/`.

## Layout

```
cmd/singbox-menu/     entry point + subcommands (install, renew-all, menu)
internal/paths/       shared file/service path constants
internal/ui/          prompts, colors, log/warn/err
internal/sysutil/     process exec, port-free checks, random/UUID/keypair helpers
internal/config/      sing-box JSON config load/save/validate-and-apply
internal/certs/       Let's Encrypt issuance/renewal via lego, cert listing
internal/store/       public address, saved links, reachability check
internal/inbounds/    the 12 inbound builders + add/remove/list screens
internal/menu/        the interactive menu itself
internal/installer/   sing-box binary download, systemd units, sysctl tuning
internal/updater/     self-update from the latest GitHub Release
internal/version/     version string, set via -ldflags at release build time
```
