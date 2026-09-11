package menu

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"strings"
	"time"

	"github.com/nooblk-98/singox_sh/internal/certs"
	"github.com/nooblk-98/singox_sh/internal/config"
	"github.com/nooblk-98/singox_sh/internal/inbounds"
	"github.com/nooblk-98/singox_sh/internal/paths"
	"github.com/nooblk-98/singox_sh/internal/store"
	"github.com/nooblk-98/singox_sh/internal/sysutil"
	"github.com/nooblk-98/singox_sh/internal/ui"
	"github.com/nooblk-98/singox_sh/internal/updater"
	"github.com/nooblk-98/singox_sh/internal/version"
)

func RequireRoot() {
	u, err := user.Current()
	if err != nil || u.Uid != "0" {
		fmt.Println("Run as root.")
		os.Exit(1)
	}
}

func Run() {
	for {
		ui.Clear()
		statusDashboard()
		fmt.Println()
		fmt.Printf("%s=== singox_sh manager (v%s) ===%s\n", ui.Blue, version.Version, ui.Reset)
		fmt.Println(" 1) Refresh")
		fmt.Println(" 2) List inbounds")
		fmt.Println(" 3) Add inbound")
		fmt.Println(" 4) Remove inbound")
		fmt.Println(" 5) List saved client links")
		fmt.Println(" 6) Certificates")
		fmt.Println(" 7) Set public address/domain for links")
		fmt.Println(" 8) Kernel/network tuning")
		fmt.Println(" 9) View logs")
		fmt.Println("10) Backup config+certs now")
		fmt.Println("11) Restart service")
		fmt.Println("12) Live traffic totals")
		fmt.Println("13) Uninstall")
		fmt.Println("14) Update singox_sh")
		fmt.Println(" 0) Exit")

		switch ui.Ask("Choose", "1") {
		case "1":
		case "2":
			inbounds.List()
			ui.Pause()
		case "3":
			addInboundMenu()
		case "4":
			inbounds.Remove()
			ui.Pause()
		case "5":
			inbounds.ListLinksScreen()
			ui.Pause()
		case "6":
			certMenu()
		case "7":
			setAddress()
			ui.Pause()
		case "8":
			kernelTuningMenu()
		case "9":
			viewLogs()
		case "10":
			backupNow()
			ui.Pause()
		case "11":
			if err := sysutil.SystemctlRestart(paths.Service); err != nil {
				ui.Err("Restart failed.")
			} else {
				ui.Log("Restarted.")
			}
			ui.Pause()
		case "12":
			showTraffic()
			ui.Pause()
		case "13":
			uninstallAll()
		case "14":
			updater.Update()
		case "0":
			os.Exit(0)
		default:
			ui.Warn("Invalid choice.")
		}
	}
}

func statusDashboard() {
	fmt.Println()
	fmt.Println("== Status ==")
	if sysutil.SystemctlIsActive(paths.Service) {
		fmt.Printf("Service:      %sactive%s\n", ui.Green, ui.Reset)
	} else {
		fmt.Printf("Service:      %sinactive%s\n", ui.Red, ui.Reset)
	}
	fmt.Printf("singox_sh:    v%s\n", version.Version)
	out, _ := sysutil.Run(paths.Bin, "version")
	fmt.Printf("sing-box:     %s\n", firstLine(out))
	fmt.Printf("Address:      %s\n", store.GetAddress())

	cfg, err := config.Load()
	count := 0
	if err == nil {
		count = len(cfg.Inbounds())
	}
	fmt.Printf("Inbounds:     %d (menu option 2 for details)\n", count)

	fmt.Println()
	fmt.Println("Certificates:")
	list := certs.List()
	if len(list) == 0 {
		fmt.Println("  (none)")
	}
	for _, c := range list {
		if c.Invalid {
			fmt.Printf("  %s%s: INVALID/EMPTY cert%s\n", ui.Red, c.Domain, ui.Reset)
		} else {
			fmt.Printf("  %s: %d days left\n", c.Domain, c.Days)
		}
	}
}

func firstLine(s string) string {
	i := strings.IndexByte(s, '\n')
	if i == -1 {
		return s
	}
	return s[:i]
}

