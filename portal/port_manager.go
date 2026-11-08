package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	// Import the SQLite driver.
	_ "github.com/mattn/go-sqlite3"
	"gopkg.in/yaml.v3"
)

// PortLease represents a single port allocation for a user job.
type PortLease struct {
	// Port is the allocated port number.
	Port int
	// JobID is the Slurm job ID associated with this lease.
	JobID int
	// Username is the owner of the job.
	Username string
	// NodeHostname is the hostname of the compute node where the job is running.
	NodeHostname string
	// NodeIP is the IP address of the compute node.
	NodeIP string
	// LeasedAt is the timestamp when the port was allocated.
	LeasedAt string
	// Status is the current state of the lease ("active" or "released").
	Status string
}

// PortManager handles the lifecycle of proxy ports for interactive applications.
// It persists leases in a SQLite database and generates dynamic Traefik configurations.
type PortManager struct {
	// db is the handle to the SQLite database.
	db *sql.DB
	// dbPath is the filesystem path to the SQLite database.
	dbPath string
	// portMin is the lower bound of the port range to manage.
	portMin int
	// portMax is the upper bound of the port range to manage.
	portMax int
	// traefikConfigDir is the directory where dynamic Traefik YAML files are written.
	traefikConfigDir string
}

// TraefikConfig represents the structure of Traefik's dynamic configuration.
type TraefikConfig struct {
	// HTTP defines the HTTP-specific configuration.
	HTTP struct {
		// Routers maps router names to their configurations.
		Routers map[string]map[string]interface{} `yaml:"routers"`
		// Services maps service names to their configurations.
		Services map[string]map[string]interface{} `yaml:"services"`
	} `yaml:"http"`
}

// NewPortManager initializes a new PortManager instance.
// It creates the database and Traefik config directories if they do not exist.
func NewPortManager(dbPath string, portMin, portMax int, traefikDir string) *PortManager {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		log.Printf("Warning: failed to create DB directory: %v", err)
	}
	if err := os.MkdirAll(traefikDir, 0755); err != nil {
		log.Printf("Warning: failed to create Traefik directory: %v", err)
	}

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

// initDB creates the necessary tables for lease management if they do not exist.
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

	if _, err := pm.db.Exec(query1); err != nil {
		log.Fatalf("Failed to create port_leases table: %v", err)
	}
	if _, err := pm.db.Exec(query2); err != nil {
		log.Fatalf("Failed to create port_queue table: %v", err)
	}

	var count int
	err := pm.db.QueryRow("SELECT COUNT(*) FROM port_queue").Scan(&count)
	if err != nil {
		log.Fatalf("Failed to query port_queue: %v", err)
	}
	if count == 0 {
		if _, err := pm.db.Exec("INSERT INTO port_queue (last_allocated_port) VALUES (?)", pm.portMin-1); err != nil {
			log.Fatalf("Failed to initialize port_queue: %v", err)
		}
	}
}

// getNextPortCircular finds the next available port using a circular allocation strategy.
func (pm *PortManager) getNextPortCircular() (int, error) {
	var lastPort int
	err := pm.db.QueryRow("SELECT last_allocated_port FROM port_queue WHERE id = 1").Scan(&lastPort)
	if err != nil {
		return 0, fmt.Errorf("failed to get last allocated port: %w", err)
	}

	nextPort := lastPort + 1
	if nextPort > pm.portMax {
		nextPort = pm.portMin
	}

	maxAttempts := pm.portMax - pm.portMin + 1
	for attempts := 0; attempts < maxAttempts; attempts++ {
		var existingPort int
		err := pm.db.QueryRow("SELECT port FROM port_leases WHERE port = ? AND status = 'active'", nextPort).Scan(&existingPort)
		if err == sql.ErrNoRows {
			if _, err := pm.db.Exec("UPDATE port_queue SET last_allocated_port = ? WHERE id = 1", nextPort); err != nil {
				return 0, fmt.Errorf("failed to update last allocated port: %w", err)
			}
			return nextPort, nil
		}
		nextPort++
		if nextPort > pm.portMax {
			nextPort = pm.portMin
		}
	}
	return 0, fmt.Errorf("no available ports")
}

// AllocatePort finds and reserves a port for a given job.
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
		return 0, fmt.Errorf("failed to insert lease: %w", err)
	}

	pm.updateTraefikRoutes()
	return port, nil
}

// ReleasePort marks a port lease as released and updates proxy configuration.
func (pm *PortManager) ReleasePort(jobID int) error {
	_, err := pm.db.Exec(`UPDATE port_leases SET status = 'released', released_at = ? WHERE job_id = ? AND status = 'active'`,
		time.Now().Format(time.RFC3339), jobID)
	if err == nil {
		pm.updateTraefikRoutes()
	}
	return err
}

// GetLeaseByJob retrieves the active port lease for a specific Slurm job ID.
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

// updateTraefikRoutes regenerates the dynamic Traefik routing configuration from active leases.
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
		if err := rows.Scan(&port, &jobID, &username, &nodeIP); err != nil {
			log.Printf("Error scanning lease row: %v", err)
			continue
		}

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

	yamlData, err := yaml.Marshal(&config)
	if err != nil {
		log.Printf("Error marshaling Traefik config: %v", err)
		return
	}
	if err := os.WriteFile(filepath.Join(pm.traefikConfigDir, "dynamic-routes.yml"), yamlData, 0644); err != nil {
		log.Printf("Error writing Traefik config: %v", err)
	}
}
