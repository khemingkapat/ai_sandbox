package services

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
	"log"

	"portal/models"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/ssh"
)


// SlurmService handles all communication with the Slurm REST API.
type SlurmService struct {
	BaseURL       string
	jwtKeyPath    string
	TokenLifespan int
}

// NewSlurmService creates a SlurmService from configuration values.
func NewSlurmService(baseURL, jwtKeyPath string, tokenLifespan int) *SlurmService {
	return &SlurmService{
		BaseURL:       baseURL,
		jwtKeyPath:    jwtKeyPath,
		TokenLifespan: tokenLifespan,
	}
}

// ReadKey loads the HS256 signing key from disk.
// Re-read on each call so key rotation is picked up automatically.
func (s *SlurmService) ReadKey() ([]byte, error) {
	return os.ReadFile(s.jwtKeyPath)
}

// MakeToken creates a signed JWT for the given user/project pair.
func (s *SlurmService) MakeToken(username, project string) (string, error) {
	key, err := s.ReadKey()
	if err != nil {
		return "", fmt.Errorf("reading JWT key: %w", err)
	}
	claims := jwt.MapClaims{
		"sun": username,
		"prj": project,
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(time.Duration(s.TokenLifespan) * time.Second).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(key)
}

// FetchAccessMatrix returns a map of username -> []project queried from slurmdbd.
func (s *SlurmService) FetchAccessMatrix() map[string][]string {
	matrix := make(map[string][]string)

	adminToken, err := s.MakeToken("root", "root")
	if err != nil {
		return matrix
	}

	req, err := http.NewRequest(http.MethodGet, s.BaseURL+"/slurmdb/v0.0.42/associations", nil)
	if err != nil {
		return matrix
	}
	req.Header.Set("X-SLURM-USER-TOKEN", adminToken)
	req.Header.Set("X-SLURM-USER-NAME", "root")
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		return matrix
	}
	defer resp.Body.Close()

	var result struct {
		Associations []struct {
			User    string `json:"user"`
			Account string `json:"account"`
		} `json:"associations"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return matrix
	}
	for _, a := range result.Associations {
		if a.User != "" && a.Account != "" {
			matrix[a.User] = append(matrix[a.User], a.Account)
		}
	}
	if len(matrix["root"]) == 0 {
		matrix["root"] = []string{"root_project"}
	}
	return matrix
}

// Do executes an authenticated JSON request against the Slurm REST API.
// Pass body=nil for requests with no payload (GET, DELETE).
// The caller is responsible for closing resp.Body on success.
func (s *SlurmService) Do(ctx context.Context, method, path, username, token string, body interface{}) (*http.Response, error) {
	var buf *bytes.Buffer
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("marshalling request body: %w", err)
		}
		buf = bytes.NewBuffer(data)
	} else {
		buf = bytes.NewBuffer(nil)
	}

	req, err := http.NewRequestWithContext(ctx, method, s.BaseURL+path, buf)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-SLURM-USER-TOKEN", token)
	req.Header.Set("X-SLURM-USER-NAME", username)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 15 * time.Second}
	return client.Do(req)
}
// SlurmJob represents a single job
type SlurmJob struct {
	JobState []string `json:"job_state"`
}

// SlurmJobsResponse represents the list of jobs
type SlurmJobsResponse struct {
	Jobs []SlurmJob `json:"jobs"`
}

// SlurmNode represents a single compute node
type SlurmNode struct {
	State []string `json:"state"`
}

// SlurmNodesResponse represents the list of nodes from the API
type SlurmNodesResponse struct {
	Nodes []SlurmNode `json:"nodes"`
}

// CheckPendingQueue checks if the number of active/pending jobs 
// is greater than or equal to the number of available nodes.
func (s *SlurmService) CheckPendingQueue(ctx context.Context, username, token string) (bool, error) {
	// 1. Get total number of nodes
	nodeResp, err := s.Do(ctx, http.MethodGet, "/slurm/v0.0.42/nodes", username, token, nil)
	if err != nil {
		return false, fmt.Errorf("failed to fetch nodes: %w", err)
	}
	defer nodeResp.Body.Close()

	var nodesResult SlurmNodesResponse
	if err := json.NewDecoder(nodeResp.Body).Decode(&nodesResult); err != nil {
		return false, fmt.Errorf("failed to decode nodes: %w", err)
	}
	totalNodes := len(nodesResult.Nodes)

	// 2. Get current jobs
	jobResp, err := s.Do(ctx, http.MethodGet, "/slurm/v0.0.42/jobs", username, token, nil)
	if err != nil {
		return false, fmt.Errorf("failed to fetch jobs: %w", err)
	}
	defer jobResp.Body.Close()

	var jobsResult SlurmJobsResponse
	if err := json.NewDecoder(jobResp.Body).Decode(&jobsResult); err != nil {
		return false, fmt.Errorf("failed to decode jobs: %w", err)
	}

	// 3. Count jobs that are taking up a "slot" (Running or Pending)
	activeJobCount := 0
	for _, job := range jobsResult.Jobs {
		if len(job.JobState) > 0 {
			state := job.JobState[0]
			if state == "RUNNING" || state == "PENDING" {
				activeJobCount++
			}
		}
	}

	// 4. Return true if we are at or over capacity
	// Example: 2 nodes, 2 jobs (Running) -> returns true (the next job will queue)
	return activeJobCount >= totalNodes, nil
}

// SubmitExternalJob connects via SSH using a password and runs Apptainer directly.
// pm is used to allocate a port and register the Traefik proxy route before launching.
func (s *SlurmService) SubmitExternalJob(ctx context.Context, username string, app *models.AppManifest, workspace string, pm PortAllocator) (string, error) {
	// 1. Generate a stable job ID
	jobID := fmt.Sprintf("ext_%d", time.Now().Unix())
	jobIDInt := int(time.Now().Unix() % 100000)

	// 2. Allocate a port + register Traefik route BEFORE launching
	port, err := pm.AllocatePort(jobIDInt, username, "external-worker", "external-worker")
	if err != nil {
		log.Printf("[ExternalJob] Port allocation failed: %v", err)
		return "", fmt.Errorf("port allocation failed: %v", err)
	}
	log.Printf("[ExternalJob] Allocated port %d for job %s", port, jobID)
	baseURL := fmt.Sprintf("/%s/jupyter/%d", username, jobIDInt)

	// 3. Setup SSH configuration
	config := &ssh.ClientConfig{
		User: username,
		Auth: []ssh.AuthMethod{
			ssh.Password("password"),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         5 * time.Second,
	}

	addr := "external-worker:22"
	log.Printf("[ExternalJob] Connecting to %s as user %s", addr, username)
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		log.Printf("[ExternalJob] SSH dial failed: %v", err)
		pm.ReleasePort(jobIDInt)
		return "", fmt.Errorf("failed to connect to external node: %v", err)
	}
	defer client.Close()
	log.Printf("[ExternalJob] SSH connection established")

	session, err := client.NewSession()
	if err != nil {
		log.Printf("[ExternalJob] Failed to create SSH session: %v", err)
		pm.ReleasePort(jobIDInt)
		return "", fmt.Errorf("failed to create session: %v", err)
	}
	defer session.Close()

	// 4. Build command — substitute shell vars with real values
	externalWorkspace := strings.Replace(workspace, "/mnt/storage/projects", "/storage/projects", 1)
	externalSourcePath := strings.Replace(app.SourcePath, "/mnt/storage", "/storage", 1)

	execCmd := strings.ReplaceAll(app.ExecCommand, "$ALLOCATED_PORT", fmt.Sprintf("%d", port))
	execCmd = strings.ReplaceAll(execCmd, "$BASE_URL", baseURL)
	execCmd = strings.ReplaceAll(execCmd, "$WORKSPACE", externalWorkspace)

	remoteCmd := fmt.Sprintf(
		"mkdir -p %s/logs && nohup apptainer exec --bind %s:%s --bind /storage/common:/storage/common:ro %s/%s bash -c %q > %s/logs/external_%s.log 2>&1 < /dev/null &",
		externalWorkspace,
		externalWorkspace, externalWorkspace,
		externalSourcePath, app.ImageFile,
		execCmd,
		externalWorkspace, app.ID,
	)
	log.Printf("[ExternalJob] Remote command: %s", remoteCmd)

	var stderrBuf bytes.Buffer
	session.Stderr = &stderrBuf

	if err := session.Start(remoteCmd); err != nil {
		log.Printf("[ExternalJob] session.Start failed: %v | stderr: %s", err, stderrBuf.String())
		pm.ReleasePort(jobIDInt)
		return "", fmt.Errorf("failed to start external command: %v", err)
	}

	if err := session.Wait(); err != nil {
		log.Printf("[ExternalJob] session.Wait (shell exited): %v | stderr: %s", err, stderrBuf.String())
	}

	log.Printf("[ExternalJob] Dispatched: %s port=%d baseURL=%s", jobID, port, baseURL)
	return jobID, nil
}

// PortAllocator is the subset of ports.PortManager needed by SubmitExternalJob.
// Defined here to avoid an import cycle between the services and ports packages.
type PortAllocator interface {
	AllocatePort(jobID int, username, nodeHostname, nodeIP string) (int, error)
	ReleasePort(jobID int) error
}
