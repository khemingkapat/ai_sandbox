package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var (
	cachedJWTKey     []byte
	cachedJWTKeyOnce sync.Once
	cachedJWTErr     error
)

// readSlurmKey reads the shared secret key used for signing Slurm and vLLM JWTs.
// It caches the key in memory via sync.Once to guarantee thread-safe zero disk I/O on hot auth paths.
func readSlurmKey() ([]byte, error) {
	cachedJWTKeyOnce.Do(func() {
		cachedJWTKey, cachedJWTErr = os.ReadFile(jwtKeyPath)
	})
	return cachedJWTKey, cachedJWTErr
}

// makeSlurmToken generates a signed JWT for the given user and project.
// The token is used for authenticating with the Slurm REST API.
func makeSlurmToken(username string, project string) (string, error) {
	key, err := readSlurmKey()
	if err != nil || len(key) == 0 {
		// Fallback for tests or environments without /etc/slurm/jwt_hs256.key
		key = getUniversitySecret()
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

// makeInferenceToken generates a long-lived (30 days) HMAC-SHA256 signed Bearer JWT
// for central vLLM inference API access.
func makeInferenceToken(username string) (string, error) {
	key, err := readSlurmKey()
	if err != nil {
		return "", err
	}

	claims := jwt.MapClaims{
		"sub": username,
		"aud": "vllm-api",
		"iss": "ai-sandbox-portal",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(30 * 24 * time.Hour).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(key)
}

// verifyInferenceToken parses and validates an HMAC-SHA256 Bearer JWT in memory.
// Returns the verified username/subject (uid) or an error.
func verifyInferenceToken(tokenString string) (string, error) {
	key, err := readSlurmKey()
	if err != nil {
		return "", fmt.Errorf("failed to read signing key: %w", err)
	}

	token, err := jwt.Parse(tokenString, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing algorithm: %v", t.Header["alg"])
		}
		return key, nil
	}, jwt.WithAudience("vllm-api"), jwt.WithIssuer("ai-sandbox-portal"))

	if err != nil || !token.Valid {
		return "", fmt.Errorf("invalid token: %w", err)
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return "", fmt.Errorf("invalid token claims")
	}

	sub, ok := claims["sub"].(string)
	if !ok || sub == "" {
		sub, ok = claims["sun"].(string)
		if !ok || sub == "" {
			return "", fmt.Errorf("missing subject in token claims")
		}
	}

	return sub, nil
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
	defer func() { _ = resp.Body.Close() }()

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
