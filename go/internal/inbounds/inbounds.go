package inbounds

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/nooblk-98/singox_sh/internal/certs"
	"github.com/nooblk-98/singox_sh/internal/config"
	"github.com/nooblk-98/singox_sh/internal/store"
	"github.com/nooblk-98/singox_sh/internal/sysutil"
	"github.com/nooblk-98/singox_sh/internal/ui"
)

func askPort(def string, network string) int {
	for {
		p := ui.Ask("Port", def)
		port, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil || port < 1 || port > 65535 {
			ui.Warn("Invalid port.")
			continue
		}
		cfg, err := config.Load()
		if err == nil && cfg.PortInUse(port, network) {
			ui.Warn("Port %d/%s already used by an existing inbound.", port, network)
			continue
		}
		if !sysutil.PortFree(port, network) {
			ui.Warn("Port %d/%s appears to be in use on the system.", port, network)
			if ui.Confirm("Use it anyway?", false) {
				return port
			}
			continue
		}
		return port
	}
}

func askDomain() string {
	domain := ui.Ask("Domain (must already point DNS to this server; cert issued automatically if missing)", "")
	if err := certs.EnsureCert(domain); err != nil {
		ui.Err("%v", err)
		return ""
	}
	store.DefaultAddressToDomain(domain)
	return domain
}

func urlenc(s string) string {
	return url.QueryEscape(s)
}

func mergeApply(cfg *config.Config, ib map[string]interface{}) error {
	cfg.AddInbound(ib)
	return config.ValidateAndApply(cfg)
}

