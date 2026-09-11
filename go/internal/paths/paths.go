package paths

const (
	Bin           = "/usr/local/bin/sing-box"
	Conf          = "/usr/local/etc/singbox-config.json"
	Service       = "sing-box"
	SysctlFile    = "/etc/sysctl.d/99-network-tune.conf"
	CertBase      = "/root/cert"
	AcmeAccount   = "/root/.singbox-acme/account.json"
	AddrFile      = "/usr/local/etc/singbox-address"
	LinksFile     = "/usr/local/etc/singbox-links.txt"
	ClashAPIAddr  = "127.0.0.1:9090"
	BackupDir     = "/root/singbox-backups"
	AppDir        = "/usr/local/lib/singox_sh"
	MenuLink      = "/usr/local/bin/singbox-menu"
	ServiceFile   = "/etc/systemd/system/sing-box.service"
	VersionFile   = "/usr/local/lib/singox_sh/VERSION"
	RepoOwner     = "nooblk-98"
	RepoName      = "singox_sh"
)
