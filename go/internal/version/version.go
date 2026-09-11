package version

// Version is set at build time via:
//   go build -ldflags "-X github.com/nooblk-98/singox_sh/internal/version.Version=1.4.0"
// The GitHub Actions release workflow sets it from the git tag.
var Version = "dev"
