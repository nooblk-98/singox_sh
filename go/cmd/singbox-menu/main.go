package main

import (
	"fmt"
	"os"

	"github.com/nooblk-98/singox_sh/internal/certs"
	"github.com/nooblk-98/singox_sh/internal/installer"
	"github.com/nooblk-98/singox_sh/internal/menu"
	"github.com/nooblk-98/singox_sh/internal/ui"
	"github.com/nooblk-98/singox_sh/internal/version"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "install":
			runInstall(false)
			return
		case "--update":
			runInstall(true)
			return
		case "renew-all":
			menu.RequireRoot()
			n := certs.RenewAll()
			fmt.Printf("Renewed %d certificate(s).\n", n)
			return
		case "version", "--version", "-v":
			fmt.Println(version.Version)
			return
		}
	}
	menu.RequireRoot()
	menu.Run()
}

func runInstall(isUpdate bool) {
	menu.RequireRoot()
	if !isUpdate {
		// Only needed on a fresh install - tar is a base package that's
		// never going to have vanished by the time an update runs, and
		// apt-get update is the one step in this whole flow that's actually
		// slow/flaky in practice, so skip it here.
		installer.InstallDeps()
	}
	if err := installer.InstallSingBoxBinary(); err != nil {
		ui.Err("%v", err)
		os.Exit(1)
	}
	if err := installer.ApplySysctlTuning(); err != nil {
		ui.Err("%v", err)
	}
	if err := installer.WriteBaseConfig(); err != nil {
		ui.Err("%v", err)
		os.Exit(1)
	}
	if err := installer.InstallSystemdService(); err != nil {
		ui.Err("%v", err)
	}
	if err := installer.InstallSelf(); err != nil {
		ui.Err("%v", err)
		os.Exit(1)
	}
	if err := installer.InstallRenewTimer(); err != nil {
		ui.Warn("Could not install the cert-renewal timer: %v", err)
	}
	fmt.Println()
	ui.Log("Install complete.")
	fmt.Println("    Run:  singbox-menu")
	fmt.Println("    to add inbounds, manage certificates, and view status.")
	fmt.Println()
	if isUpdate {
		// Called via updater.Update()'s exec chain from an interactive menu
		// session - go straight back into the menu, no need to ask.
		menu.Run()
		return
	}
	if ui.Confirm("Launch the menu now?", true) {
		menu.Run()
	}
}
