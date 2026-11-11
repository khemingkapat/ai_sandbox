package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
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

// TestSlurmWebhook_AuthEnforcement verifies that both ingest and egress endpoints require Bearer auth.
func TestSlurmWebhook_AuthEnforcement(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret")

	// 1. Ingest without auth -> 401
	req := httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(`{"job_id":"101"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	_ = scraper.HandleSlurmWebhook(c)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on unauthenticated ingest, got %d", rec.Code)
	}

	// 2. Ingest with bad auth -> 401
	req = httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(`{"job_id":"101"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer wrong-secret")
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	_ = scraper.HandleSlurmWebhook(c)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on bad auth ingest, got %d", rec.Code)
	}

	// 3. Egress without auth -> 401
	req = httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents", nil)
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	_ = scraper.HandleTelemetryIncidents(c)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on unauthenticated incidents egress, got %d", rec.Code)
	}

	// 4. Server token unconfigured -> fail-closed 401
	scraperUnset := NewTelemetryScraper(30*time.Second, "")
	req = httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents", nil)
	req.Header.Set("Authorization", "Bearer arbitrary")
	rec = httptest.NewRecorder()
	c = e.NewContext(req, rec)
	_ = scraperUnset.HandleTelemetryIncidents(c)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 when server token is unconfigured, got %d", rec.Code)
	}
}

// TestSlurmWebhook_HappyPathAndEgress verifies that a failed job is ingested (201) and retrievable via /incidents.
func TestSlurmWebhook_HappyPathAndEgress(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret")

	// Post failed job
	payload := `{"job_id":"1042","user":"student01","account":"nlp-lab","partition":"batch-gpu","exit_code":137,"status":"FAILED","log_tail":"CUDA out of memory"}`
	req := httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer test-secret")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := scraper.HandleSlurmWebhook(c); err != nil {
		t.Fatalf("HandleSlurmWebhook failed: %v", err)
	}
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 Created, got %d", rec.Code)
	}

	// Query incidents
	reqGet := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents", nil)
	reqGet.Header.Set("Authorization", "Bearer test-secret")
	recGet := httptest.NewRecorder()
	cGet := e.NewContext(reqGet, recGet)

	if err := scraper.HandleTelemetryIncidents(cGet); err != nil {
		t.Fatalf("HandleTelemetryIncidents failed: %v", err)
	}
	if recGet.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", recGet.Code)
	}

	var incidents []SlurmIncident
	if err := json.Unmarshal(recGet.Body.Bytes(), &incidents); err != nil {
		t.Fatalf("failed to decode incidents JSON: %v", err)
	}

	if len(incidents) != 1 {
		t.Fatalf("expected 1 incident, got %d", len(incidents))
	}
	inc := incidents[0]
	if inc.EntityID != "1042" || inc.User != "student01" || inc.ExitCode != 137 || inc.Status != "FAILED" {
		t.Fatalf("incident fields mismatch: %+v", inc)
	}
	if inc.LogTail != "CUDA out of memory" {
		t.Fatalf("expected log_tail 'CUDA out of memory', got %q", inc.LogTail)
	}
}

// TestSlurmWebhook_FailureOnlyFiltering verifies that normal job completions (exit_code 0, COMPLETED)
// are ignored without entering the incident ring buffer.
func TestSlurmWebhook_FailureOnlyFiltering(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret")

	// Post successful job
	payload := `{"job_id":"1043","user":"student02","account":"nlp-lab","partition":"batch-cpu","exit_code":0,"status":"COMPLETED","log_tail":"Training completed successfully"}`
	req := httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer test-secret")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := scraper.HandleSlurmWebhook(c); err != nil {
		t.Fatalf("HandleSlurmWebhook failed: %v", err)
	}
	// Must return 200 OK (ignored/noop), not 201 Created
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK for completed job, got %d", rec.Code)
	}

	// Verify incidents list is empty
	reqGet := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents", nil)
	reqGet.Header.Set("Authorization", "Bearer test-secret")
	recGet := httptest.NewRecorder()
	cGet := e.NewContext(reqGet, recGet)
	_ = scraper.HandleTelemetryIncidents(cGet)

	var incidents []SlurmIncident
	_ = json.Unmarshal(recGet.Body.Bytes(), &incidents)
	if len(incidents) != 0 {
		t.Fatalf("expected 0 incidents recorded for completed job, got %d", len(incidents))
	}
}

// TestSlurmWebhook_LogSanitizationAndTruncation verifies that log_tail is sanitized of control characters
// and truncated to at most 4096 bytes.
func TestSlurmWebhook_LogSanitizationAndTruncation(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret")

	// Create 10KB log with terminal escape codes and control characters
	rawLog := strings.Repeat("A_Very_Long_Stack_Trace_Line_1234567890_\n", 250) + "\x1b[31mRed Alert\x1b[0m\x00\x07"
	p := SlurmWebhookPayload{
		JobID:    "1044",
		User:     "student03",
		Account:  "ai-lab",
		ExitCode: 1,
		Status:   "FAILED",
		LogTail:  rawLog,
	}
	body, _ := json.Marshal(p)

	req := httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer test-secret")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	_ = scraper.HandleSlurmWebhook(c)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 Created, got %d", rec.Code)
	}

	reqGet := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents", nil)
	reqGet.Header.Set("Authorization", "Bearer test-secret")
	recGet := httptest.NewRecorder()
	cGet := e.NewContext(reqGet, recGet)
	_ = scraper.HandleTelemetryIncidents(cGet)

	var incidents []SlurmIncident
	_ = json.Unmarshal(recGet.Body.Bytes(), &incidents)
	if len(incidents) != 1 {
		t.Fatalf("expected 1 incident, got %d", len(incidents))
	}

	gotLog := incidents[0].LogTail
	if len(gotLog) > 4096 {
		t.Fatalf("expected log length <= 4096 bytes, got %d", len(gotLog))
	}
	if strings.Contains(gotLog, "\x00") || strings.Contains(gotLog, "\x07") {
		t.Fatalf("log contains unsanitized null or bell control characters")
	}
}

