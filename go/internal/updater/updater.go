package updater

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"syscall"
	"time"

	"github.com/nooblk-98/singox_sh/internal/paths"
	"github.com/nooblk-98/singox_sh/internal/ui"
)

type ghAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}
type ghRelease struct {
	TagName string    `json:"tag_name"`
	Assets  []ghAsset `json:"assets"`
}

func archSuffix() string {
	switch runtime.GOARCH {
	case "amd64":
		return "amd64"
	case "arm64":
		return "arm64"
	case "arm":
		return "armv7"
	default:
		return runtime.GOARCH
	}
}

// Update downloads the latest GitHub release binary for this OS/arch,
// replaces the currently-installed /usr/local/bin/singbox-menu, and
// re-execs it with --update so it also refreshes the sing-box binary,
// systemd units, and renew timer - not just the menu binary itself -
// before relaunching the menu. Unlike the bash version's git-based
// self-update, there's no separate lib/*.sh to keep in sync - it's one
// file.
func Update() {
	ui.Log("Checking for the latest singox_sh release...")
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases/latest", paths.RepoOwner, paths.RepoName)
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		ui.Err("Could not reach GitHub: %v", err)
		return
	}
	defer resp.Body.Close()
	var rel ghRelease
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil || rel.TagName == "" {
		ui.Err("Could not determine the latest release.")
		return
	}

	want := "singbox-menu-linux-" + archSuffix()
	var assetURL string
	for _, a := range rel.Assets {
		if a.Name == want {
			assetURL = a.BrowserDownloadURL
			break
		}
	}
	if assetURL == "" {
		ui.Err("No release asset found for linux-%s (%s).", archSuffix(), rel.TagName)
		return
	}

	ui.Log("Downloading %s (%s)...", rel.TagName, want)
	dlClient := &http.Client{Timeout: 5 * time.Minute}
	dresp, err := dlClient.Get(assetURL)
	if err != nil || dresp.StatusCode != 200 {
		ui.Err("Download failed.")
		return
	}
	defer dresp.Body.Close()

	tmp := paths.MenuLink + ".new"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		ui.Err("Could not write temp file: %v", err)
		return
	}
	if _, err := io.Copy(f, dresp.Body); err != nil {
		f.Close()
		os.Remove(tmp)
		ui.Err("Download failed: %v", err)
		return
	}
	f.Close()

	if err := os.Rename(tmp, paths.MenuLink); err != nil {
		ui.Err("Could not replace %s: %v", paths.MenuLink, err)
		return
	}
	ui.Log("Updated to %s. Refreshing sing-box, systemd units, and renew timer...", rel.TagName)
	time.Sleep(time.Second)

	if err := syscall.Exec(paths.MenuLink, []string{paths.MenuLink, "--update"}, os.Environ()); err != nil {
		ui.Err("Relaunch failed, run 'singbox-menu' manually: %v", err)
	}
}
