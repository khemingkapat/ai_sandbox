package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/labstack/echo/v4"
	echoSwagger "github.com/swaggo/echo-swagger"

	_ "portal/docs"
)

// TestHealthz_LivenessProbe verifies that /healthz returns 200 OK immediately with no external dependencies.
func TestHealthz_LivenessProbe(t *testing.T) {
	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := handleHealthz(c); err != nil {
		t.Fatalf("handleHealthz failed: %v", err)
	}

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var resp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse json response: %v", err)
	}
	if resp["status"] != "ok" {
		t.Fatalf("expected status 'ok', got %q", resp["status"])
	}
}

// TestTelemetry_AuthEnforcement verifies that /api/v1/telemetry enforces Bearer token authentication.
func TestTelemetry_AuthEnforcement(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret-token")

	// 1. Missing Authorization header
	reqNoAuth := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry", nil)
	recNoAuth := httptest.NewRecorder()
	cNoAuth := e.NewContext(reqNoAuth, recNoAuth)

	err := scraper.HandleTelemetry(cNoAuth)
	if err == nil && recNoAuth.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for missing auth, got code %d", recNoAuth.Code)
	}

	// 2. Invalid Bearer token
	reqBadAuth := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry", nil)
	reqBadAuth.Header.Set("Authorization", "Bearer wrong-token")
	recBadAuth := httptest.NewRecorder()
	cBadAuth := e.NewContext(reqBadAuth, recBadAuth)

	err = scraper.HandleTelemetry(cBadAuth)
	if err == nil && recBadAuth.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for invalid token, got code %d", recBadAuth.Code)
	}

	// 3. Valid Bearer token
	reqValid := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry", nil)
	reqValid.Header.Set("Authorization", "Bearer test-secret-token")
	recValid := httptest.NewRecorder()
	cValid := e.NewContext(reqValid, recValid)

	if err := scraper.HandleTelemetry(cValid); err != nil {
		t.Fatalf("unexpected error for valid token: %v", err)
	}
	if recValid.Code != http.StatusOK {
		t.Fatalf("expected 200 for valid token, got %d", recValid.Code)
	}

	// 4. Unconfigured/empty server token must fail closed
	scraperUnset := NewTelemetryScraper(30*time.Second, "")
	reqUnset := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry", nil)
	reqUnset.Header.Set("Authorization", "Bearer arbitrary-token")
	recUnset := httptest.NewRecorder()
	cUnset := e.NewContext(reqUnset, recUnset)

	err = scraperUnset.HandleTelemetry(cUnset)
	if err == nil && recUnset.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 when server token is unconfigured, got %d", recUnset.Code)
	}
}

// TestTelemetry_ADR0003_BatchYield verifies that when vLLM is down due to exclusive batch GPU jobs,
// vLLM is marked 'yielded_for_batch' and root status remains 'healthy'.
func TestTelemetry_ADR0003_BatchYield(t *testing.T) {
	scraper := NewTelemetryScraper(30*time.Second, "test-token")

	// Inject probe state: vLLM unreachable, but batch-gpu job running in Slurm
	probes := SubsystemProbes{
		VLLMReachable:   false,
		MLflowReachable: true,
		SlurmReachable:  true,
		StorageOK:       true,
		BatchGPURunning: true, // ADR 0003 condition
		InteractivePods: 2,
		RunningJobs:     1,
		QueuedJobs:      0,
		ActiveUserSet:   map[string]bool{"student01": true, "student02": true},
	}

	data := scraper.computeTelemetry(probes)

	if data.Status != "healthy" {
		t.Fatalf("expected root status 'healthy' under ADR 0003 batch yield, got %q", data.Status)
	}
	if data.Services["vllm"] != "yielded_for_batch" {
		t.Fatalf("expected vLLM status 'yielded_for_batch', got %q", data.Services["vllm"])
	}
	if data.ActiveUsers != 2 {
		t.Fatalf("expected active_users 2, got %d", data.ActiveUsers)
	}
	if data.Workloads.InteractiveSessions != 2 || data.Workloads.RunningJobs != 1 {
		t.Fatalf("workload counts mismatch: %+v", data.Workloads)
	}
}

// TestTelemetry_DegradedWhenServiceDown verifies that an unmitigated service crash triggers 'degraded'.
func TestTelemetry_DegradedWhenServiceDown(t *testing.T) {
	scraper := NewTelemetryScraper(30*time.Second, "test-token")

	probes := SubsystemProbes{
		VLLMReachable:   true,
		MLflowReachable: false, // MLflow crashed
		SlurmReachable:  true,
		StorageOK:       true,
		BatchGPURunning: false,
		InteractivePods: 1,
		RunningJobs:     0,
		QueuedJobs:      0,
		ActiveUserSet:   map[string]bool{"student01": true},
	}

	data := scraper.computeTelemetry(probes)

	if data.Status != "degraded" {
		t.Fatalf("expected status 'degraded' when MLflow is down, got %q", data.Status)
	}
	if data.Services["mlflow"] != "error" {
		t.Fatalf("expected mlflow status 'error', got %q", data.Services["mlflow"])
	}
}

// TestTelemetry_ErrorWhenCoreInfraDown verifies that Slurm or Storage failure triggers 'error'.
func TestTelemetry_ErrorWhenCoreInfraDown(t *testing.T) {
	scraper := NewTelemetryScraper(30*time.Second, "test-token")

	probes := SubsystemProbes{
		VLLMReachable:   true,
		MLflowReachable: true,
		SlurmReachable:  false, // Slurm controller unreachable
		StorageOK:       true,
		BatchGPURunning: false,
	}

	data := scraper.computeTelemetry(probes)

	if data.Status != "error" {
		t.Fatalf("expected status 'error' when Slurm is unreachable, got %q", data.Status)
	}
}

// TestSwagger_DocJSON verifies that Swagger doc.json is registered and serves the API schema.
func TestSwagger_DocJSON(t *testing.T) {
	e := echo.New()
	e.GET("/swagger/*", echoSwagger.WrapHandler)

	req := httptest.NewRequest(http.MethodGet, "/swagger/doc.json", nil)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200 for /swagger/doc.json, got %d", rec.Code)
	}

	var doc map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
		t.Fatalf("failed to parse swagger doc.json: %v", err)
	}

	info, ok := doc["info"].(map[string]interface{})
	if !ok || info["title"] != "AI Sandbox Portal API" {
		t.Fatalf("expected title 'AI Sandbox Portal API', got %v", info["title"])
	}

	paths, ok := doc["paths"].(map[string]interface{})
	if !ok {
		t.Fatalf("paths missing in swagger doc")
	}

	// Verify public and telemetry paths are present
	if _, ok := paths["/healthz"]; !ok {
		t.Fatalf("expected /healthz in swagger paths")
	}
	if _, ok := paths["/api/v1/telemetry"]; !ok {
		t.Fatalf("expected /api/v1/telemetry in swagger paths")
	}

	// Verify internal routes are NOT present
	if _, ok := paths["/api/internal/allocate-port"]; ok {
		t.Fatalf("leak: /api/internal/allocate-port should not be documented in swagger")
	}
}
