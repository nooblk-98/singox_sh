package installer

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/nooblk-98/singox_sh/internal/config"
	"github.com/nooblk-98/singox_sh/internal/paths"
	"github.com/nooblk-98/singox_sh/internal/sysutil"
	"github.com/nooblk-98/singox_sh/internal/ui"
)

func detectArch() (string, error) {
	switch runtime.GOARCH {
	case "amd64":
		return "amd64", nil
	case "arm64":
		return "arm64", nil
	case "arm":
		return "armv7", nil
	default:
		return "", fmt.Errorf("unsupported arch: %s", runtime.GOARCH)
	}
}

type ghAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}
type ghRelease struct {
	TagName string    `json:"tag_name"`
	Assets  []ghAsset `json:"assets"`
}

func InstallSingBoxBinary() error {
	if _, err := os.Stat(paths.Bin); err == nil {
		out, _ := sysutil.Run(paths.Bin, "version")
		ui.Log("sing-box already installed: %s", firstLine(out))
		if !ui.Confirm("Update to latest sing-box release?", false) {
			return nil
		}
	}
	arch, err := detectArch()
	if err != nil {
		return err
	}
	ui.Log("Fetching latest sing-box release info...")
	rel, err := fetchLatestRelease("SagerNet", "sing-box")
	if err != nil {
		return fmt.Errorf("could not determine latest sing-box version: %w", err)
	}
	ver := strings.TrimPrefix(rel.TagName, "v")
	want := fmt.Sprintf("sing-box-%s-linux-%s.tar.gz", ver, arch)
	var assetURL string
	for _, a := range rel.Assets {
		if a.Name == want {
			assetURL = a.BrowserDownloadURL
			break
		}
	}
	if assetURL == "" {
		return fmt.Errorf("could not find release asset %s", want)
	}
	ui.Log("Downloading sing-box %s (%s)...", rel.TagName, arch)
	tmp, err := os.MkdirTemp("", "singbox-dl")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	tgz := filepath.Join(tmp, "sb.tar.gz")
	if err := downloadFile(assetURL, tgz); err != nil {
		return fmt.Errorf("download failed: %w", err)
	}
	binPath, err := extractSingBoxBinary(tgz, tmp)
	if err != nil {
		return err
	}
	if err := copyFile(binPath, paths.Bin, 0755); err != nil {
		return err
	}
	out, _ := sysutil.Run(paths.Bin, "version")
	ui.Log("Installed: %s", firstLine(out))
	return nil
}

func fetchLatestRelease(owner, repo string) (*ghRelease, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases/latest", owner, repo)
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var rel ghRelease
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return nil, err
	}
	if rel.TagName == "" {
		return nil, fmt.Errorf("empty tag name in response")
	}
	return &rel, nil
}

func downloadFile(url, dest string) error {
	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP %d for %s", resp.StatusCode, url)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func extractSingBoxBinary(tgz, destDir string) (string, error) {
	f, err := os.Open(tgz)
	if err != nil {
		return "", err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return "", err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
		if filepath.Base(hdr.Name) != "sing-box" {
			continue
		}
		outPath := filepath.Join(destDir, "sing-box")
		out, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
		if err != nil {
			return "", err
		}
		if _, err := io.Copy(out, tr); err != nil {
			out.Close()
			return "", err
		}
		out.Close()
		return outPath, nil
	}
	return "", fmt.Errorf("sing-box binary not found in archive")
}

// copyFile writes to a temp file in dst's directory and renames it into
// place, rather than opening dst with O_TRUNC. If dst is a symlink (e.g.
// the bash version's /usr/local/bin/singbox-menu -> lib/menu.sh), O_TRUNC
// follows the link and clobbers whatever it points to instead of replacing
// the link itself - os.Rename replaces the link/file atomically instead.
func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	tmp := dst + ".new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i != -1 {
		return s[:i]
	}
	return s
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

func ApplySysctlTuning() error {
	if _, err := os.Stat(paths.SysctlFile); err == nil {
		ui.Log("Network tuning already present at %s", paths.SysctlFile)
		return nil
	}
	ui.Log("Writing network tuning to %s", paths.SysctlFile)
	if err := os.WriteFile(paths.SysctlFile, []byte(sysctlTuning), 0644); err != nil {
		return err
	}
	if err := sysutil.RunSilent("sysctl", "--system"); err != nil {
		ui.Warn("sysctl --system reported issues, check manually.")
	}
	return nil
}

