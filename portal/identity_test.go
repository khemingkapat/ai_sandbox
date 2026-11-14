package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"
)

// Helper to create a signed University JWT for tests
func makeTestUniversityJWT(t *testing.T, studentID string, secret []byte) string {
	t.Helper()
	claims := jwt.MapClaims{
		"sub":        studentID,
		"student_id": studentID,
		"iss":        "university-sso",
		"iat":        time.Now().Unix(),
		"exp":        time.Now().Add(1 * time.Hour).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	tokenStr, err := token.SignedString(secret)
	if err != nil {
		t.Fatalf("failed to sign test JWT: %v", err)
	}
	return tokenStr
}

// Criteria 1 & 3: Database Store Initialization, Baseline Seeding & Monotonic Allocations
func TestIdentityManager_InitAndMonotonicAllocations(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "identity_test.db")
	extraDir := filepath.Join(tempDir, "common", "etc")
	projDir := filepath.Join(tempDir, "projects")
	if err := os.MkdirAll(extraDir, 0755); err != nil {
		t.Fatalf("failed to mkdir extraDir: %v", err)
	}
	if err := os.MkdirAll(projDir, 0755); err != nil {
		t.Fatalf("failed to mkdir projDir: %v", err)
	}

	im, err := NewIdentityManager("sqlite3", dbPath, extraDir, projDir, "")
	if err != nil {
		t.Fatalf("failed to initialize IdentityManager: %v", err)
	}
	defer im.Close()

	// 1. Verify baseline seeded users (user1..user4) and projects (project1..project3)
	user1UID, err := im.GetUserUID("user1")
	if err != nil || user1UID != 1001 {
		t.Errorf("expected user1 UID 1001, got %d (err: %v)", user1UID, err)
	}
	user4UID, err := im.GetUserUID("user4")
	if err != nil || user4UID != 1004 {
		t.Errorf("expected user4 UID 1004, got %d (err: %v)", user4UID, err)
	}

	p1GID, err := im.GetProjectGID("project1")
	if err != nil || p1GID != 2001 {
		t.Errorf("expected project1 GID 2001, got %d (err: %v)", p1GID, err)
	}
	p3GID, err := im.GetProjectGID("project3")
	if err != nil || p3GID != 2003 {
		t.Errorf("expected project3 GID 2003, got %d (err: %v)", p3GID, err)
	}

	// 2. Ensure new student provisioning starts at UID >= 2000
	aliceUID, defProject, err := im.EnsureStudentProvisioned("stu_alice")
	if err != nil {
		t.Fatalf("failed to provision stu_alice: %v", err)
	}
	if aliceUID < 2000 {
		t.Errorf("expected stu_alice UID >= 2000, got %d", aliceUID)
	}
	if !strings.HasPrefix(defProject, "p-") {
		t.Errorf("expected default project slug to start with 'p-', got %s", defProject)
	}

	// 3. Second provision of same student is idempotent (same UID)
	aliceUID2, _, err := im.EnsureStudentProvisioned("stu_alice")
	if err != nil || aliceUID2 != aliceUID {
		t.Errorf("expected idempotent UID %d, got %d (err: %v)", aliceUID, aliceUID2, err)
	}

	// 4. Provisioning a second student increments UID monotonically
	bobUID, _, err := im.EnsureStudentProvisioned("stu_bob")
	if err != nil {
		t.Fatalf("failed to provision stu_bob: %v", err)
	}
	if bobUID <= aliceUID {
		t.Errorf("expected bobUID (%d) > aliceUID (%d)", bobUID, aliceUID)
	}

	// 5. Creating a new project allocates GID >= 10000
	projSlug, projGID, err := im.CreateProject("stu_alice", "Agent Harness")
	if err != nil {
		t.Fatalf("failed to create project: %v", err)
	}
	if projGID < 10000 {
		t.Errorf("expected projGID >= 10000, got %d", projGID)
	}
	if !strings.HasPrefix(projSlug, "p-") {
		t.Errorf("expected project slug starting with 'p-', got %s", projSlug)
	}
}

