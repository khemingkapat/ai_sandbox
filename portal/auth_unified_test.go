package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"
)

// Helper to generate an RSA test key pair and JWKS representation
func generateTestRSAKey(t *testing.T, kid string) (*rsa.PrivateKey, string, map[string]interface{}) {
	t.Helper()
	privKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("failed to generate RSA key: %v", err)
	}

	pubASN1, err := x509.MarshalPKIXPublicKey(&privKey.PublicKey)
	if err != nil {
		t.Fatalf("failed to marshal public key: %v", err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "PUBLIC KEY",
		Bytes: pubASN1,
	})

	nStr := base64.RawURLEncoding.EncodeToString(privKey.PublicKey.N.Bytes())
	eBytes := big.NewInt(int64(privKey.PublicKey.E)).Bytes()
	eStr := base64.RawURLEncoding.EncodeToString(eBytes)

	jwk := map[string]interface{}{
		"kty": "RSA",
		"use": "sig",
		"alg": "RS256",
		"kid": kid,
		"n":   nStr,
		"e":   eStr,
	}

	return privKey, string(pubPEM), jwk
}

// Criteria 1: RS256 (JWKS/PEM) and HS256 Verification & Claim Normalization
func TestUnifiedJWT_RS256_And_HS256_Verification(t *testing.T) {
	kid := "test-key-1"
	privKey, pubPEM, jwk := generateTestRSAKey(t, kid)

	// Mock JWKS Server
	jwksHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"keys": []interface{}{jwk},
		})
	})
	jwksServer := httptest.NewServer(jwksHandler)
	defer jwksServer.Close()

	// 1. RS256 Verification via JWKS
	rsClaims := jwt.MapClaims{
		"iss":        "https://auth.cpe.eng.cmu.ac.th",
		"sub":        "65070501111",
		"student_id": "65070501111",
		"aud":        "cpe-ai-sandbox",
		"role":       "student",
		"name":       "Alice Student",
		"email":      "alice@cpe.eng.cmu.ac.th",
		"iat":        time.Now().Unix(),
		"exp":        time.Now().Add(1 * time.Hour).Unix(),
	}
	rsToken := jwt.NewWithClaims(jwt.SigningMethodRS256, rsClaims)
	rsToken.Header["kid"] = kid
	rsTokenStr, err := rsToken.SignedString(privKey)
	if err != nil {
		t.Fatalf("failed to sign RS256 token: %v", err)
	}

	cfg := UnifiedAuthConfig{
		JWKSURL:       jwksServer.URL,
		JWKSCacheTTL:  5 * time.Minute,
		DevSecret:     []byte("test-dev-secret-key-32b"),
		AllowedIss:    []string{"https://auth.cpe.eng.cmu.ac.th"},
		AllowedAud:    []string{"cpe-ai-sandbox", "cpe-sandbox"},
	}
	verifier := NewUnifiedJWTVerifier(cfg)

	userCtx, err := verifier.VerifyUnifiedToken(rsTokenStr)
	if err != nil {
		t.Fatalf("expected successful RS256 verification via JWKS, got error: %v", err)
	}
	if userCtx.StudentID != "65070501111" {
		t.Errorf("expected StudentID 65070501111, got %s", userCtx.StudentID)
	}
	if userCtx.Role != "student" {
		t.Errorf("expected Role student, got %s", userCtx.Role)
	}
	if userCtx.TenantID != "65070501111" {
		t.Errorf("expected TenantID 65070501111, got %s", userCtx.TenantID)
	}

	// 2. RS256 Verification via Static PEM
	pemCfg := UnifiedAuthConfig{
		PublicKeyPEM: pubPEM,
		AllowedAud:   []string{"cpe-ai-sandbox"},
	}
	pemVerifier := NewUnifiedJWTVerifier(pemCfg)
	userCtxPEM, err := pemVerifier.VerifyUnifiedToken(rsTokenStr)
	if err != nil {
		t.Fatalf("expected successful RS256 verification via PEM, got: %v", err)
	}
	if userCtxPEM.StudentID != "65070501111" {
		t.Errorf("expected StudentID 65070501111, got %s", userCtxPEM.StudentID)
	}

	// 3. Role Normalization (ta/instructor -> instructor, admin -> admin)
	for _, tc := range []struct {
		inputRole    string
		expectedRole string
	}{
		{"ta", "instructor"},
		{"instructor", "instructor"},
		{"admin", "admin"},
		{"student", "student"},
		{"unknown_role", "student"},
	} {
		roleClaims := jwt.MapClaims{
			"iss":  "https://auth.cpe.eng.cmu.ac.th",
			"sub":  "user_role_test",
			"aud":  "cpe-ai-sandbox",
			"role": tc.inputRole,
			"iat":  time.Now().Unix(),
			"exp":  time.Now().Add(1 * time.Hour).Unix(),
		}
		tok := jwt.NewWithClaims(jwt.SigningMethodRS256, roleClaims)
		tok.Header["kid"] = kid
		tokStr, _ := tok.SignedString(privKey)
		ctx, err := verifier.VerifyUnifiedToken(tokStr)
		if err != nil {
			t.Fatalf("verification failed for role %s: %v", tc.inputRole, err)
		}
		if ctx.Role != tc.expectedRole {
			t.Errorf("role %q normalized to %q, expected %q", tc.inputRole, ctx.Role, tc.expectedRole)
		}
	}

	// 4. HS256 Dev Fallback
	hsSecret := []byte("university-dev-secret-32-chars!!")
	hsCfg := UnifiedAuthConfig{
		DevSecret:  hsSecret,
		AllowedAud: []string{"cpe-ai-sandbox", "cpe-sandbox"},
	}
	hsVerifier := NewUnifiedJWTVerifier(hsCfg)

	hsClaims := jwt.MapClaims{
		"iss": "dev-idp",
		"sub": "dev_student_65",
		"aud": "cpe-sandbox",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(1 * time.Hour).Unix(),
	}
	hsToken := jwt.NewWithClaims(jwt.SigningMethodHS256, hsClaims)
	hsTokenStr, err := hsToken.SignedString(hsSecret)
	if err != nil {
		t.Fatalf("failed to sign HS256 token: %v", err)
	}

	hsCtx, err := hsVerifier.VerifyUnifiedToken(hsTokenStr)
	if err != nil {
		t.Fatalf("expected successful HS256 dev verification, got: %v", err)
	}
	if hsCtx.StudentID != "dev_student_65" {
		t.Errorf("expected StudentID dev_student_65, got %s", hsCtx.StudentID)
	}
}

