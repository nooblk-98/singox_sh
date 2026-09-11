package certs

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/go-acme/lego/v4/certcrypto"
	"github.com/go-acme/lego/v4/certificate"
	"github.com/go-acme/lego/v4/challenge/http01"
	"github.com/go-acme/lego/v4/lego"
	"github.com/go-acme/lego/v4/registration"

	"github.com/nooblk-98/singox_sh/internal/paths"
	"github.com/nooblk-98/singox_sh/internal/sysutil"
	"github.com/nooblk-98/singox_sh/internal/ui"
)

type accountFile struct {
	PrivateKeyPEM string                  `json:"private_key_pem"`
	Registration  *registration.Resource  `json:"registration,omitempty"`
}

type acmeUser struct {
	Registration *registration.Resource
	key          crypto.PrivateKey
}

func (u *acmeUser) GetEmail() string                        { return "" }
func (u *acmeUser) GetRegistration() *registration.Resource { return u.Registration }
func (u *acmeUser) GetPrivateKey() crypto.PrivateKey        { return u.key }

func loadOrCreateUser() (*acmeUser, error) {
	if b, err := os.ReadFile(paths.AcmeAccount); err == nil {
		var af accountFile
		if err := json.Unmarshal(b, &af); err == nil {
			block, _ := pem.Decode([]byte(af.PrivateKeyPEM))
			if block != nil {
				if key, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
					return &acmeUser{Registration: af.Registration, key: key}, nil
				}
			}
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return &acmeUser{key: key}, nil
}

func saveUser(u *acmeUser) error {
	keyBytes, err := x509.MarshalECPrivateKey(u.key.(*ecdsa.PrivateKey))
	if err != nil {
		return err
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	af := accountFile{PrivateKeyPEM: string(pemBytes), Registration: u.Registration}
	b, err := json.MarshalIndent(af, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(paths.AcmeAccount), 0700); err != nil {
		return err
	}
	return os.WriteFile(paths.AcmeAccount, b, 0600)
}

func newClient(user *acmeUser) (*lego.Client, error) {
	cfg := lego.NewConfig(user)
	cfg.CADirURL = lego.LEDirectoryProduction
	cfg.Certificate.KeyType = certcrypto.EC256
	client, err := lego.NewClient(cfg)
	if err != nil {
		return nil, err
	}
	if err := client.Challenge.SetHTTP01Provider(http01.NewProviderServer("", "80")); err != nil {
		return nil, err
	}
	return client, nil
}

func CertDir(domain string) string {
	return filepath.Join(paths.CertBase, domain)
}

// EnsureCert issues (via Let's Encrypt HTTP-01, using the stdlib-based lego
// library directly - no acme.sh, no shelling out, no external account/CA
// config files to get out of sync) a cert for domain if one isn't already
// present at CertDir(domain)/fullchain.pem.
func EnsureCert(domain string) error {
	certDir := CertDir(domain)
	fullchain := filepath.Join(certDir, "fullchain.pem")
	if _, err := os.Stat(fullchain); err == nil {
		return nil
	}
	ui.Log("No cert found for %s, issuing via Let's Encrypt (needs port 80 free)...", domain)

	blocker := ""
	if !sysutil.PortFree(80, "tcp") {
		ui.Warn("Port 80 is in use - HTTP-01 needs it free to issue a cert.")
		blocker = sysutil.PortInUseBySystemd([]string{"nginx", "apache2", "httpd", "caddy"})
		if blocker != "" {
			if ui.Confirm(fmt.Sprintf("Temporarily stop %s to issue the cert, then start it back up?", blocker), true) {
				sysutil.SystemctlStop(blocker)
			} else {
				if !ui.Confirm("Continue anyway?", false) {
					return fmt.Errorf("port 80 busy")
				}
				blocker = ""
			}
		} else if !ui.Confirm("Continue anyway?", false) {
			return fmt.Errorf("port 80 busy")
		}
	}
	defer func() {
		if blocker != "" {
			if err := sysutil.SystemctlStart(blocker); err != nil {
				ui.Warn("Failed to restart %s - start it manually.", blocker)
			}
		}
	}()

	user, err := loadOrCreateUser()
	if err != nil {
		return err
	}
	client, err := newClient(user)
	if err != nil {
		return err
	}
	if user.Registration == nil {
		reg, err := client.Registration.Register(registration.RegisterOptions{TermsOfServiceAgreed: true})
		if err != nil {
			return fmt.Errorf("account registration failed: %w", err)
		}
		user.Registration = reg
		if err := saveUser(user); err != nil {
			ui.Warn("Could not save acme account state: %v", err)
		}
	}

	res, err := client.Certificate.Obtain(certificate.ObtainRequest{
		Domains: []string{domain},
		Bundle:  true,
	})
	if err != nil {
		return fmt.Errorf("cert issuance failed for %s: %w", domain, err)
	}

	if err := os.MkdirAll(certDir, 0700); err != nil {
		return err
	}
	if err := os.WriteFile(fullchain, res.Certificate, 0644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(certDir, "privkey.pem"), res.PrivateKey, 0600); err != nil {
		return err
	}
	ui.Log("Cert issued and installed for %s.", domain)
	return nil
}

// RenewCert force-renews an already-issued cert, using the same account and
// port-80 handling as EnsureCert.
func RenewCert(domain string) error {
	certDir := CertDir(domain)
	fullchain := filepath.Join(certDir, "fullchain.pem")
	certBytes, err := os.ReadFile(fullchain)
	if err != nil {
		return fmt.Errorf("no existing cert for %s to renew", domain)
	}
	keyBytes, err := os.ReadFile(filepath.Join(certDir, "privkey.pem"))
	if err != nil {
		return fmt.Errorf("no existing private key for %s to renew", domain)
	}

	blocker := ""
	if !sysutil.PortFree(80, "tcp") {
		blocker = sysutil.PortInUseBySystemd([]string{"nginx", "apache2", "httpd", "caddy"})
		if blocker != "" && ui.Confirm(fmt.Sprintf("Temporarily stop %s to renew the cert?", blocker), true) {
			sysutil.SystemctlStop(blocker)
		} else {
			blocker = ""
		}
	}
	defer func() {
		if blocker != "" {
			sysutil.SystemctlStart(blocker)
		}
	}()

	user, err := loadOrCreateUser()
	if err != nil {
		return err
	}
	client, err := newClient(user)
	if err != nil {
		return err
	}

	res, err := client.Certificate.Renew(certificate.Resource{
		Domain:      domain,
		Certificate: certBytes,
		PrivateKey:  keyBytes,
	}, true, false, "")
	if err != nil {
		return fmt.Errorf("renewal failed for %s: %w", domain, err)
	}
	if err := os.WriteFile(fullchain, res.Certificate, 0644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(certDir, "privkey.pem"), res.PrivateKey, 0600); err != nil {
		return err
	}
	ui.Log("Renewed cert for %s.", domain)
	return nil
}

// RenewAll renews every cert with fewer than 30 days left, restarting the
// sing-box service once at the end if anything actually renewed. Meant to be
// called from a systemd timer (see installer.InstallRenewTimer) or manually.
func RenewAll() int {
	renewed := 0
	for _, c := range List() {
		if c.Invalid || c.Days >= 30 {
			continue
		}
		ui.Log("Renewing %s (%d days left)...", c.Domain, c.Days)
		if err := RenewCert(c.Domain); err != nil {
			ui.Err("%v", err)
			continue
		}
		renewed++
	}
	if renewed > 0 {
		if err := sysutil.SystemctlRestart(paths.Service); err != nil {
			ui.Warn("Renewed %d cert(s) but failed to restart %s - restart manually.", renewed, paths.Service)
		} else {
			ui.Log("Renewed %d cert(s) and restarted %s.", renewed, paths.Service)
		}
	}
	return renewed
}

type CertInfo struct {
	Domain  string
	Invalid bool
	Expires time.Time
	Days    int
}

func List() []CertInfo {
	entries, err := os.ReadDir(paths.CertBase)
	if err != nil {
		return nil
	}
	var out []CertInfo
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		domain := e.Name()
		fullchain := filepath.Join(paths.CertBase, domain, "fullchain.pem")
		info := CertInfo{Domain: domain}
		b, err := os.ReadFile(fullchain)
		if err != nil {
			info.Invalid = true
			out = append(out, info)
			continue
		}
		block, _ := pem.Decode(b)
		if block == nil {
			info.Invalid = true
			out = append(out, info)
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			info.Invalid = true
			out = append(out, info)
			continue
		}
		info.Expires = cert.NotAfter
		info.Days = int(time.Until(cert.NotAfter).Hours() / 24)
		out = append(out, info)
	}
	return out
}
