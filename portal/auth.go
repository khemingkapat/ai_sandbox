package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// readSlurmKey reads the shared secret key used for signing Slurm JWTs.
func readSlurmKey() ([]byte, error) {
	return os.ReadFile(jwtKeyPath)
}

// makeSlurmToken generates a signed JWT for the given user and project.
// The token is used for authenticating with the Slurm REST API.
func makeSlurmToken(username string, project string) (string, error) {
	key, err := readSlurmKey()
	if err != nil {
		return "", err
	}

	claims := jwt.MapClaims{
		"sun": username,
		"prj": project,
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(time.Duration(tokenLifespan) * time.Second).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(key)
}

// fetchAccessMatrix retrieves the user-to-project access mapping.
// It attempts to fetch associations from SlurmDB and falls back to a static map.
func fetchAccessMatrix() map[string][]string {
	fallback := map[string][]string{
		"root":  {"root_project"},
		"user1": {"project1"},
		"user2": {"project1", "project2"},
		"user3": {"project2"},
		"user4": {"project3"},
	}

	adminToken, err := makeSlurmToken("root", "root")
	if err != nil {
		return fallback
	}

	req, err := http.NewRequest("GET", slurmRestURL+"/slurmdb/v0.0.42/associations", nil)
	if err != nil {
		return fallback
	}

	req.Header.Set("X-SLURM-USER-TOKEN", adminToken)
	req.Header.Set("X-SLURM-USER-NAME", "root")
	req.Header.Set("Content-Type", "application/json")

	httpClient := &http.Client{Timeout: 10 * time.Second}
	resp, err := httpClient.Do(req)
	if err != nil {
		return fallback
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fallback
	}

	var result struct {
		Associations []struct {
			User    string `json:"user"`
			Account string `json:"account"`
		} `json:"associations"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fallback
	}

	matrix := make(map[string][]string)
	for _, assoc := range result.Associations {
		if assoc.User != "" && assoc.Account != "" {
			matrix[assoc.User] = append(matrix[assoc.User], assoc.Account)
		}
	}

	if len(matrix) == 0 {
		return fallback
	}
	return matrix
}

// registerUserExtrausers adds a user to the extrausers database files on shared storage.
// This allows the user to be resolved by ID across the cluster.
func registerUserExtrausers(username string, project string) error {
	if !strings.HasPrefix(username, "user") {
		return nil // Only register dynamic test users for now
	}
	suffixStr := strings.TrimPrefix(username, "user")
	suffix, err := strconv.Atoi(suffixStr)
	if err != nil {
		return nil // skip if not numeric suffix
	}
	uid := 1000 + suffix
	gid := 1000 + suffix

	passwdFile := "/mnt/storage/common/etc/passwd"
	groupFile := "/mnt/storage/common/etc/group"

	// Ensure atomic write for passwd
	if err := appendExtrauserEntry(passwdFile, username, fmt.Sprintf("%s:x:%d:%d::/mnt/storage/projects/%s:/bin/bash", username, uid, gid, project)); err != nil {
		return err
	}

	// Ensure atomic write for group
	if err := appendExtrauserEntry(groupFile, username, fmt.Sprintf("%s:x:%d:", username, gid)); err != nil {
		return err
	}

	return nil
}

// appendExtrauserEntry ensures a unique entry exists in the specified extrausers file.
func appendExtrauserEntry(filePath string, entryKey string, entryLine string) error {
	data, err := os.ReadFile(filePath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, entryKey+":") {
			return nil // Already exists
		}
	}

	newData := string(data)
	if len(newData) > 0 && !strings.HasSuffix(newData, "\n") {
		newData += "\n"
	}
	newData += entryLine + "\n"

	tmpPath := filePath + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(newData), 0644); err != nil {
		return err
	}
	return os.Rename(tmpPath, filePath)
}