// Criteria 2: Mandatory Claims & Boundary Validation Failures
func TestUnifiedJWT_MandatoryClaims_And_ValidationFailures(t *testing.T) {
	kid := "test-key-2"
	privKey, pubPEM, _ := generateTestRSAKey(t, kid)
	verifier := NewUnifiedJWTVerifier(UnifiedAuthConfig{
		PublicKeyPEM: pubPEM,
		AllowedAud:   []string{"cpe-ai-sandbox", "cpe-sandbox"},
	})

	// 1. Wrong Audience
	claimsBadAud := jwt.MapClaims{
		"iss": "test-idp",
		"sub": "stu1",
		"aud": "wrong-audience",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(1 * time.Hour).Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claimsBadAud)
	tok.Header["kid"] = kid
	str, _ := tok.SignedString(privKey)
	if _, err := verifier.VerifyUnifiedToken(str); err == nil {
		t.Errorf("expected error for wrong audience, got nil")
	}

	// 2. Expired Token
	claimsExpired := jwt.MapClaims{
		"iss": "test-idp",
		"sub": "stu1",
		"aud": "cpe-ai-sandbox",
		"iat": time.Now().Add(-2 * time.Hour).Unix(),
		"exp": time.Now().Add(-1 * time.Hour).Unix(),
	}
	tok = jwt.NewWithClaims(jwt.SigningMethodRS256, claimsExpired)
	tok.Header["kid"] = kid
	str, _ = tok.SignedString(privKey)
	if _, err := verifier.VerifyUnifiedToken(str); err == nil {
		t.Errorf("expected error for expired token, got nil")
	}

	// 3. Missing Subject
	claimsNoSub := jwt.MapClaims{
		"iss": "test-idp",
		"aud": "cpe-ai-sandbox",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(1 * time.Hour).Unix(),
	}
	tok = jwt.NewWithClaims(jwt.SigningMethodRS256, claimsNoSub)
	tok.Header["kid"] = kid
	str, _ = tok.SignedString(privKey)
	if _, err := verifier.VerifyUnifiedToken(str); err == nil {
		t.Errorf("expected error for missing subject, got nil")
	}

	// 4. Missing Issuer
	claimsNoIss := jwt.MapClaims{
		"sub": "stu1",
		"aud": "cpe-ai-sandbox",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(1 * time.Hour).Unix(),
	}
	tok = jwt.NewWithClaims(jwt.SigningMethodRS256, claimsNoIss)
	tok.Header["kid"] = kid
	str, _ = tok.SignedString(privKey)
	if _, err := verifier.VerifyUnifiedToken(str); err == nil {
		t.Errorf("expected error for missing issuer, got nil")
	}
}

