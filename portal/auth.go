package main

import (
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
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

// UnifiedAuthConfig holds configuration for Unified JWT v1.2.0 verification.
type UnifiedAuthConfig struct {
	JWKSURL      string
	JWKSCacheTTL time.Duration
	PublicKeyPEM string
	DevSecret    []byte
	AllowedIss   []string
	AllowedAud   []string
}

// UnifiedUserContext represents normalized claims from a verified Unified JWT.
type UnifiedUserContext struct {
	StudentID string        `json:"student_id"`
	TenantID  string        `json:"tenant_id"`
	Role      string        `json:"role"`
	Name      string        `json:"name"`
	Email     string        `json:"email"`
	RawClaims jwt.MapClaims `json:"raw_claims"`
}

// AppServer encapsulates app-level services including JWT verification.
type AppServer struct {
	jwtVerifier *UnifiedJWTVerifier
}

var globalAppServer *AppServer

// UnifiedJWTVerifier parses and validates Unified JWT v1.2.0 tokens.
type UnifiedJWTVerifier struct {
	cfg        UnifiedAuthConfig
	mu         sync.RWMutex
	cachedKeys map[string]*rsa.PublicKey
	lastFetch  time.Time
	parsedPEM  *rsa.PublicKey
}

// NewUnifiedJWTVerifier initializes a verifier with the given configuration.
func NewUnifiedJWTVerifier(cfg UnifiedAuthConfig) *UnifiedJWTVerifier {
	v := &UnifiedJWTVerifier{
		cfg: cfg,
	}

	if cfg.PublicKeyPEM != "" {
		block, _ := pem.Decode([]byte(cfg.PublicKeyPEM))
		if block != nil {
			pub, err := x509.ParsePKIXPublicKey(block.Bytes)
			if err == nil {
				if rsaPub, ok := pub.(*rsa.PublicKey); ok {
					v.parsedPEM = rsaPub
				}
			} else {
				rsaPub, err := x509.ParsePKCS1PublicKey(block.Bytes)
				if err == nil {
					v.parsedPEM = rsaPub
				}
			}
		}
	}

	return v
}

// NormalizeRole maps raw role strings to one of "student", "instructor", or "admin".
func NormalizeRole(r interface{}) string {
	str, ok := r.(string)
	if !ok {
		return "student"
	}
	s := strings.ToLower(strings.TrimSpace(str))
	switch s {
	case "admin":
		return "admin"
	case "instructor", "ta", "teacher":
		return "instructor"
	case "student":
		return "student"
	default:
		return "student"
	}
}

func extractAuds(audClaim interface{}) []string {
	switch a := audClaim.(type) {
	case string:
		if a != "" {
			return []string{a}
		}
	case []string:
		return a
	case []interface{}:
		var res []string
		for _, item := range a {
			if s, ok := item.(string); ok && s != "" {
				res = append(res, s)
			}
		}
		return res
	}
	return nil
}

// VerifyUnifiedToken verifies signature, algorithms, and mandatory claims of a Unified JWT v1.2.0.
func (v *UnifiedJWTVerifier) VerifyUnifiedToken(tokenString string) (*UnifiedUserContext, error) {
	if tokenString == "" {
		return nil, fmt.Errorf("empty token")
	}

	token, err := jwt.Parse(tokenString, func(t *jwt.Token) (interface{}, error) {
		switch t.Method.(type) {
		case *jwt.SigningMethodRSA:
			kid, _ := t.Header["kid"].(string)
			return v.getRSAPublicKey(kid)
		case *jwt.SigningMethodHMAC:
			sec := v.cfg.DevSecret
			if len(sec) == 0 {
				sec = getUniversitySecret()
			}
			return sec, nil
		default:
			return nil, fmt.Errorf("unsupported signing method: %v", t.Header["alg"])
		}
	})

	if err != nil || !token.Valid {
		return nil, fmt.Errorf("invalid or expired token: %w", err)
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return nil, fmt.Errorf("invalid token claims")
	}

	// Validate iss
	iss, _ := claims["iss"].(string)
	if iss == "" {
		return nil, fmt.Errorf("missing issuer (iss)")
	}
	if len(v.cfg.AllowedIss) > 0 {
		matched := false
		for _, allowed := range v.cfg.AllowedIss {
			if iss == allowed {
				matched = true
				break
			}
		}
		if !matched {
			return nil, fmt.Errorf("invalid issuer: %s", iss)
		}
	}

	// Validate sub
	sub, _ := claims["sub"].(string)
	if sub == "" {
		return nil, fmt.Errorf("missing subject (sub)")
	}

	// Validate aud
	allowedAuds := v.cfg.AllowedAud
	if len(allowedAuds) == 0 {
		allowedAuds = []string{"cpe-ai-sandbox", "cpe-sandbox"}
	}
	tokenAuds := extractAuds(claims["aud"])
	if len(tokenAuds) == 0 {
		return nil, fmt.Errorf("missing audience (aud)")
	}
	audMatched := false
	for _, ta := range tokenAuds {
		for _, aa := range allowedAuds {
			if ta == aa {
				audMatched = true
				break
			}
		}
		if audMatched {
			break
		}
	}
	if !audMatched {
		return nil, fmt.Errorf("invalid audience: %v", tokenAuds)
	}

	studentID := sub
	if s, ok := claims["student_id"].(string); ok && s != "" {
		studentID = s
	}

	tenantID := studentID
	if t, ok := claims["tenant_id"].(string); ok && t != "" {
		tenantID = t
	}

	role := NormalizeRole(claims["role"])
	name, _ := claims["name"].(string)
	email, _ := claims["email"].(string)

	return &UnifiedUserContext{
		StudentID: studentID,
		TenantID:  tenantID,
		Role:      role,
		Name:      name,
		Email:     email,
		RawClaims: claims,
	}, nil
}

func (v *UnifiedJWTVerifier) getRSAPublicKey(kid string) (*rsa.PublicKey, error) {
	if v.parsedPEM != nil {
		return v.parsedPEM, nil
	}

	if v.cfg.JWKSURL == "" {
		return nil, fmt.Errorf("no JWKS URL or PEM public key configured for RS256")
	}

	v.mu.RLock()
	if v.cachedKeys != nil && (v.cfg.JWKSCacheTTL == 0 || time.Since(v.lastFetch) < v.cfg.JWKSCacheTTL) {
		if key, ok := v.cachedKeys[kid]; ok {
			v.mu.RUnlock()
			return key, nil
		}
	}
	v.mu.RUnlock()

	// Fetch from JWKS
	v.mu.Lock()
	defer v.mu.Unlock()

	// Recheck after acquiring write lock
	if v.cachedKeys != nil && (v.cfg.JWKSCacheTTL == 0 || time.Since(v.lastFetch) < v.cfg.JWKSCacheTTL) {
		if key, ok := v.cachedKeys[kid]; ok {
			return key, nil
		}
	}

	keys, err := fetchJWKS(v.cfg.JWKSURL)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch JWKS: %w", err)
	}

	v.cachedKeys = keys
	v.lastFetch = time.Now()

	if key, ok := keys[kid]; ok {
		return key, nil
	}

	if kid == "" && len(keys) == 1 {
		for _, k := range keys {
			return k, nil
		}
	}

	return nil, fmt.Errorf("kid %q not found in JWKS", kid)
}