func addInboundMenu() {
	ui.Clear()
	fmt.Println("== Add inbound - choose type ==")
	fmt.Println("  1) VLESS + WS + TLS            (CDN-friendly camouflage)")
	fmt.Println("  2) VLESS + gRPC + TLS")
	fmt.Println("  3) VLESS + HTTPUpgrade + TLS")
	fmt.Println("  4) VLESS + TCP (raw) + TLS      (plain TLS, no WS framing)")
	fmt.Println("  5) VLESS + Reality + Vision     (fastest in our benchmarks, no cert needed)")
	fmt.Println("  6) VLESS + Reality (no Vision, less padding overhead)")
	fmt.Println("  7) VMess + WS + TLS")
	fmt.Println("  8) Trojan + TLS (raw)")
	fmt.Println("  9) Trojan + WS + TLS")
	fmt.Println(" 10) Shadowsocks (2022 / classic AEAD)")
	fmt.Println(" 11) Hysteria2 (QUIC/UDP)")
	fmt.Println(" 12) TUIC v5 (QUIC/UDP)")
	fmt.Println("  0) Back")

	switch ui.Ask("Choose", "0") {
	case "1":
		inbounds.AddVlessWSTLS()
	case "2":
		inbounds.AddVlessTransport("grpc")
	case "3":
		inbounds.AddVlessTransport("httpupgrade")
	case "4":
		inbounds.AddVlessRawTLS()
	case "5":
		inbounds.AddVlessReality(true)
	case "6":
		inbounds.AddVlessReality(false)
	case "7":
		inbounds.AddVmessWSTLS()
	case "8":
		inbounds.AddTrojan(false)
	case "9":
		inbounds.AddTrojan(true)
	case "10":
		inbounds.AddShadowsocks()
	case "11":
		inbounds.AddHysteria2()
	case "12":
		inbounds.AddTuic()
	case "0":
		return
	default:
		ui.Warn("Invalid choice.")
	}
	ui.Pause()
}

func certMenu() {
	for {
		ui.Clear()
		fmt.Println("== Certificates ==")
		fmt.Printf("Auto-renewal: handled by the singbox-renew.timer installed alongside this tool (checks daily; run \"singbox-menu renew-all\" manually any time)\n")
		list := certs.List()
		if len(list) == 0 {
			fmt.Println("  (none yet)")
		}
		for _, c := range list {
			if c.Invalid {
				fmt.Printf("  %-30s %sINVALID/EMPTY cert - issuance likely failed%s\n", c.Domain, ui.Red, ui.Reset)
				continue
			}
			fmt.Printf("  %-30s expires %s (%d days)\n", c.Domain, c.Expires.Format("2006-01-02"), c.Days)
		}
		fmt.Println()
		fmt.Println("  1) Issue/repair cert for a domain")
		fmt.Println("  2) Force-renew a domain now")
		fmt.Println("  0) Back")
		switch ui.Ask("Choose", "0") {
		case "1":
			d := ui.Ask("Domain", "")
			if err := certs.EnsureCert(d); err != nil {
				ui.Err("%v", err)
			}
			ui.Pause()
		case "2":
			d := ui.Ask("Domain", "")
			if err := certs.RenewCert(d); err != nil {
				ui.Err("%v", err)
			}
			ui.Pause()
		case "0":
			return
		}
	}
}

func setAddress() {
	cur := store.GetAddress()
	newAddr := ui.Ask("Public address/domain clients should connect to", cur)
	store.SetAddress(newAddr)
	ui.Log("Saved. Existing links printed earlier won't auto-update - re-view them if needed.")
}

func kernelTuningMenu() {
	ui.Clear()
	fmt.Println("== Kernel / network tuning ==")
	if b, err := os.ReadFile(paths.SysctlFile); err == nil {
		fmt.Printf("File: %s\n%s\n", paths.SysctlFile, string(b))
	} else {
		ui.Warn("Tuning file not present - BBR is not currently configured.")
		if ui.Confirm("Write and apply the BBR/network tuning file now?", true) {
			if err := writeKernelTuning(); err != nil {
				ui.Err("%v", err)
			} else {
				ui.Log("Wrote and applied %s.", paths.SysctlFile)
			}
		}
	}
	fmt.Println()
	fmt.Println("Live values:")
	out, _ := sysutil.Run("sysctl", "net.ipv4.tcp_congestion_control", "net.core.default_qdisc", "net.ipv4.tcp_fastopen")
	fmt.Println(out)
	if ui.Confirm("Re-apply sysctl --system now?", false) {
		sysutil.RunSilent("sysctl", "--system")
	}
}