// Criteria 1 & 2: SSO Bridge & Open-Redirect Sanitization
func TestSSOBridge_HappyPath_And_OpenRedirectProtection(t *testing.T) {
	kid := "test-key-3"
	privKey, pubPEM, _ := generateTestRSAKey(t, kid)
	verifier := NewUnifiedJWTVerifier(UnifiedAuthConfig{
		PublicKeyPEM: pubPEM,
		AllowedAud:   []string{"cpe-ai-sandbox"},
	})

	e := echo.New()
	app := &AppServer{
		jwtVerifier: verifier,
	}

	// 1. Valid SSO Login with Relative Redirect
	claims := jwt.MapClaims{
		"iss": "https://auth.cpe.eng.cmu.ac.th",
		"sub": "65070501234",
		"aud": "cpe-ai-sandbox",
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(1 * time.Hour).Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	tokStr, _ := tok.SignedString(privKey)

	req := httptest.NewRequest(http.MethodGet, "/api/auth/sso?token="+tokStr+"&redirect=/workspaces", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := app.handleSSO(c); err != nil {
		t.Fatalf("handleSSO failed: %v", err)
	}

	if rec.Code != http.StatusFound {
		t.Errorf("expected 302 Found, got %d", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "/workspaces" {
		t.Errorf("expected Location /workspaces, got %s", loc)
	}

	// Verify sandbox_token cookie attributes
	var sandboxCookie *http.Cookie
	for _, ck := range rec.Result().Cookies() {
		if ck.Name == "sandbox_token" {
			sandboxCookie = ck
			break
		}
	}
	if sandboxCookie == nil {
		t.Fatalf("expected sandbox_token cookie to be set")
	}
	if !sandboxCookie.HttpOnly {
		t.Errorf("expected sandbox_token HttpOnly=true")
	}
	if sandboxCookie.SameSite != http.SameSiteLaxMode {
		t.Errorf("expected sandbox_token SameSite=Lax")
	}
	if sandboxCookie.Path != "/" {
		t.Errorf("expected sandbox_token Path=/, got %s", sandboxCookie.Path)
	}

	// 2. Open Redirect Defense: External schemes, double slashes, and backslashes must resolve to "/"
	maliciousRedirects := []string{
		"https://evil.com",
		"http://evil.com/phish",
		"//evil.com",
		"//evil.com/path",
		"/\\evil.com",
		"javascript:alert(1)",
		"ftp://evil.com",
	}

	for _, mal := range maliciousRedirects {
		req = httptest.NewRequest(http.MethodGet, "/api/auth/sso?token="+tokStr+"&redirect="+url.QueryEscape(mal), nil)
		rec = httptest.NewRecorder()
		c = e.NewContext(req, rec)

		if err := app.handleSSO(c); err != nil {
			t.Fatalf("handleSSO failed for redirect %q: %v", mal, err)
		}
		if loc := rec.Header().Get("Location"); loc != "/" {
			t.Errorf("malicious redirect %q was not sanitized to '/', got %q", mal, loc)
		}
	}

	// 3. Invalid Token Rejection
	req = httptest.NewRequest(http.MethodGet, "/api/auth/sso?token=invalid.jwt.token&redirect=/", nil)
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	_ = app.handleSSO(c)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 Unauthorized for invalid token, got %d", rec.Code)
	}
}

// Criteria 2 & Traefik ForwardAuth: Verify Endpoint
func TestForwardAuth_VerifyEndpoint(t *testing.T) {
	kid := "test-key-4"
	privKey, pubPEM, _ := generateTestRSAKey(t, kid)
	verifier := NewUnifiedJWTVerifier(UnifiedAuthConfig{
		PublicKeyPEM: pubPEM,
		AllowedAud:   []string{"cpe-ai-sandbox"},
	})

	e := echo.New()
	app := &AppServer{
		jwtVerifier: verifier,
	}

	claims := jwt.MapClaims{
		"iss":  "https://auth.cpe.eng.cmu.ac.th",
		"sub":  "65070509999",
		"aud":  "cpe-ai-sandbox",
		"role": "instructor",
		"iat":  time.Now().Unix(),
		"exp":  time.Now().Add(1 * time.Hour).Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	tokStr, _ := tok.SignedString(privKey)

	// 1. Authenticated via sandbox_token Cookie
	req := httptest.NewRequest(http.MethodGet, "/api/auth/verify", nil)
	req.AddCookie(&http.Cookie{Name: "sandbox_token", Value: tokStr})
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := app.handleAuthVerify(c); err != nil {
		t.Fatalf("handleAuthVerify failed: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200 OK, got %d", rec.Code)
	}
	if uid := rec.Header().Get("X-User-Id"); uid != "65070509999" {
		t.Errorf("expected X-User-Id 65070509999, got %s", uid)
	}
	if role := rec.Header().Get("X-User-Role"); role != "instructor" {
		t.Errorf("expected X-User-Role instructor, got %s", role)
	}

	// 2. Authenticated via Authorization: Bearer Header
	req = httptest.NewRequest(http.MethodGet, "/api/auth/verify", nil)
	req.Header.Set("Authorization", "Bearer "+tokStr)
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)

	if err := app.handleAuthVerify(c); err != nil {
		t.Fatalf("handleAuthVerify failed: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200 OK via Bearer, got %d", rec.Code)
	}

	// 3. Unauthenticated with Accept: text/html -> 302 Redirect to /login
	req = httptest.NewRequest(http.MethodGet, "/api/auth/verify", nil)
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)

	_ = app.handleAuthVerify(c)
	if rec.Code != http.StatusFound {
		t.Errorf("expected 302 Found for browser unauthenticated, got %d", rec.Code)
	}
	if loc := rec.Header().Get("Location"); !strings.Contains(loc, "/login") {
		t.Errorf("expected redirect to contain /login, got %s", loc)
	}

	// 4. Unauthenticated with API/JSON -> 401 Unauthorized
	req = httptest.NewRequest(http.MethodGet, "/api/auth/verify", nil)
	req.Header.Set("Accept", "application/json")
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)

	_ = app.handleAuthVerify(c)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 Unauthorized for API unauthenticated, got %d", rec.Code)
	}
}

