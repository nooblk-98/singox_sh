package store

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/nooblk-98/singox_sh/internal/db"
	"github.com/nooblk-98/singox_sh/internal/ui"
)

func GetAddress() string {
	if addr, ok := db.GetSetting("address"); ok && addr != "" {
		return addr
	}
	ip := detectIP()
	db.SetSetting("address", ip)
	return ip
}

func detectIP() string {
	client := &http.Client{Timeout: 5 * time.Second}
	for _, url := range []string{"https://api.ipify.org", "https://ifconfig.me"} {
		resp, err := client.Get(url)
		if err != nil {
			continue
		}
		b, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err == nil && len(b) > 0 {
			return strings.TrimSpace(string(b))
		}
	}
	return "127.0.0.1"
}

func SetAddress(addr string) {
	db.SetSetting("address", addr)
}

// DefaultAddressToDomain seeds the public address with domain the first
// time it's ever set (i.e. before the user has explicitly picked one via
// the menu), since a real TLS domain is a more useful default than the
// bare auto-detected IP.
func DefaultAddressToDomain(domain string) {
	if _, ok := db.GetSetting("address"); ok {
		return
	}
	db.SetSetting("address", domain)
	ui.Log("Using %s as your public address for client links (menu option 7 to change).", domain)
}

func SaveLink(tag, uri string) {
	db.SetLink(tag, uri)
	fmt.Println()
	ui.Log("Client link (also saved, view any time via menu -> List links):")
	fmt.Println(uri)
}

func RemoveLink(tag string) {
	db.DeleteLink(tag)
}

func ListLinks() map[string]string {
	links, err := db.ListLinks()
	if err != nil {
		return map[string]string{}
	}
	return links
}

type checkHostResp struct {
	RequestID string `json:"request_id"`
}

// CheckReachability runs a best-effort external TCP reachability probe via
// check-host.net right after an inbound is created, so a firewall/security
// group block is caught immediately instead of discovered later from a
// client that can't connect. UDP inbounds aren't checked (see the note this
// prints instead) since that free API doesn't reliably support it.
func CheckReachability(addr string, port int, network string) {
	if network != "tcp" {
		ui.Warn("UDP reachability isn't checked automatically - test with a real client, or check your firewall/security group for UDP %d.", port)
		return
	}
	ui.Log("Checking external reachability of %s:%d (best-effort, via check-host.net)...", addr, port)
	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Get(fmt.Sprintf("https://check-host.net/check-tcp?host=%s:%d&max_nodes=2", addr, port))
	if err != nil {
		ui.Warn("Reachability check unavailable right now - verify manually if clients can't connect.")
		return
	}
	var chr checkHostResp
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err := json.Unmarshal(b, &chr); err != nil || chr.RequestID == "" {
		ui.Warn("Reachability check unavailable right now - verify manually if clients can't connect.")
		return
	}

	var result map[string][]map[string]interface{}
	for i := 0; i < 5; i++ {
		time.Sleep(3 * time.Second)
		r, err := client.Get("https://check-host.net/check-result/" + chr.RequestID)
		if err != nil {
			continue
		}
		rb, _ := io.ReadAll(r.Body)
		r.Body.Close()
		if err := json.Unmarshal(rb, &result); err != nil {
			continue
		}
		done := false
		for _, nodeResults := range result {
			for _, res := range nodeResults {
				if _, ok := res["time"]; ok {
					done = true
				}
				if _, ok := res["error"]; ok {
					done = true
				}
			}
		}
		if done {
			break
		}
	}

	reachable := false
	got := false
	for _, nodeResults := range result {
		for _, res := range nodeResults {
			if _, ok := res["time"]; ok {
				reachable = true
				got = true
			}
			if _, ok := res["error"]; ok {
				got = true
			}
		}
	}
	switch {
	case reachable:
		ui.Log("Port %d is reachable from outside.", port)
	case got:
		ui.Warn("Port %d does NOT appear reachable from outside - check firewall/security group rules (ufw, cloud provider firewall, NAT) before sharing this link.", port)
	default:
		ui.Warn("Reachability check inconclusive - verify manually if clients can't connect.")
	}
}