const sysctlTuning = `net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
`

func writeKernelTuning() error {
	if err := os.WriteFile(paths.SysctlFile, []byte(sysctlTuning), 0644); err != nil {
		return err
	}
	return sysutil.RunSilent("sysctl", "--system")
}

func backupNow() {
	os.MkdirAll(paths.BackupDir, 0755)
	name := fmt.Sprintf("%s/backup-%s.tar.gz", paths.BackupDir, timeStamp())
	cmd := exec.Command("tar", "czf", name, paths.Conf, paths.CertBase, paths.SysctlFile, paths.LinksFile)
	cmd.Run()
	ui.Log("Backup saved: %s", name)
}

func timeStamp() string {
	return time.Now().Format("20060102-150405")
}

func viewLogs() {
	cmd := exec.Command("journalctl", "-u", paths.Service, "-n", "200", "--no-pager")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Run()
	ui.Pause()
}

func showTraffic() {
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if !cfg.HasClashAPI() {
		ui.Log("Enabling sing-box's Clash API (needed for live traffic totals)...")
		cfg.EnableClashAPI()
		if err := config.ValidateAndApply(cfg); err != nil {
			return
		}
	}
	fmt.Println()
	fmt.Println("== Live traffic (since last sing-box restart) ==")
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://" + paths.ClashAPIAddr + "/connections")
	if err != nil {
		ui.Err("Could not reach Clash API - is sing-box running?")
		return
	}
	defer resp.Body.Close()
	var data struct {
		UploadTotal   int64 `json:"uploadTotal"`
		DownloadTotal int64 `json:"downloadTotal"`
		Connections   []struct {
			Metadata struct {
				Type string `json:"type"`
			} `json:"metadata"`
		} `json:"connections"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		ui.Err("Could not parse Clash API response.")
		return
	}
	fmt.Printf("Upload total:    %s\n", bytesHuman(data.UploadTotal))
	fmt.Printf("Download total:  %s\n", bytesHuman(data.DownloadTotal))
	fmt.Printf("Active connections: %d\n", len(data.Connections))
	if len(data.Connections) > 0 {
		byType := map[string]int{}
		for _, c := range data.Connections {
			byType[c.Metadata.Type]++
		}
		fmt.Println()
		fmt.Println("Active connections by inbound:")
		for t, n := range byType {
			fmt.Printf("  %4d %s\n", n, t)
		}
	}
	fmt.Println()
	ui.Warn("This counter resets whenever sing-box restarts - it's not persisted historical usage.")
}

func bytesHuman(b int64) string {
	units := []string{"B", "KB", "MB", "GB", "TB"}
	f := float64(b)
	i := 0
	for f >= 1024 && i < len(units)-1 {
		f /= 1024
		i++
	}
	return fmt.Sprintf("%.2f %s", f, units[i])
}

func uninstallAll() {
	ui.Warn("This stops and removes sing-box, its config, service, and the menu tool.")
	deleteCerts := ui.Confirm(fmt.Sprintf("Also delete certificates under %s?", paths.CertBase), false)
	confirm := ui.Ask("Type YES to confirm full uninstall", "no")
	if confirm != "YES" {
		ui.Warn("Cancelled.")
		return
	}
	if deleteCerts {
		os.RemoveAll(paths.CertBase)
	}
	sysutil.SystemctlStop(paths.Service)
	sysutil.RunSilent("systemctl", "disable", paths.Service)
	os.Remove(paths.ServiceFile)
	sysutil.RunSilent("systemctl", "daemon-reload")
	os.Remove(paths.Bin)
	os.Remove(paths.Conf)
	os.Remove(paths.MenuLink)
	os.RemoveAll(paths.AppDir)
	ui.Log("Uninstalled. Certs (if kept) remain under %s; sysctl tuning left in place.", paths.CertBase)
	os.Exit(0)
}
