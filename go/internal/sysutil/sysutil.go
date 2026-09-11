package sysutil

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func Run(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func RunSilent(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	return cmd.Run()
}

func SystemctlIsActive(service string) bool {
	err := RunSilent("systemctl", "is-active", "--quiet", service)
	return err == nil
}

func SystemctlRestart(service string) error {
	return RunSilent("systemctl", "restart", service)
}

func SystemctlStop(service string) error {
	return RunSilent("systemctl", "stop", service)
}

func SystemctlStart(service string) error {
	return RunSilent("systemctl", "start", service)
}

// PortFree reports whether the given TCP/UDP port is free to bind on this
// host, by attempting an actual bind - more reliable than parsing `ss`
// output (which caused a real false-negative bug in the bash version).
func PortFree(port int, network string) bool {
	addr := fmt.Sprintf(":%d", port)
	if network == "udp" {
		l, err := net.ListenPacket("udp", addr)
		if err != nil {
			return false
		}
		l.Close()
		return true
	}
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return false
	}
	l.Close()
	return true
}

func RandHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func RandBase64(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func NewUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// RealityKeypair returns (privateKeyBase64URL, publicKeyBase64URL) for a
// VLESS Reality inbound, using stdlib X25519.
func RealityKeypair() (string, string, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	pub := priv.PublicKey()
	enc := base64.RawURLEncoding
	return enc.EncodeToString(priv.Bytes()), enc.EncodeToString(pub.Bytes()), nil
}

func PortInUseBySystemd(candidates []string) string {
	for _, svc := range candidates {
		if SystemctlIsActive(svc) {
			return svc
		}
	}
	return ""
}

func WaitFor(d time.Duration) { time.Sleep(d) }

func ParseIntOrZero(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0
	}
	return n
}
