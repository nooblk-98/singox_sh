// Package db is the SQLite-backed store for state that previously lived in
// flat files (public address, saved client links) plus cumulative traffic
// totals - sing-box's own Clash API counters reset to zero on every
// restart, so persisting usage across restarts means tracking it ourselves.
//
// The sing-box config itself (singbox-config.json) stays a plain JSON file
// on purpose: sing-box reads it directly as a file path, so it can't move
// into the database without breaking sing-box itself.
package db

import (
	"database/sql"
	"os"
	"strings"
	"sync"

	_ "modernc.org/sqlite"

	"github.com/nooblk-98/singox_sh/internal/paths"
)

var (
	once sync.Once
	conn *sql.DB
	err  error
)

const schema = `
CREATE TABLE IF NOT EXISTS settings (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS links (
	tag TEXT PRIMARY KEY,
	uri TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS traffic_totals (
	id                 INTEGER PRIMARY KEY CHECK (id = 1),
	upload_bytes       INTEGER NOT NULL DEFAULT 0,
	download_bytes     INTEGER NOT NULL DEFAULT 0,
	last_seen_upload   INTEGER NOT NULL DEFAULT 0,
	last_seen_download INTEGER NOT NULL DEFAULT 0,
	updated_at         TEXT NOT NULL DEFAULT (datetime('now'))
);
`

func open() (*sql.DB, error) {
	once.Do(func() {
		// busy_timeout so the interactive menu and the once-a-minute
		// stats-tick process never hard-fail if they briefly collide on
		// the same file - they just wait up to 5s instead.
		conn, err = sql.Open("sqlite", paths.DBFile+"?_pragma=busy_timeout(5000)")
		if err != nil {
			return
		}
		conn.SetMaxOpenConns(1) // modernc.org/sqlite: one writer at a time
		if _, err = conn.Exec(schema); err != nil {
			return
		}
		migrateFlatFiles(conn)
	})
	return conn, err
}

// migrateFlatFiles imports the old ADDR_FILE/LINKS_FILE content into the
// database exactly once (only if the corresponding settings/links rows
// don't already exist), so upgrading an existing install doesn't lose the
// address or saved links it already had.
func migrateFlatFiles(c *sql.DB) {
	var count int
	c.QueryRow(`SELECT count(*) FROM settings WHERE key = 'address'`).Scan(&count)
	if count == 0 {
		if b, err := os.ReadFile(paths.AddrFile); err == nil {
			addr := strings.TrimSpace(string(b))
			if addr != "" {
				c.Exec(`INSERT OR REPLACE INTO settings (key, value) VALUES ('address', ?)`, addr)
			}
		}
	}

	c.QueryRow(`SELECT count(*) FROM links`).Scan(&count)
	if count == 0 {
		if b, err := os.ReadFile(paths.LinksFile); err == nil {
			for _, line := range strings.Split(string(b), "\n") {
				parts := strings.SplitN(line, "\t", 2)
				if len(parts) == 2 {
					c.Exec(`INSERT OR REPLACE INTO links (tag, uri) VALUES (?, ?)`, parts[0], parts[1])
				}
			}
		}
	}
}

func GetSetting(key string) (string, bool) {
	c, err := open()
	if err != nil {
		return "", false
	}
	var v string
	if err := c.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&v); err != nil {
		return "", false
	}
	return v, true
}

func SetSetting(key, value string) error {
	c, err := open()
	if err != nil {
		return err
	}
	_, err = c.Exec(`INSERT INTO settings (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

func SetLink(tag, uri string) error {
	c, err := open()
	if err != nil {
		return err
	}
	_, err = c.Exec(`INSERT INTO links (tag, uri) VALUES (?, ?)
		ON CONFLICT(tag) DO UPDATE SET uri = excluded.uri`, tag, uri)
	return err
}

func DeleteLink(tag string) error {
	c, err := open()
	if err != nil {
		return err
	}
	_, err = c.Exec(`DELETE FROM links WHERE tag = ?`, tag)
	return err
}

func ListLinks() (map[string]string, error) {
	c, err := open()
	if err != nil {
		return nil, err
	}
	rows, err := c.Query(`SELECT tag, uri FROM links`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var tag, uri string
		if err := rows.Scan(&tag, &uri); err != nil {
			continue
		}
		out[tag] = uri
	}
	return out, nil
}

type TrafficTotals struct {
	UploadBytes   int64
	DownloadBytes int64
}

func GetTrafficTotals() (TrafficTotals, error) {
	c, err := open()
	if err != nil {
		return TrafficTotals{}, err
	}
	var t TrafficTotals
	err = c.QueryRow(`SELECT upload_bytes, download_bytes FROM traffic_totals WHERE id = 1`).
		Scan(&t.UploadBytes, &t.DownloadBytes)
	if err == sql.ErrNoRows {
		return TrafficTotals{}, nil
	}
	return t, err
}

// AccumulateTraffic folds the latest absolute upload/download counters
// reported by sing-box's Clash API into the persisted cumulative totals.
// Those counters reset to 0 whenever sing-box restarts, so a drop versus
// the last-seen value is treated as "restarted, the new value is the full
// delta since then" rather than a negative delta.
func AccumulateTraffic(uploadNow, downloadNow int64) error {
	c, err := open()
	if err != nil {
		return err
	}
	var lastUp, lastDown int64
	err = c.QueryRow(`SELECT last_seen_upload, last_seen_download FROM traffic_totals WHERE id = 1`).
		Scan(&lastUp, &lastDown)
	if err != nil && err != sql.ErrNoRows {
		return err
	}

	deltaUp := uploadNow - lastUp
	if deltaUp < 0 {
		deltaUp = uploadNow
	}
	deltaDown := downloadNow - lastDown
	if deltaDown < 0 {
		deltaDown = downloadNow
	}

	_, err = c.Exec(`INSERT INTO traffic_totals (id, upload_bytes, download_bytes, last_seen_upload, last_seen_download, updated_at)
		VALUES (1, ?, ?, ?, ?, datetime('now'))
		ON CONFLICT(id) DO UPDATE SET
			upload_bytes = upload_bytes + excluded.upload_bytes,
			download_bytes = download_bytes + excluded.download_bytes,
			last_seen_upload = excluded.last_seen_upload,
			last_seen_download = excluded.last_seen_download,
			updated_at = excluded.updated_at`,
		deltaUp, deltaDown, uploadNow, downloadNow)
	return err
}
