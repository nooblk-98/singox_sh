# singox_sh (Go module)

The Go implementation of `singbox-menu` — see the [top-level README](../README.md) for install
and usage instructions. This document covers building, releasing, and the package layout.

## Why a rewrite

- **One binary, no runtime dependencies.** No more `jq`, `acme.sh`, or a `lib/*.sh` directory
  that has to travel with `menu.sh` and stay in sync.
- **Native ACME (Let's Encrypt) via [lego](https://github.com/go-acme/lego)** instead of
  shelling out to `acme.sh`. This removes an entire class of bugs the bash version hit in
  practice: ZeroSSL's EAB requirement, invalid/reserved contact emails, and stale
  `CA_EMAIL`/`ACCOUNT_EMAIL` config files getting out of sync with reality.
- **Typed JSON config editing** instead of `jq` string templates.
- **Real bind checks** (`net.Listen`) for port-free detection, instead of parsing `ss` output —
  which caused a real false-negative bug in the bash version.
- **Self-update pulls a versioned GitHub Release binary** instead of a git sync, so there's no
  CDN-caching surprises to design around.

## Status

Verified against a real production server: install (including cutover from the prior bash
install), all 12 inbound types, add/remove with live `sing-box check` validation and service
restart, the status dashboard, and certificate handling.

## Building

```sh
cd go
go build -o singbox-menu ./cmd/singbox-menu
```

Cross-compile for a target arch:

```sh
GOOS=linux GOARCH=arm64 go build -o singbox-menu-linux-arm64 ./cmd/singbox-menu
```

Set the version string at build time (the release workflow does this from the git tag):

```sh
go build -ldflags "-X github.com/nooblk-98/singox_sh/internal/version.Version=1.0.0" \
  -o singbox-menu ./cmd/singbox-menu
```

## Releasing

Pushing a tag matching `v*.*.*` triggers `.github/workflows/release-go.yml`, which
cross-compiles `linux/amd64`, `linux/arm64`, and `linux/armv7` binaries and attaches them to a
GitHub Release as `singbox-menu-linux-<arch>`. `.github/workflows/go-ci.yml` builds (all three
target arches) and vets on every push to `main` that touches `go/`.

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
