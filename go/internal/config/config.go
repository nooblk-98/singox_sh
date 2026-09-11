package config

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/nooblk-98/singox_sh/internal/paths"
	"github.com/nooblk-98/singox_sh/internal/sysutil"
	"github.com/nooblk-98/singox_sh/internal/ui"
)

type Config struct {
	data map[string]interface{}
}

func Skeleton() *Config {
	return &Config{data: map[string]interface{}{
		"log": map[string]interface{}{"level": "warn", "timestamp": true},
		"experimental": map[string]interface{}{
			"clash_api":  map[string]interface{}{"external_controller": paths.ClashAPIAddr},
			"cache_file": map[string]interface{}{"enabled": true},
		},
		"inbounds":  []interface{}{},
		"outbounds": []interface{}{map[string]interface{}{"type": "direct", "tag": "direct"}},
	}}
}

func Load() (*Config, error) {
	b, err := os.ReadFile(paths.Conf)
	if err != nil {
		return nil, err
	}
	var data map[string]interface{}
	if err := json.Unmarshal(b, &data); err != nil {
		return nil, err
	}
	return &Config{data: data}, nil
}

func Exists() bool {
	_, err := os.Stat(paths.Conf)
	return err == nil
}

func (c *Config) Save() error {
	b, err := json.MarshalIndent(c.data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(paths.Conf, b, 0644)
}

func (c *Config) inbounds() []interface{} {
	arr, _ := c.data["inbounds"].([]interface{})
	return arr
}

func (c *Config) Inbounds() []map[string]interface{} {
	var out []map[string]interface{}
	for _, item := range c.inbounds() {
		if m, ok := item.(map[string]interface{}); ok {
			out = append(out, m)
		}
	}
	return out
}

func (c *Config) AddInbound(ib map[string]interface{}) {
	c.data["inbounds"] = append(c.inbounds(), ib)
}

func (c *Config) RemoveInbound(tag string) bool {
	arr := c.inbounds()
	out := arr[:0]
	removed := false
	for _, item := range arr {
		if m, ok := item.(map[string]interface{}); ok && m["tag"] == tag {
			removed = true
			continue
		}
		out = append(out, item)
	}
	c.data["inbounds"] = out
	return removed
}

func (c *Config) PortInUse(port int, network string) bool {
	for _, ib := range c.Inbounds() {
		p, _ := ib["listen_port"].(float64)
		if int(p) != port {
			continue
		}
		t, _ := ib["type"].(string)
		ibNet := "tcp"
		if t == "hysteria2" || t == "tuic" {
			ibNet = "udp"
		}
		if ibNet == network {
			return true
		}
	}
	return false
}

func (c *Config) HasClashAPI() bool {
	exp, ok := c.data["experimental"].(map[string]interface{})
	if !ok {
		return false
	}
	_, ok = exp["clash_api"]
	return ok
}

func (c *Config) EnableClashAPI() {
	c.data["experimental"] = map[string]interface{}{
		"clash_api":  map[string]interface{}{"external_controller": paths.ClashAPIAddr},
		"cache_file": map[string]interface{}{"enabled": true},
	}
}

// ValidateAndApply writes the config to a temp file, validates it with
// `sing-box check`, and only overwrites the live config + restarts the
// service if that passes.
func ValidateAndApply(c *Config) error {
	b, err := json.MarshalIndent(c.data, "", "  ")
	if err != nil {
		return err
	}
	tmp := "/tmp/singbox_new.json"
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return err
	}
	out, err := sysutil.Run(paths.Bin, "check", "-c", tmp)
	if err != nil {
		ui.Err("Config validation failed, not applying:")
		fmt.Println(out)
		os.Remove(tmp)
		return fmt.Errorf("validation failed")
	}
	if err := os.Rename(tmp, paths.Conf); err != nil {
		return err
	}
	sysutil.SystemctlRestart(paths.Service)
	time.Sleep(time.Second)
	if !sysutil.SystemctlIsActive(paths.Service) {
		ui.Err("%s failed to start after applying config! Check: journalctl -u %s -n 50", paths.Service, paths.Service)
		return fmt.Errorf("service failed to start")
	}
	ui.Log("Applied and %s restarted successfully.", paths.Service)
	return nil
}