// Criteria 2: Tenant Isolation Middleware (/:user/:app)
func TestTenantIsolation_Proxy(t *testing.T) {
	e := echo.New()

	// Protected handler behind TenantIsolationMiddleware
	protectedHandler := func(c echo.Context) error {
		return c.String(http.StatusOK, "welcome to workspace")
	}

	// 1. Student A accessing own workspace (65070501111 -> /65070501111/jupyter)
	req := httptest.NewRequest(http.MethodGet, "/65070501111/jupyter", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	c.SetParamNames("user", "app")
	c.SetParamValues("65070501111", "jupyter")
	c.Set("unified_user", &UnifiedUserContext{
		StudentID: "65070501111",
		Role:      "student",
	})

	handler := TenantIsolationMiddleware()(protectedHandler)
	if err := handler(c); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200 OK for own workspace, got %d", rec.Code)
	}

	// 2. Student A accessing Student B's workspace (65070501111 -> /65070502222/jupyter) -> 403 Forbidden
	req = httptest.NewRequest(http.MethodGet, "/65070502222/jupyter", nil)
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	c.SetParamNames("user", "app")
	c.SetParamValues("65070502222", "jupyter")
	c.Set("unified_user", &UnifiedUserContext{
		StudentID: "65070501111",
		Role:      "student",
	})

	_ = handler(c)
	if rec.Code != http.StatusForbidden {
		t.Errorf("expected 403 Forbidden for cross-tenant access, got %d", rec.Code)
	}
	if reason := rec.Header().Get("X-Denial-Reason"); reason != "cross-tenant-isolation" {
		t.Errorf("expected X-Denial-Reason 'cross-tenant-isolation', got %q", reason)
	}

	// 3. Admin accessing Student B's workspace (admin -> /65070502222/jupyter) -> Allowed (200 OK)
	req = httptest.NewRequest(http.MethodGet, "/65070502222/jupyter", nil)
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	c.SetParamNames("user", "app")
	c.SetParamValues("65070502222", "jupyter")
	c.Set("unified_user", &UnifiedUserContext{
		StudentID: "admin_user",
		Role:      "admin",
	})

	if err := handler(c); err != nil {
		t.Fatalf("unexpected error for admin access: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200 OK for admin bypass, got %d", rec.Code)
	}
}

