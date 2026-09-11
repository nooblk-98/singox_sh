// Package stats folds sing-box's live (resets-on-restart) Clash API traffic
// counters into persisted, cumulative totals in the database. Meant to be
// invoked as a one-shot "tick" from a systemd timer (see
// installer.InstallStatsTimer), the same pattern already used for
// certificate renewal - not a long-running daemon.
package stats

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/nooblk-98/singox_sh/internal/db"
	"github.com/nooblk-98/singox_sh/internal/paths"
)

// Tick reads sing-box's current upload/download totals from the Clash API
// and accumulates the delta into the persisted totals. A quiet no-op (not
// an error) if the API isn't reachable - e.g. the service is down, or the
// Clash API hasn't been enabled yet - so the timer never needs babysitting.
func Tick() error {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("http://" + paths.ClashAPIAddr + "/connections")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	var data struct {
		UploadTotal   int64 `json:"uploadTotal"`
		DownloadTotal int64 `json:"downloadTotal"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return fmt.Errorf("could not parse Clash API response: %w", err)
	}
	return db.AccumulateTraffic(data.UploadTotal, data.DownloadTotal)
}
