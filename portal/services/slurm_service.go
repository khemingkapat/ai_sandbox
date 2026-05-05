package services

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"portal/models"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/ssh" // Added here
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
func (s *SlurmService) SubmitExternalJob(ctx context.Context, username string, app *models.AppManifest, workspace string) (string, error) {
	// 1. Setup SSH configuration with password
	config := &ssh.ClientConfig{
		User: username,
		Auth: []ssh.AuthMethod{
			ssh.Password("password"),
		},
		// Since this is a POC, we skip host key verification
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         5 * time.Second,
	}

	// 2. Connect to the external node
	// Replace "external-node-ip" with the actual IP address
	addr := "external-worker:22"
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return "", fmt.Errorf("failed to connect to external node: %v", err)
	}
	defer client.Close()

	// 3. Create an SSH session
	session, err := client.NewSession()
	if err != nil {
		return "", fmt.Errorf("failed to create session: %v", err)
	}
	defer session.Close()

	// 4. Construct the Apptainer command
	// We use 'nohup' and '&' so the program keeps running after we disconnect.
	remoteCmd := fmt.Sprintf("nohup apptainer exec --bind %s:%s %s/%s %s > %s/logs/external_%s.log 2>&1 &",
		workspace, workspace, app.SourcePath, app.ImageFile, app.ExecCommand, workspace, app.ID)

	// 5. Run the command
	err = session.Run(remoteCmd)
	if err != nil {
		return "", fmt.Errorf("failed to run external command: %v", err)
	}

	// Return a custom ID so the portal knows this is an external job
	return fmt.Sprintf("ext_%d", time.Now().Unix()), nil
}