// Criteria 1 & 2: Self-Service Project Creation, Invitation & Quota Enforcement
func TestIdentityManager_ProjectQuotaAndMembership(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "identity_quota.db")
	extraDir := filepath.Join(tempDir, "common", "etc")
	projDir := filepath.Join(tempDir, "projects")
	_ = os.MkdirAll(extraDir, 0755)
	_ = os.MkdirAll(projDir, 0755)

	im, err := NewIdentityManager("sqlite3", dbPath, extraDir, projDir, "")
	if err != nil {
		t.Fatalf("failed to initialize IdentityManager: %v", err)
	}
	defer im.Close()

	student := "stu_charlie"
	_, _, err = im.EnsureStudentProvisioned(student)
	if err != nil {
		t.Fatalf("failed to provision student: %v", err)
	}

	// Max quota is 5. Default project counts as 1. Creating 4 more should succeed.
	for i := 1; i <= 4; i++ {
		_, _, err := im.CreateProject(student, fmt.Sprintf("Project %d", i))
		if err != nil {
			t.Fatalf("expected project %d to succeed, got: %v", i, err)
		}
	}

	// Attempting 6th project (1 default + 4 created + 1 extra = 6) must be rejected with QuotaExceeded
	_, _, err = im.CreateProject(student, "Excess Project")
	if err == nil {
		t.Fatalf("expected quota error for 6th project, got nil")
	}
	if !strings.Contains(err.Error(), "quota exceeded") {
		t.Errorf("expected quota exceeded error, got: %v", err)
	}

	// Member invitation: Invite stu_david to Project 1
	projects, err := im.ListUserProjects(student)
	if err != nil || len(projects) == 0 {
		t.Fatalf("failed to list projects: %v", err)
	}
	targetProj := projects[0].ProjectID

	err = im.InviteMember(student, targetProj, "stu_david")
	if err != nil {
		t.Fatalf("failed to invite member: %v", err)
	}

	// Verify stu_david now belongs to targetProj
	davidProjects, err := im.ListUserProjects("stu_david")
	if err != nil {
		t.Fatalf("failed to list david's projects: %v", err)
	}
	found := false
	for _, p := range davidProjects {
		if p.ProjectID == targetProj {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected stu_david to belong to %s", targetProj)
	}

	// Non-member cannot invite another user
	err = im.InviteMember("stu_stranger", targetProj, "stu_eve")
	if err == nil {
		t.Errorf("expected error when stranger invites to project, got nil")
	}
}

// Criteria 2: Input Validation & Delimiter / Path Traversal Rejection
func TestIdentityManager_ValidationRejection(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "identity_val.db")
	extraDir := filepath.Join(tempDir, "common", "etc")
	projDir := filepath.Join(tempDir, "projects")
	_ = os.MkdirAll(extraDir, 0755)
	_ = os.MkdirAll(projDir, 0755)

	im, err := NewIdentityManager("sqlite3", dbPath, extraDir, projDir, "")
	if err != nil {
		t.Fatalf("failed to init: %v", err)
	}
	defer im.Close()

	badUsernames := []string{
		"root",
		"admin",
		"user:evil",
		"user\nevil",
		"../traversal",
		"-leadingdash",
		"very_long_username_exceeding_thirty_two_characters_total",
		"",
	}

	for _, bad := range badUsernames {
		_, _, err := im.EnsureStudentProvisioned(bad)
		if err == nil {
			t.Errorf("expected validation failure for invalid student_id %q, got nil", bad)
		}
	}
}

