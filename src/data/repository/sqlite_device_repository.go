package repository

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"

	"github.com/labstack/gommon/log"
	"github.com/zeusxprime/checkuser/src/domain/contract"
	"github.com/zeusxprime/checkuser/src/domain/entity"

	_ "github.com/ncruces/go-sqlite3/driver"
	_ "github.com/ncruces/go-sqlite3/embed"
)

func isRoot() bool {
	return os.Geteuid() == 0
}

func dbURI() string {
	if custom := os.Getenv("CHECKUSER_DB_PATH"); custom != "" {
		return custom
	}
	uri := `./db.sqlite3`
	if isRoot() {
		uri = `/root/db.sqlite3`
	}

	db, err := filepath.Abs(uri)
	if err != nil {
		return uri
	}
	return db
}

func migrateDevicesTable(db *sql.DB) {
	rows, err := db.Query(`PRAGMA table_info(devices)`)
	if err != nil {
		return
	}
	defer rows.Close()

	type column struct {
		name string
		pk   int
	}
	cols := []column{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notnull, pk int
		var dflt interface{}
		if err := rows.Scan(&cid, &name, &typ, &notnull, &dflt, &pk); err != nil {
			return
		}
		cols = append(cols, column{name: name, pk: pk})
	}
	if len(cols) == 0 {
		return
	}

	idPKOnly := false
	usernameInPK := false
	for _, c := range cols {
		if c.name == "id" && c.pk > 0 {
			idPKOnly = true
		}
		if c.name == "username" && c.pk > 0 {
			usernameInPK = true
		}
	}
	if !idPKOnly || usernameInPK {
		return
	}

	_, _ = db.Exec(`CREATE TABLE IF NOT EXISTS devices_v2 (id TEXT NOT NULL, username TEXT NOT NULL, PRIMARY KEY (id, username))`)
	_, _ = db.Exec(`INSERT OR IGNORE INTO devices_v2 (id, username) SELECT id, username FROM devices WHERE id IS NOT NULL AND username IS NOT NULL`)
	_, _ = db.Exec(`DROP TABLE devices`)
	_, _ = db.Exec(`ALTER TABLE devices_v2 RENAME TO devices`)
}

type SQLiteDeviceRepository struct {
	db *sql.DB
}

func NewSQLiteDeviceRepository() contract.DeviceRepository {
	db, err := sql.Open("sqlite3", dbURI())
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	_, _ = db.Exec(`PRAGMA busy_timeout = 3000`)
	_, _ = db.Exec(`PRAGMA journal_mode = WAL`)

	migrateDevicesTable(db)

	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS devices (
		id TEXT NOT NULL,
		username TEXT NOT NULL,
		PRIMARY KEY (id, username)
	)`)
	if err != nil {
		log.Fatal(err)
	}

	return &SQLiteDeviceRepository{db: db}
}

func (r *SQLiteDeviceRepository) Save(ctx context.Context, device *entity.Device) error {
	_, err := r.db.ExecContext(ctx, "INSERT OR IGNORE INTO devices (id, username) VALUES (?, ?)", device.ID, device.Username)
	if err != nil {
		return err
	}
	return nil
}

func (r *SQLiteDeviceRepository) Exists(ctx context.Context, device *entity.Device) bool {
	var count int
	err := r.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM devices WHERE id = ? AND username = ?", device.ID, device.Username).Scan(&count)
	if err != nil {
		return false
	}
	return count > 0
}

func (r *SQLiteDeviceRepository) ListByUsername(ctx context.Context, username string) ([]*entity.Device, error) {
	rows, err := r.db.QueryContext(ctx, "SELECT id, username FROM devices WHERE username = ?", username)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	devices := []*entity.Device{}
	for rows.Next() {
		device := &entity.Device{}
		err := rows.Scan(&device.ID, &device.Username)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	return devices, nil
}

func (r *SQLiteDeviceRepository) ListAll(ctx context.Context) ([]*entity.Device, error) {
	rows, err := r.db.QueryContext(ctx, "SELECT id, username FROM devices")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	devices := []*entity.Device{}
	for rows.Next() {
		device := &entity.Device{}
		err := rows.Scan(&device.ID, &device.Username)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	return devices, nil
}

func (r *SQLiteDeviceRepository) DeleteByUsername(ctx context.Context, username string) error {
	_, err := r.db.ExecContext(ctx, "DELETE FROM devices WHERE username = ?", username)
	if err != nil {
		return err
	}
	return nil
}

func (r *SQLiteDeviceRepository) CountByUsername(ctx context.Context, username string) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM devices WHERE username = ?", username).Scan(&count)
	if err != nil {
		return 0, err
	}
	return count, nil
}

func (r *SQLiteDeviceRepository) CountAll(ctx context.Context) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM devices").Scan(&count)
	if err != nil {
		return 0, err
	}
	return count, nil
}

func DeleteDB() {
	db, err := sql.Open("sqlite3", dbURI())
	if err != nil {
		log.Fatal(err)
	}

	_, err = db.Exec(`DROP TABLE IF EXISTS devices`)
	if err != nil {
		log.Fatal(err)
	}
}