func WriteBaseConfig() error {
	if config.Exists() {
		ui.Log("Existing config found at %s - leaving inbounds untouched.", paths.Conf)
		return nil
	}
	ui.Log("Writing base config skeleton to %s", paths.Conf)
	if err := os.MkdirAll(filepath.Dir(paths.Conf), 0755); err != nil {
		return err
	}
	return config.Skeleton().Save()
}

const serviceUnitTpl = `[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=%s run -c %s
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
`

func InstallSystemdService() error {
	ui.Log("Installing systemd service...")
	unit := fmt.Sprintf(serviceUnitTpl, paths.Bin, paths.Conf)
	if err := os.WriteFile(paths.ServiceFile, []byte(unit), 0644); err != nil {
		return err
	}
	sysutil.RunSilent("systemctl", "daemon-reload")
	sysutil.RunSilent("systemctl", "enable", "sing-box")
	if err := sysutil.SystemctlRestart(paths.Service); err != nil {
		ui.Warn("sing-box failed to start - check 'journalctl -u sing-box' (likely empty inbounds, that's fine until you add one).")
	}
	return nil
}

const renewServiceUnit = `[Unit]
Description=singox_sh certificate renewal

[Service]
Type=oneshot
ExecStart=/usr/local/bin/singbox-menu renew-all
`

const renewTimerUnit = `[Unit]
Description=Daily singox_sh certificate renewal check

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
`

// InstallRenewTimer sets up a daily systemd timer that calls
// `singbox-menu renew-all`, replacing acme.sh's cron job from the bash
// version now that cert issuance/renewal is a native Go library call.
func InstallRenewTimer() error {
	if err := os.WriteFile("/etc/systemd/system/singbox-renew.service", []byte(renewServiceUnit), 0644); err != nil {
		return err
	}
	if err := os.WriteFile("/etc/systemd/system/singbox-renew.timer", []byte(renewTimerUnit), 0644); err != nil {
		return err
	}
	sysutil.RunSilent("systemctl", "daemon-reload")
	sysutil.RunSilent("systemctl", "enable", "--now", "singbox-renew.timer")
	return nil
}

const statsServiceUnit = `[Unit]
Description=singox_sh traffic totals collector

[Service]
Type=oneshot
ExecStart=/usr/local/bin/singbox-menu stats-tick
`

const statsTimerUnit = `[Unit]
Description=Periodic singox_sh traffic totals collection

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
`

// InstallStatsTimer sets up a systemd timer that calls
// `singbox-menu stats-tick` every minute, folding sing-box's Clash API
// traffic counters (which reset to zero on every restart) into persisted,
// cumulative totals in the database.
func InstallStatsTimer() error {
	if err := os.WriteFile("/etc/systemd/system/singbox-stats.service", []byte(statsServiceUnit), 0644); err != nil {
		return err
	}
	if err := os.WriteFile("/etc/systemd/system/singbox-stats.timer", []byte(statsTimerUnit), 0644); err != nil {
		return err
	}
	sysutil.RunSilent("systemctl", "daemon-reload")
	sysutil.RunSilent("systemctl", "enable", "--now", "singbox-stats.timer")
	return nil
}

// InstallSelf copies the currently-running binary to /usr/local/bin/singbox-menu.
// Unlike the bash version, there's nothing else to copy - it's one binary.
func InstallSelf() error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(paths.AppDir, 0755); err != nil {
		return err
	}
	if err := copyFile(self, paths.MenuLink, 0755); err != nil {
		return err
	}
	ui.Log("Management command installed: run 'singbox-menu' any time.")
	return nil
}

// InstallDeps ensures the small set of external tools this tool still
// shells out to are present. Go's stdlib handles JSON, HTTP, TLS, and
// tar/gzip extraction natively, so this list is much shorter than the bash
// version's (no more jq, curl, acme.sh, or cron dependency).
func InstallDeps() {
	if _, err := exec.LookPath("apt-get"); err == nil {
		ui.Log("Installing dependencies (apt)...")
		sysutil.RunSilent("apt-get", "update", "-qq")
		if err := sysutil.RunSilent("apt-get", "install", "-y", "-qq", "tar"); err != nil {
			ui.Warn("apt-get install failed - ensure tar is installed.")
		}
		return
	}
	if _, err := exec.LookPath("apk"); err == nil {
		ui.Log("Installing dependencies (apk)...")
		sysutil.RunSilent("apk", "add", "--no-cache", "tar")
		return
	}
	ui.Warn("Unknown package manager - ensure tar is installed.")
}