func AddVlessWSTLS() {
	port := askPort("", "tcp")
	domain := askDomain()
	if domain == "" {
		return
	}
	sni := ui.Ask("SNI to present to clients (decoy domain, e.g. m.youtube.com; blank = same as cert domain)", domain)
	path := ui.Ask("WS path", "/"+sysutil.RandHex(6))
	uuid := sysutil.NewUUID()
	tag := fmt.Sprintf("vless-ws-tls-%d", port)
	certDir := certs.CertDir(domain)

	ib := map[string]interface{}{
		"type": "vless", "tag": tag, "listen": "::", "listen_port": port, "tcp_fast_open": true,
		"users": []interface{}{map[string]interface{}{"uuid": uuid, "flow": ""}},
		"transport": map[string]interface{}{
			"type": "ws", "path": path, "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol",
		},
		"multiplex": map[string]interface{}{"enabled": true},
		"tls": map[string]interface{}{
			"enabled": true, "server_name": sni, "min_version": "1.2", "max_version": "1.3",
			"alpn": []interface{}{"h2", "http/1.1"},
			"certificate_path": certDir + "/fullchain.pem", "key_path": certDir + "/privkey.pem",
		},
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	uri := fmt.Sprintf("vless://%s@%s:%d?type=ws&security=tls&path=%s&sni=%s&fp=chrome#%s",
		uuid, addr, port, urlenc(path), sni, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "tcp")
	if sni != domain {
		ui.Warn("SNI differs from cert domain - client must set verifyPeerCertByName=%s.", domain)
	}
}

func AddVlessRawTLS() {
	port := askPort("", "tcp")
	domain := askDomain()
	if domain == "" {
		return
	}
	sni := ui.Ask("SNI to present to clients (decoy domain, e.g. m.youtube.com; blank = same as cert domain)", domain)
	uuid := sysutil.NewUUID()
	tag := fmt.Sprintf("vless-tcp-tls-%d", port)
	certDir := certs.CertDir(domain)

	ib := map[string]interface{}{
		"type": "vless", "tag": tag, "listen": "::", "listen_port": port, "tcp_fast_open": true,
		"users": []interface{}{map[string]interface{}{"uuid": uuid, "flow": ""}},
		"tls": map[string]interface{}{
			"enabled": true, "server_name": sni, "min_version": "1.2", "max_version": "1.3",
			"certificate_path": certDir + "/fullchain.pem", "key_path": certDir + "/privkey.pem",
		},
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	uri := fmt.Sprintf("vless://%s@%s:%d?type=tcp&security=tls&sni=%s&fp=chrome#%s", uuid, addr, port, sni, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "tcp")
	if sni != domain {
		ui.Warn("SNI differs from cert domain - client must set verifyPeerCertByName=%s.", domain)
	}
}

func AddVlessTransport(transport string) {
	port := askPort("", "tcp")
	domain := askDomain()
	if domain == "" {
		return
	}
	sni := ui.Ask("SNI to present to clients", domain)
	uuid := sysutil.NewUUID()
	tag := fmt.Sprintf("vless-%s-tls-%d", transport, port)
	certDir := certs.CertDir(domain)

	var transportCfg map[string]interface{}
	var extraQS string
	if transport == "grpc" {
		svc := ui.Ask("gRPC service name", "grpc"+sysutil.RandHex(4))
		transportCfg = map[string]interface{}{"type": "grpc", "service_name": svc}
		extraQS = "type=grpc&serviceName=" + urlenc(svc)
	} else {
		path := ui.Ask("HTTP-Upgrade path", "/"+sysutil.RandHex(6))
		transportCfg = map[string]interface{}{"type": "httpupgrade", "path": path}
		extraQS = "type=httpupgrade&path=" + urlenc(path)
	}

	ib := map[string]interface{}{
		"type": "vless", "tag": tag, "listen": "::", "listen_port": port, "tcp_fast_open": true,
		"users":     []interface{}{map[string]interface{}{"uuid": uuid, "flow": ""}},
		"transport": transportCfg,
		"tls": map[string]interface{}{
			"enabled": true, "server_name": sni, "min_version": "1.2", "max_version": "1.3",
			"certificate_path": certDir + "/fullchain.pem", "key_path": certDir + "/privkey.pem",
		},
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	uri := fmt.Sprintf("vless://%s@%s:%d?security=tls&sni=%s&fp=chrome&%s#%s", uuid, addr, port, sni, extraQS, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "tcp")
	if sni != domain {
		ui.Warn("SNI differs from cert domain - client must set verifyPeerCertByName=%s.", domain)
	}
}

func AddVlessReality(withVision bool) {
	port := askPort("", "tcp")
	hsDomain := ui.Ask("Real site to mimic (Reality handshake target)", "m.youtube.com")
	hsPortStr := ui.Ask("Handshake port", "443")
	hsPort, _ := strconv.Atoi(hsPortStr)
	uuid := sysutil.NewUUID()
	priv, pub, err := sysutil.RealityKeypair()
	if err != nil {
		ui.Err("Failed to generate Reality keypair: %v", err)
		return
	}
	shortID := sysutil.RandHex(8)
	flow := ""
	tagSuffix := "reality"
	if withVision {
		flow = "xtls-rprx-vision"
		tagSuffix = "reality-vision"
	}
	tag := fmt.Sprintf("vless-%s-%d", tagSuffix, port)

	ib := map[string]interface{}{
		"type": "vless", "tag": tag, "listen": "::", "listen_port": port, "tcp_fast_open": true,
		"users": []interface{}{map[string]interface{}{"uuid": uuid, "flow": flow}},
		"tls": map[string]interface{}{
			"enabled": true, "server_name": hsDomain,
			"reality": map[string]interface{}{
				"enabled":     true,
				"handshake":   map[string]interface{}{"server": hsDomain, "server_port": hsPort},
				"private_key": priv,
				"short_id":    []interface{}{"", shortID},
			},
		},
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	flowQS := ""
	if flow != "" {
		flowQS = "&flow=" + flow
	}
	uri := fmt.Sprintf("vless://%s@%s:%d?type=tcp&security=reality%s&sni=%s&fp=chrome&pbk=%s&sid=%s&encryption=none#%s",
		uuid, addr, port, flowQS, hsDomain, pub, shortID, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "tcp")
}

func AddVmessWSTLS() {
	port := askPort("", "tcp")
	domain := askDomain()
	if domain == "" {
		return
	}
	sni := ui.Ask("SNI to present to clients", domain)
	path := ui.Ask("WS path", "/"+sysutil.RandHex(6))
	uuid := sysutil.NewUUID()
	tag := fmt.Sprintf("vmess-ws-tls-%d", port)
	certDir := certs.CertDir(domain)

	ib := map[string]interface{}{
		"type": "vmess", "tag": tag, "listen": "::", "listen_port": port,
		"users":     []interface{}{map[string]interface{}{"uuid": uuid, "alterId": 0}},
		"transport": map[string]interface{}{"type": "ws", "path": path},
		"tls": map[string]interface{}{
			"enabled": true, "server_name": sni,
			"certificate_path": certDir + "/fullchain.pem", "key_path": certDir + "/privkey.pem",
		},
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	vmessJSON := fmt.Sprintf(`{"v":"2","ps":"%s","add":"%s","port":"%d","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}`,
		tag, addr, port, uuid, sni, path, sni)
	uri := "vmess://" + base64.StdEncoding.EncodeToString([]byte(vmessJSON))
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "tcp")
	if sni != domain {
		ui.Warn("SNI differs from cert domain - client must set verifyPeerCertByName=%s.", domain)
	}
}

func AddTrojan(withWS bool) {
	port := askPort("", "tcp")
	domain := askDomain()
	if domain == "" {
		return
	}
	sni := ui.Ask("SNI to present to clients", domain)
	password := sysutil.RandBase64(16)
	certDir := certs.CertDir(domain)

	ib := map[string]interface{}{
		"type": "trojan", "tag": "", "listen": "::", "listen_port": port,
		"users": []interface{}{map[string]interface{}{"password": password}},
		"tls": map[string]interface{}{
			"enabled": true, "server_name": sni,
			"certificate_path": certDir + "/fullchain.pem", "key_path": certDir + "/privkey.pem",
		},
	}
	qs := ""
	tagSuffix := "tls"
	if withWS {
		path := ui.Ask("WS path", "/"+sysutil.RandHex(6))
		ib["transport"] = map[string]interface{}{"type": "ws", "path": path}
		qs = "&type=ws&path=" + urlenc(path)
		tagSuffix = "ws-tls"
	}
	tag := fmt.Sprintf("trojan-%s-%d", tagSuffix, port)
	ib["tag"] = tag

	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	uri := fmt.Sprintf("trojan://%s@%s:%d?security=tls&sni=%s%s#%s", password, addr, port, sni, qs, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "tcp")
	if sni != domain {
		ui.Warn("SNI differs from cert domain - client must set verifyPeerCertByName=%s.", domain)
	}
}

func AddShadowsocks() {
	port := askPort("", "tcp")
	fmt.Println("Methods: 1) 2022-blake3-aes-128-gcm  2) 2022-blake3-aes-256-gcm  3) aes-256-gcm  4) chacha20-ietf-poly1305")
	choice := ui.Ask("Choose method", "2")
	var method string
	switch choice {
	case "1":
		method = "2022-blake3-aes-128-gcm"
	case "3":
		method = "aes-256-gcm"
	case "4":
		method = "chacha20-ietf-poly1305"
	default:
		method = "2022-blake3-aes-256-gcm"
	}
	var password string
	if strings.HasPrefix(method, "2022-") {
		password = sysutil.RandBase64(32)
	} else {
		password = sysutil.RandBase64(16)
	}
	tag := fmt.Sprintf("ss-%d", port)

	ib := map[string]interface{}{
		"type": "shadowsocks", "tag": tag, "listen": "::", "listen_port": port,
		"method": method, "password": password,
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	userinfo := base64.StdEncoding.EncodeToString([]byte(method + ":" + password))
	uri := fmt.Sprintf("ss://%s@%s:%d#%s", userinfo, addr, port, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "tcp")
}

func AddHysteria2() {
	port := askPort("", "udp")
	domain := askDomain()
	if domain == "" {
		return
	}
	password := sysutil.RandBase64(16)
	masq := ui.Ask("Masquerade URL (decoy site shown to probers)", "https://m.youtube.com")
	tag := fmt.Sprintf("hysteria2-%d", port)
	certDir := certs.CertDir(domain)
	up, _ := strconv.Atoi(ui.Ask("Declared up_mbps (server upload to client)", "200"))
	down, _ := strconv.Atoi(ui.Ask("Declared down_mbps (server download from client)", "200"))

	ib := map[string]interface{}{
		"type": "hysteria2", "tag": tag, "listen": "::", "listen_port": port,
		"up_mbps": up, "down_mbps": down,
		"users":       []interface{}{map[string]interface{}{"password": password}},
		"masquerade":  map[string]interface{}{"type": "proxy", "url": masq},
		"tls": map[string]interface{}{
			"enabled": true, "server_name": domain, "alpn": []interface{}{"h3"},
			"certificate_path": certDir + "/fullchain.pem", "key_path": certDir + "/privkey.pem",
		},
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	uri := fmt.Sprintf("hysteria2://%s@%s:%d/?sni=%s&alpn=h3#%s", password, addr, port, domain, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "udp")
}

func AddTuic() {
	port := askPort("", "udp")
	domain := askDomain()
	if domain == "" {
		return
	}
	uuid := sysutil.NewUUID()
	password := sysutil.RandBase64(16)
	tag := fmt.Sprintf("tuic-%d", port)
	certDir := certs.CertDir(domain)

	ib := map[string]interface{}{
		"type": "tuic", "tag": tag, "listen": "::", "listen_port": port,
		"users":              []interface{}{map[string]interface{}{"uuid": uuid, "password": password}},
		"congestion_control": "bbr",
		"tls": map[string]interface{}{
			"enabled": true, "server_name": domain, "alpn": []interface{}{"h3"},
			"certificate_path": certDir + "/fullchain.pem", "key_path": certDir + "/privkey.pem",
		},
	}
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	if err := mergeApply(cfg, ib); err != nil {
		return
	}
	addr := store.GetAddress()
	uri := fmt.Sprintf("tuic://%s:%s@%s:%d?congestion_control=bbr&alpn=h3&sni=%s#%s", uuid, password, addr, port, domain, tag)
	store.SaveLink(tag, uri)
	store.CheckReachability(addr, port, "udp")
}

func List() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Println("(none)")
		return
	}
	fmt.Println()
	fmt.Println("== Inbounds ==")
	ibs := cfg.Inbounds()
	if len(ibs) == 0 {
		fmt.Println("(none)")
		return
	}
	for _, ib := range ibs {
		tag, _ := ib["tag"].(string)
		typ, _ := ib["type"].(string)
		port, _ := ib["listen_port"].(float64)
		fmt.Printf("  %-30s %-14s port %d\n", tag, typ, int(port))
	}
}

func Remove() {
	cfg, err := config.Load()
	if err != nil {
		ui.Err("%v", err)
		return
	}
	ibs := cfg.Inbounds()
	if len(ibs) == 0 {
		ui.Warn("No inbounds to remove.")
		return
	}
	fmt.Println()
	fmt.Println("== Inbounds ==")
	tags := make([]string, 0, len(ibs))
	for i, ib := range ibs {
		tag, _ := ib["tag"].(string)
		typ, _ := ib["type"].(string)
		port, _ := ib["listen_port"].(float64)
		tags = append(tags, tag)
		fmt.Printf("  %d) %-30s %-14s port %d\n", i+1, tag, typ, int(port))
	}
	sel := ui.Ask("Number to remove (or type exact tag)", "")
	tag := sel
	if n, err := strconv.Atoi(sel); err == nil && n >= 1 && n <= len(tags) {
		tag = tags[n-1]
	}
	if !cfg.RemoveInbound(tag) {
		ui.Err("No such tag.")
		return
	}
	if err := config.ValidateAndApply(cfg); err != nil {
		return
	}
	store.RemoveLink(tag)
	ui.Log("Removed %s.", tag)
}

func ListLinksScreen() {
	fmt.Println()
	fmt.Println("== Saved client links ==")
	links := store.ListLinks()
	if len(links) == 0 {
		fmt.Println("(none yet)")
		return
	}
	for tag, uri := range links {
		fmt.Printf("-- %s --\n%s\n\n", tag, uri)
	}
}