// Criteria 2: 3-Tier RBAC & Admin Endpoints
func TestRBAC_3TierAccessControl(t *testing.T) {
	e := echo.New()
	dummyHandler := func(c echo.Context) error {
		return c.String(http.StatusOK, "ok")
	}

	// Test RequireRole("instructor")
	instructorGuard := RequireRole("instructor")(dummyHandler)

	// Student blocked
	req := httptest.NewRequest(http.MethodGet, "/instructor/test", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	c.Set("unified_user", &UnifiedUserContext{StudentID: "stu1", Role: "student"})
	_ = instructorGuard(c)
	if rec.Code != http.StatusForbidden {
		t.Errorf("expected student to be blocked by RequireRole(instructor), got %d", rec.Code)
	}

	// Instructor allowed
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	c.Set("unified_user", &UnifiedUserContext{StudentID: "inst1", Role: "instructor"})
	_ = instructorGuard(c)
	if rec.Code != http.StatusOK {
		t.Errorf("expected instructor to pass RequireRole(instructor), got %d", rec.Code)
	}

	// Admin allowed
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	c.Set("unified_user", &UnifiedUserContext{StudentID: "admin1", Role: "admin"})
	_ = instructorGuard(c)
	if rec.Code != http.StatusOK {
		t.Errorf("expected admin to pass RequireRole(instructor), got %d", rec.Code)
	}

	// Test RequireRole("admin")
	adminGuard := RequireRole("admin")(dummyHandler)

	// Instructor blocked from admin
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	c.Set("unified_user", &UnifiedUserContext{StudentID: "inst1", Role: "instructor"})
	_ = adminGuard(c)
	if rec.Code != http.StatusForbidden {
		t.Errorf("expected instructor to be blocked from admin route, got %d", rec.Code)
	}

	// Admin allowed
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	c.Set("unified_user", &UnifiedUserContext{StudentID: "admin1", Role: "admin"})
	_ = adminGuard(c)
	if rec.Code != http.StatusOK {
		t.Errorf("expected admin to pass RequireRole(admin), got %d", rec.Code)
	}
}