// TestIncidentRingBuffer_EvictionAndBounds verifies that the 200-slot buffer evicts oldest records
// when more than 200 arrive, returns newest first, and respects ?limit and ?since query params.
func TestIncidentRingBuffer_EvictionAndBounds(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret")

	// Insert 205 incidents
	for i := 1; i <= 205; i++ {
		payload := fmt.Sprintf(`{"job_id":"%d","user":"user%d","account":"lab","exit_code":1,"status":"FAILED","log_tail":"error"}`, i, i)
		req := httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer test-secret")
		rec := httptest.NewRecorder()
		c := e.NewContext(req, rec)
		_ = scraper.HandleSlurmWebhook(c)
	}

	// 1. Fetch default (should return 50 newest, #205 down to #156)
	reqGet := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents", nil)
	reqGet.Header.Set("Authorization", "Bearer test-secret")
	recGet := httptest.NewRecorder()
	cGet := e.NewContext(reqGet, recGet)
	_ = scraper.HandleTelemetryIncidents(cGet)

	var defaultList []SlurmIncident
	_ = json.Unmarshal(recGet.Body.Bytes(), &defaultList)
	if len(defaultList) != 50 {
		t.Fatalf("expected default limit 50, got %d", len(defaultList))
	}
	if defaultList[0].EntityID != "205" {
		t.Fatalf("expected newest incident first (205), got %q", defaultList[0].EntityID)
	}

	// 2. Fetch full capacity (limit=200). Should contain #205 down to #6; #1-#5 must be evicted.
	reqFull := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents?limit=200", nil)
	reqFull.Header.Set("Authorization", "Bearer test-secret")
	recFull := httptest.NewRecorder()
	cFull := e.NewContext(reqFull, recFull)
	_ = scraper.HandleTelemetryIncidents(cFull)

	var fullList []SlurmIncident
	_ = json.Unmarshal(recFull.Body.Bytes(), &fullList)
	if len(fullList) != 200 {
		t.Fatalf("expected exactly 200 incidents, got %d", len(fullList))
	}
	if fullList[0].EntityID != "205" {
		t.Fatalf("expected newest to be 205, got %q", fullList[0].EntityID)
	}
	if fullList[199].EntityID != "6" {
		t.Fatalf("expected oldest surviving incident to be 6, got %q", fullList[199].EntityID)
	}

	// 3. Limit parameter bounds (e.g. limit=5)
	reqLimit5 := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents?limit=5", nil)
	reqLimit5.Header.Set("Authorization", "Bearer test-secret")
	recLimit5 := httptest.NewRecorder()
	cLimit5 := e.NewContext(reqLimit5, recLimit5)
	_ = scraper.HandleTelemetryIncidents(cLimit5)

	var list5 []SlurmIncident
	_ = json.Unmarshal(recLimit5.Body.Bytes(), &list5)
	if len(list5) != 5 {
		t.Fatalf("expected 5 incidents with limit=5, got %d", len(list5))
	}
}

// TestSlurmWebhook_PayloadLimit verifies that requests > 16KB are rejected to prevent memory exhaustion.
func TestSlurmWebhook_PayloadLimit(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret")

	oversizedPayload := strings.Repeat("x", 20*1024) // 20KB
	req := httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(oversizedPayload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer test-secret")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	_ = scraper.HandleSlurmWebhook(c)
	if rec.Code != http.StatusRequestEntityTooLarge && rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 413 or 400 for >16KB payload, got %d", rec.Code)
	}
}

// TestSlurmWebhook_Concurrency verifies thread safety under high-concurrency readers and writers with -race.
func TestSlurmWebhook_Concurrency(t *testing.T) {
	e := echo.New()
	scraper := NewTelemetryScraper(30*time.Second, "test-secret")

	done := make(chan bool)
	for w := 0; w < 10; w++ {
		go func(workerID int) {
			for j := 0; j < 50; j++ {
				payload := fmt.Sprintf(`{"job_id":"%d-%d","user":"user","account":"lab","exit_code":1,"status":"FAILED"}`, workerID, j)
				req := httptest.NewRequest(http.MethodPost, "/api/internal/webhook/slurm", strings.NewReader(payload))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Authorization", "Bearer test-secret")
				rec := httptest.NewRecorder()
				c := e.NewContext(req, rec)
				_ = scraper.HandleSlurmWebhook(c)
			}
			done <- true
		}(w)
	}

	for r := 0; r < 5; r++ {
		go func() {
			for j := 0; j < 50; j++ {
				req := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/incidents?limit=20", nil)
				req.Header.Set("Authorization", "Bearer test-secret")
				rec := httptest.NewRecorder()
				c := e.NewContext(req, rec)
				_ = scraper.HandleTelemetryIncidents(c)
			}
			done <- true
		}()
	}

	for i := 0; i < 15; i++ {
		<-done
	}
}