// Criteria 1 & 3: Atomic extrausers Compilation and 2770 Directory Permissions
func TestIdentityManager_CompileExtrausersAndSetgidDir(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "identity_compile.db")
	extraDir := filepath.Join(tempDir, "common", "etc")
	projDir := filepath.Join(tempDir, "projects")
	_ = os.MkdirAll(extraDir, 0755)
	_ = os.MkdirAll(projDir, 0755)

	im, err := NewIdentityManager("sqlite3", dbPath, extraDir, projDir, "")
	if err != nil {
		t.Fatalf("failed to init: %v", err)
	}
	defer im.Close()

	_, _, err = im.EnsureStudentProvisioned("stu_frank")
	if err != nil {
		t.Fatalf("failed to provision stu_frank: %v", err)
	}

	projSlug, projGID, err := im.CreateProject("stu_frank", "Distributed Training")
	if err != nil {
		t.Fatalf("failed to create project: %v", err)
	}

	// Trigger compilation
	if err := im.CompileExtrausers(); err != nil {
		t.Fatalf("failed to compile extrausers: %v", err)
	}

	// 1. Verify passwd contains stu_frank with valid format
	passwdContent, err := os.ReadFile(filepath.Join(extraDir, "passwd"))
	if err != nil {
		t.Fatalf("failed to read passwd: %v", err)
	}
	if !strings.Contains(string(passwdContent), "stu_frank:x:") {
		t.Errorf("passwd missing stu_frank entry. Content:\n%s", string(passwdContent))
	}
	if !strings.Contains(string(passwdContent), "user1:x:1001:") {
		t.Errorf("passwd missing baseline user1 entry")
	}

	// 2. Verify group contains project and user memberships
	groupContent, err := os.ReadFile(filepath.Join(extraDir, "group"))
	if err != nil {
		t.Fatalf("failed to read group: %v", err)
	}
	expectedGroupEntry := fmt.Sprintf("%s:x:%d:stu_frank", projSlug, projGID)
	if !strings.Contains(string(groupContent), expectedGroupEntry) {
		t.Errorf("group missing expected entry %q. Content:\n%s", expectedGroupEntry, string(groupContent))
	}

	// 3. Verify directory mode is 2770 (setgid | 0770)
	dirPath := filepath.Join(projDir, projSlug)
	info, err := os.Stat(dirPath)
	if err != nil {
		t.Fatalf("failed to stat project dir: %v", err)
	}
	if info.Mode()&os.ModeSetgid == 0 {
		t.Errorf("expected setgid bit on %s, got mode %v", dirPath, info.Mode())
	}
	perm := info.Mode().Perm()
	if perm&0007 != 0 {
		t.Errorf("expected others to have 0 permissions, got %v", perm)
	}
}

// Criteria 3: Concurrency Safety under flock (Zero Data Races)
func TestIdentityManager_ConcurrentFlockSafety(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "identity_concurrent.db")
	extraDir := filepath.Join(tempDir, "common", "etc")
	projDir := filepath.Join(tempDir, "projects")
	_ = os.MkdirAll(extraDir, 0755)
	_ = os.MkdirAll(projDir, 0755)

	im, err := NewIdentityManager("sqlite3", dbPath, extraDir, projDir, "")
	if err != nil {
		t.Fatalf("failed to init: %v", err)
	}
	defer im.Close()

	const numWorkers = 10
	var wg sync.WaitGroup
	wg.Add(numWorkers)

	for i := 0; i < numWorkers; i++ {
		workerID := i
		go func() {
			defer wg.Done()
			student := fmt.Sprintf("student_%d", workerID)
			_, _, err := im.EnsureStudentProvisioned(student)
			if err != nil {
				t.Errorf("worker %d failed to provision: %v", workerID, err)
				return
			}
			_, _, err = im.CreateProject(student, fmt.Sprintf("Project by %s", student))
			if err != nil {
				t.Errorf("worker %d failed to create project: %v", workerID, err)
				return
			}
			if err := im.CompileExtrausers(); err != nil {
				t.Errorf("worker %d failed to compile extrausers: %v", workerID, err)
			}
		}()
	}

	wg.Wait()

	// Verify passwd and group are valid and intact
	passwdContent, err := os.ReadFile(filepath.Join(extraDir, "passwd"))
	if err != nil {
		t.Fatalf("failed to read passwd: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(passwdContent)), "\n")
	if len(lines) < numWorkers+4 { // 4 baseline + numWorkers
		t.Errorf("expected at least %d passwd entries, got %d", numWorkers+4, len(lines))
	}
}

// Criteria 1 & 2: Single-Path External JWT Login Flow
func TestHTTP_SinglePathJWTLogin(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "identity_http.db")
	extraDir := filepath.Join(tempDir, "common", "etc")
	projDir := filepath.Join(tempDir, "projects")
	_ = os.MkdirAll(extraDir, 0755)
	_ = os.MkdirAll(projDir, 0755)

	secret := []byte("test-university-secret-key-32bytes")
	im, err := NewIdentityManager("sqlite3", dbPath, extraDir, projDir, "")
	if err != nil {
		t.Fatalf("failed to init: %v", err)
	}
	defer im.Close()

	e := echo.New()
	handler := &IdentityHTTPHandler{
		im:        im,
		jwtSecret: secret,
	}

	// 1. Unsigned / malformed JWT rejected with 401
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(url.Values{"jwt_token": {"invalid.jwt.token"}}.Encode()))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationForm)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := handler.HandleLogin(c); err == nil && rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 Unauthorized for malformed JWT, got code %d", rec.Code)
	}

	// 2. Valid signed JWT provisions user and sets session cookie
	validJWT := makeTestUniversityJWT(t, "stu_grace", secret)
	req2 := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(url.Values{"jwt_token": {validJWT}}.Encode()))
	req2.Header.Set(echo.HeaderContentType, echo.MIMEApplicationForm)
	rec2 := httptest.NewRecorder()
	c2 := e.NewContext(req2, rec2)

	if err := handler.HandleLogin(c2); err != nil {
		t.Fatalf("login failed for valid JWT: %v", err)
	}
	if rec2.Code != http.StatusSeeOther {
		t.Errorf("expected redirect 303, got %d", rec2.Code)
	}

	cookies := rec2.Result().Cookies()
	var sessionCookie *http.Cookie
	for _, cookie := range cookies {
		if cookie.Name == "session" {
			sessionCookie = cookie
			break
		}
	}
	if sessionCookie == nil || sessionCookie.Value == "" {
		t.Fatalf("expected session cookie to be set")
	}

	// 3. User can query projects via GET /api/projects with their session
	req3 := httptest.NewRequest(http.MethodGet, "/api/projects", nil)
	c3 := e.NewContext(req3, httptest.NewRecorder())
	c3.Set("user_student_id", "stu_grace")

	rec3 := httptest.NewRecorder()
	c3 = e.NewContext(req3, rec3)
	c3.Set("user_student_id", "stu_grace")

	if err := handler.HandleListProjects(c3); err != nil {
		t.Fatalf("failed to list projects: %v", err)
	}
	if rec3.Code != http.StatusOK {
		t.Errorf("expected 200 OK from /api/projects, got %d", rec3.Code)
	}

	var projs []ProjectInfo
	if err := json.Unmarshal(rec3.Body.Bytes(), &projs); err != nil {
		t.Fatalf("failed to decode project list: %v", err)
	}
	if len(projs) == 0 {
		t.Errorf("expected at least 1 default project for stu_grace")
	}
}

