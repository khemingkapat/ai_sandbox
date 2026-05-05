package services

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/golang-jwt/jwt/v5"
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

type SlurmJob struct {
	JobState string `json:"job_state"`
}

// SlurmJobsResponse represents the list of jobs from the API
type SlurmJobsResponse struct {
	Jobs []SlurmJob `json:"jobs"`
}

// CheckPendingQueue checks if there is any job with a PENDING state.
func (s *SlurmService) CheckPendingQueue(ctx context.Context, username, token string) (bool, error) {
	// Call the jobs endpoint. We use v0.0.42 to match your slurmdb version.
	path := "/slurm/v0.0.42/jobs"
	
	resp, err := s.Do(ctx, http.MethodGet, path, username, token, nil)
	if err != nil {
		return false, fmt.Errorf("failed to call slurm API: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("slurm API returned status: %d", resp.StatusCode)
	}

	var result SlurmJobsResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return false, fmt.Errorf("failed to read JSON: %w", err)
	}

	// Loop through all jobs. If one is PENDING, return true.
	for _, job := range result.Jobs {
		if job.JobState == "PENDING" {
			return true, nil
		}
	}

	// No pending jobs found
	return false, nil
}
