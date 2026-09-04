# singox_sh

One-shot installer + interactive management menu for a [sing-box](https://sing-box.sagernet.org/) proxy relay server: VLESS (WS/gRPC/HTTPUpgrade/Reality), VMess, Trojan, Shadowsocks, Hysteria2, TUIC — with automatic TLS certificate management (acme.sh) and BBR/network tuning baked in.

Built from a real deployment (`xray2.itsnooblk.com`) — see the companion Trilium runbook for that server's specific history and benchmark numbers.

## Install on a fresh Ubuntu/Debian VPS

```sh
curl -fsSL https://raw.githubusercontent.com/nooblk-98/singox_sh/main/install.sh | sudo bash
```

or clone and run locally:

```sh
git clone https://github.com/nooblk-98/singox_sh.git
cd singox_sh
sudo ./install.sh
```

This installs sing-box (latest release), acme.sh, applies kernel network tuning (BBR + fq, TCP fastopen, larger buffers), sets up the systemd service, and installs the `singbox-menu` command.

Safe to re-run — it won't overwrite an existing config, only updates the binary/service/menu tool.

## Manage

```sh
singbox-menu
```

- **Add inbound** — pick a protocol, give it a port, everything else (UUID, keys, passwords, TLS cert) is generated/issued automatically. Prints (and saves) a ready-to-import client link.
- **Certificates** — lists all issued certs with expiry countdown and verifies each one's acme.sh renewal reload-hook actually matches this server's service name (catches the classic "cert renews but the running process never reloads it" bug).
- **Status dashboard**, **logs**, **kernel tuning view**, **backup**, **uninstall**.

Supported inbound types: VLESS+WS+TLS, VLESS+gRPC+TLS, VLESS+HTTPUpgrade+TLS, VLESS+Reality+Vision, VLESS+Reality (no Vision), VMess+WS+TLS, Trojan+TLS, Trojan+WS+TLS, Shadowsocks (2022 AEAD or classic), Hysteria2, TUIC v5.

## Notes

- Every config change is validated with `sing-box check` against a temp file before being applied — a bad edit never reaches the live config.
- Each new deployment gets fresh UUIDs/keys/passwords — nothing is hard-coded or reused across installs.
- TLS "SNI camouflage" setups (decoy SNI ≠ cert domain) need the client to set `verifyPeerCertByName` to the real cert domain — modern Xray-core removed `allowInsecure`, so this is the correct client-side counterpart. The menu warns you when you configure a mismatched SNI.