func fetchJWKS(jwksURL string) (map[string]*rsa.PublicKey, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(jwksURL)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("JWKS server returned status %d", resp.StatusCode)
	}

	var jwks struct {
		Keys []struct {
			Kty string `json:"kty"`
			Alg string `json:"alg"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&jwks); err != nil {
		return nil, err
	}

	result := make(map[string]*rsa.PublicKey)
	for _, k := range jwks.Keys {
		if k.Kty == "RSA" && k.N != "" && k.E != "" {
			pubKey, err := parseRSAPublicKeyFromJWK(k.N, k.E)
			if err == nil {
				result[k.Kid] = pubKey
			}
		}
	}

	if len(result) == 0 {
		return nil, fmt.Errorf("no valid RSA keys found in JWKS")
	}

	return result, nil
}

func parseRSAPublicKeyFromJWK(nStr, eStr string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(nStr)
	if err != nil {
		nBytes, err = base64.URLEncoding.DecodeString(nStr)
		if err != nil {
			return nil, err
		}
	}

	eBytes, err := base64.RawURLEncoding.DecodeString(eStr)
	if err != nil {
		eBytes, err = base64.URLEncoding.DecodeString(eStr)
		if err != nil {
			return nil, err
		}
	}

	n := new(big.Int).SetBytes(nBytes)
	var eInt int
	for _, b := range eBytes {
		eInt = (eInt << 8) | int(b)
	}

	return &rsa.PublicKey{N: n, E: eInt}, nil
}
