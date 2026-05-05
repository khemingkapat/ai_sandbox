package ports

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"portal/models"

	_ "github.com/mattn/go-sqlite3"
	"gopkg.in/yaml.v3"
)

// PortManager allocates and tracks proxy ports for running jobs,
// and keeps Traefik's dynamic routing config in sync.
type PortManager struct {
	db               *sql.DB
	portMin          int
	portMax          int
	traefikConfigDir string
}

type traefikConfig struct {
	HTTP struct {
		Routers  map[string]map[string]interface{} `yaml:"routers"`
		Services map[string]map[string]interface{} `yaml:"services"`
	} `yaml:"http"`
}

// NewPortManager opens (or creates) the SQLite lease database and returns a ready manager.
func NewPortManager(dbPath string, portMin, portMax int, traefikDir string) *PortManager {
	os.MkdirAll(filepath.Dir(dbPath), os.ModePerm)
	os.MkdirAll(traefikDir, os.ModePerm)

	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		log.Fatalf("Failed to open port lease database: %v", err)
	}

	pm := &PortManager{db: db, portMin: portMin, portMax: portMax, traefikConfigDir: traefikDir}
	pm.initDB()
	return pm
}

func (pm *PortManager) initDB() {
	pm.db.Exec(`CREATE TABLE IF NOT EXISTS port_leases (
		port INTEGER PRIMARY KEY,
		job_id INTEGER,
		username TEXT,
		node_hostname TEXT,
		node_ip TEXT,
		leased_at TIMESTAMP,
		released_at TIMESTAMP,
		status TEXT DEFAULT 'active'
	)`)
	pm.db.Exec(`CREATE TABLE IF NOT EXISTS port_queue (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		last_allocated_port INTEGER DEFAULT 29999
	)`)

	var count int
	pm.db.QueryRow("SELECT COUNT(*) FROM port_queue").Scan(&count)
	if count == 0 {
		pm.db.Exec("INSERT INTO port_queue (last_allocated_port) VALUES (?)", pm.portMin-1)
	}
}

// AllocatePort finds the next free port and records the lease.
func (pm *PortManager) AllocatePort(jobID int, username, nodeHostname, nodeIP string) (int, error) {
	port, err := pm.nextFreePort()
	if err != nil {
		return 0, err
	}
	_, err = pm.db.Exec(
		`INSERT OR REPLACE INTO port_leases (port, job_id, username, node_hostname, node_ip, leased_at, status)
		 VALUES (?, ?, ?, ?, ?, ?, 'active')`,
		port, jobID, username, nodeHostname, nodeIP, time.Now().Format(time.RFC3339),
	)
	if err != nil {
		return 0, err
	}
	pm.syncTraefik()
	return port, nil
}

// ReleasePort marks the lease for jobID as released.
func (pm *PortManager) ReleasePort(jobID int) error {
	_, err := pm.db.Exec(
		`UPDATE port_leases SET status = 'released', released_at = ? WHERE job_id = ? AND status = 'active'`,
		time.Now().Format(time.RFC3339), jobID,
	)
	if err == nil {
		pm.syncTraefik()
	}
	return err
}

// GetLeaseByJob returns the active lease for a job, or nil if none exists.
func (pm *PortManager) GetLeaseByJob(jobID int) (*models.PortLease, error) {
	var l models.PortLease
	err := pm.db.QueryRow(
		`SELECT port, job_id, username, node_hostname, node_ip, leased_at, status
		 FROM port_leases WHERE job_id = ? AND status = 'active'`, jobID,
	).Scan(&l.Port, &l.JobID, &l.Username, &l.NodeHostname, &l.NodeIP, &l.LeasedAt, &l.Status)
	if err != nil {
		return nil, err
	}
	return &l, nil
}

func (pm *PortManager) nextFreePort() (int, error) {
	var last int
	pm.db.QueryRow("SELECT last_allocated_port FROM port_queue WHERE id = 1").Scan(&last)

	next := last + 1
	if next > pm.portMax {
		next = pm.portMin
	}

	for attempts := 0; attempts < pm.portMax-pm.portMin+1; attempts++ {
		var existing int
		err := pm.db.QueryRow(
			"SELECT port FROM port_leases WHERE port = ? AND status = 'active'", next,
		).Scan(&existing)
		if err == sql.ErrNoRows {
			pm.db.Exec("UPDATE port_queue SET last_allocated_port = ? WHERE id = 1", next)
			return next, nil
		}
		next++
		if next > pm.portMax {
			next = pm.portMin
		}
	}
	return 0, fmt.Errorf("no available ports in range %d-%d", pm.portMin, pm.portMax)
}

// syncTraefik rewrites the dynamic Traefik config from the current active leases.
func (pm *PortManager) syncTraefik() {
	rows, err := pm.db.Query("SELECT port, job_id, username, node_ip FROM port_leases WHERE status = 'active'")
	if err != nil {
		log.Println("syncTraefik: error reading active leases:", err)
		return
	}
	defer rows.Close()

	cfg := traefikConfig{}
	cfg.HTTP.Routers = make(map[string]map[string]interface{})
	cfg.HTTP.Services = make(map[string]map[string]interface{})

	for rows.Next() {
		var port, jobID int
		var username, nodeIP string
		rows.Scan(&port, &jobID, &username, &nodeIP)

		rName := fmt.Sprintf("jupyter-job-%d", jobID)
		sName := fmt.Sprintf("jupyter-service-%d", jobID)

		cfg.HTTP.Routers[rName] = map[string]interface{}{
			"rule":        fmt.Sprintf("PathPrefix(`/%s/jupyter/%d`)", username, jobID),
			"service":     sName,
			"entryPoints": []string{"web"},
		}
		cfg.HTTP.Services[sName] = map[string]interface{}{
			"loadBalancer": map[string]interface{}{
				"servers": []map[string]string{{"url": fmt.Sprintf("http://%s:%d", nodeIP, port)}},
			},
		}
	}

	data, _ := yaml.Marshal(&cfg)
	os.WriteFile(filepath.Join(pm.traefikConfigDir, "dynamic-routes.yml"), data, 0644)
}