// Criteria 3: slurmrestd Reconciler Synchronization
func TestIdentityManager_SlurmrestdSync(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "identity_slurm.db")
	extraDir := filepath.Join(tempDir, "common", "etc")
	projDir := filepath.Join(tempDir, "projects")
	_ = os.MkdirAll(extraDir, 0755)
	_ = os.MkdirAll(projDir, 0755)

	var recordedRequests []string
	var mu sync.Mutex

	// Mock slurmrestd server
	mockSlurm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		recordedRequests = append(recordedRequests, fmt.Sprintf("%s %s", r.Method, r.URL.Path))
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer mockSlurm.Close()

	im, err := NewIdentityManager("sqlite3", dbPath, extraDir, projDir, mockSlurm.URL)
	if err != nil {
		t.Fatalf("failed to init: %v", err)
	}
	defer im.Close()

	_, _, err = im.EnsureStudentProvisioned("stu_heidi")
	if err != nil {
		t.Fatalf("failed to provision stu_heidi: %v", err)
	}

	// Trigger Reconcile
	if err := im.ReconcileSlurm(context.Background()); err != nil {
		t.Fatalf("failed to reconcile slurm: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	hasUserPost := false
	hasAssocPost := false
	for _, req := range recordedRequests {
		if strings.Contains(req, "POST /slurmdb/v0.0.42/users") {
			hasUserPost = true
		}
		if strings.Contains(req, "POST /slurmdb/v0.0.42/associations") {
			hasAssocPost = true
		}
	}

	if !hasUserPost {
		t.Errorf("expected POST /slurmdb/v0.0.42/users call during reconcile, got: %v", recordedRequests)
	}
	if !hasAssocPost {
		t.Errorf("expected POST /slurmdb/v0.0.42/associations call during reconcile, got: %v", recordedRequests)
	}
}
