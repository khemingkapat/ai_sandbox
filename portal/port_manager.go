package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"gopkg.in/yaml.v3"
)

type PortLease struct {
	Port         int
	JobID        int
	Username     string
	NodeHostname string
	NodeIP       string
	LeasedAt     string
	Status       string
}

type PortManager struct {
	db               *sql.DB
	dbPath           string
	portMin          int
	portMax          int
	traefikConfigDir string
}

type TraefikConfig struct {
	HTTP struct {
		Routers  map[string]map[string]interface{} `yaml:"routers"`
		Services map[string]map[string]interface{} `yaml:"services"`
	} `yaml:"http"`
}

func NewPortManager(dbPath string, portMin, portMax int, traefikDir string) *PortManager {
	os.MkdirAll(filepath.Dir(dbPath), os.ModePerm)
	os.MkdirAll(traefikDir, os.ModePerm)

	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	pm := &PortManager{
		db:               db,
		dbPath:           dbPath,
		portMin:          portMin,
		portMax:          portMax,
		traefikConfigDir: traefikDir,
	}
	pm.initDB()
	return pm
}

func (pm *PortManager) initDB() {
	query1 := `CREATE TABLE IF NOT EXISTS port_leases (
		port INTEGER PRIMARY KEY,
		job_id INTEGER,
		username TEXT,
		node_hostname TEXT,
		node_ip TEXT,
		leased_at TIMESTAMP,
		released_at TIMESTAMP,
		status TEXT DEFAULT 'active'
	);`
	query2 := `CREATE TABLE IF NOT EXISTS port_queue (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		last_allocated_port INTEGER DEFAULT 29999
	);`

	pm.db.Exec(query1)
	pm.db.Exec(query2)

	var count int
	pm.db.QueryRow("SELECT COUNT(*) FROM port_queue").Scan(&count)
	if count == 0 {
		pm.db.Exec("INSERT INTO port_queue (last_allocated_port) VALUES (?)", pm.portMin-1)
	}
}

func (pm *PortManager) getNextPortCircular() (int, error) {
	var lastPort int
	pm.db.QueryRow("SELECT last_allocated_port FROM port_queue WHERE id = 1").Scan(&lastPort)

	nextPort := lastPort + 1
	if nextPort > pm.portMax {
		nextPort = pm.portMin
	}

	maxAttempts := pm.portMax - pm.portMin + 1
	for attempts := 0; attempts < maxAttempts; attempts++ {
		var existingPort int
		err := pm.db.QueryRow("SELECT port FROM port_leases WHERE port = ? AND status = 'active'", nextPort).Scan(&existingPort)
		if err == sql.ErrNoRows {
			pm.db.Exec("UPDATE port_queue SET last_allocated_port = ? WHERE id = 1", nextPort)
			return nextPort, nil
		}
		nextPort++
		if nextPort > pm.portMax {
			nextPort = pm.portMin
		}
	}
	return 0, fmt.Errorf("no available ports")
}

func (pm *PortManager) AllocatePort(jobID int, username, nodeHostname, nodeIP string) (int, error) {
	port, err := pm.getNextPortCircular()
	if err != nil {
		return 0, err
	}

	_, err = pm.db.Exec(`INSERT OR REPLACE INTO port_leases 
		(port, job_id, username, node_hostname, node_ip, leased_at, status) 
		VALUES (?, ?, ?, ?, ?, ?, 'active')`,
		port, jobID, username, nodeHostname, nodeIP, time.Now().Format(time.RFC3339))
	
	if err != nil {
		return 0, err
	}

	pm.updateTraefikRoutes()
	return port, nil
}

func (pm *PortManager) ReleasePort(jobID int) error {
	_, err := pm.db.Exec(`UPDATE port_leases SET status = 'released', released_at = ? WHERE job_id = ? AND status = 'active'`,
		time.Now().Format(time.RFC3339), jobID)
	if err == nil {
		pm.updateTraefikRoutes()
	}
	return err
}

func (pm *PortManager) GetLeaseByJob(jobID int) (*PortLease, error) {
	var lease PortLease
	err := pm.db.QueryRow(`SELECT port, job_id, username, node_hostname, node_ip, leased_at, status 
		FROM port_leases WHERE job_id = ? AND status = 'active'`, jobID).Scan(
		&lease.Port, &lease.JobID, &lease.Username, &lease.NodeHostname, &lease.NodeIP, &lease.LeasedAt, &lease.Status)
	
	if err != nil {
		return nil, err
	}
	return &lease, nil
}

func (pm *PortManager) updateTraefikRoutes() {
	rows, err := pm.db.Query("SELECT port, job_id, username, node_ip FROM port_leases WHERE status = 'active'")
	if err != nil {
		log.Println("Error reading active leases:", err)
		return
	}
	defer rows.Close()

	config := TraefikConfig{}
	config.HTTP.Routers = make(map[string]map[string]interface{})
	config.HTTP.Services = make(map[string]map[string]interface{})

	for rows.Next() {
		var port, jobID int
		var username, nodeIP string
		rows.Scan(&port, &jobID, &username, &nodeIP)

		routerName := fmt.Sprintf("jupyter-job-%d", jobID)
		serviceName := fmt.Sprintf("jupyter-service-%d", jobID)

		config.HTTP.Routers[routerName] = map[string]interface{}{
			"rule":        fmt.Sprintf("PathPrefix(`/%s/jupyter/%d`)", username, jobID),
			"service":     serviceName,
			"entryPoints": []string{"web"},
		}

		config.HTTP.Services[serviceName] = map[string]interface{}{
			"loadBalancer": map[string]interface{}{
				"servers": []map[string]string{{"url": fmt.Sprintf("http://%s:%d", nodeIP, port)}},
			},
		}
	}

	yamlData, _ := yaml.Marshal(&config)
	os.WriteFile(filepath.Join(pm.traefikConfigDir, "dynamic-routes.yml"), yamlData, 0644)
}
