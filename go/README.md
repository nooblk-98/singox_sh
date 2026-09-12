# singox_sh (Go module)

The implementation behind `singbox-menu` — see the [top-level README](../README.md) for install
and usage. This document covers building, releasing, and the package layout.

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
GitHub Release as `singbox-menu-linux-<arch>`. `.github/workflows/go-ci.yml` builds and vets on
every push to `main` that touches `go/`.

## Layout

```
cmd/singbox-menu/     entry point + subcommands (install, renew-all, stats-tick, menu)
internal/paths/       shared file/service path constants
internal/ui/          prompts, colors, log/warn/err
internal/sysutil/     process exec, port-free checks, random/UUID/keypair helpers
internal/config/      sing-box JSON config load/save/validate-and-apply
internal/certs/       Let's Encrypt issuance/renewal, cert listing
internal/db/          SQLite-backed store: address, links, all-time traffic totals
internal/stats/       folds live Clash API counters into persisted totals (stats-tick)
internal/store/       public address, saved links, reachability check
internal/inbounds/    the 12 inbound builders + add/remove/list screens
internal/menu/        the interactive menu
internal/installer/   sing-box binary download, systemd units, sysctl tuning
internal/updater/     self-update from the latest GitHub Release
internal/version/     version string, set via -ldflags at release build time
```
