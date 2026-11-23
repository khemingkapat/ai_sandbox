package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func setupTestLabsDir(t *testing.T) (string, string) {
	t.Helper()
	base := t.TempDir()
	labsDir := filepath.Join(base, "labs")
	outsideDir := filepath.Join(base, "outside")

	if err := os.MkdirAll(filepath.Join(labsDir, "week01"), 0755); err != nil {
		t.Fatalf("mkdir labs: %v", err)
	}
	if err := os.MkdirAll(outsideDir, 0755); err != nil {
		t.Fatalf("mkdir outside: %v", err)
	}

	nbContent := `{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}`
	if err := os.WriteFile(filepath.Join(labsDir, "01_hello_sandbox.ipynb"), []byte(nbContent), 0644); err != nil {
		t.Fatalf("write flat lab: %v", err)
	}
	if err := os.WriteFile(filepath.Join(labsDir, "week01", "lab01.ipynb"), []byte(nbContent), 0644); err != nil {
		t.Fatalf("write nested lab: %v", err)
	}
	if err := os.WriteFile(filepath.Join(labsDir, "week01", "helper.py"), []byte("X = 42\n"), 0644); err != nil {
		t.Fatalf("write helper.py: %v", err)
	}
	if err := os.WriteFile(filepath.Join(labsDir, "README.txt"), []byte("ignore me"), 0644); err != nil {
		t.Fatalf("write txt: %v", err)
	}

	secretFile := filepath.Join(outsideDir, "secret.ipynb")
	if err := os.WriteFile(secretFile, []byte(nbContent), 0644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	if err := os.Symlink(secretFile, filepath.Join(labsDir, "escape.ipynb")); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	return labsDir, base
}

func TestResolveLabPath_ValidAndBoundaryRejection(t *testing.T) {
	labsDir, _ := setupTestLabsDir(t)

	// Valid flat and nested notebooks
	validCases := []string{
		"01_hello_sandbox.ipynb",
		"week01/lab01.ipynb",
	}
	for _, tc := range validCases {
		rel, abs, err := resolveLabPath(labsDir, tc)
		if err != nil {
			t.Errorf("expected %q to be valid, got error: %v", tc, err)
			continue
		}
		if rel != tc {
			t.Errorf("expected rel %q, got %q", tc, rel)
		}
		if !strings.HasPrefix(abs, labsDir) {
			t.Errorf("expected abs %q inside %q", abs, labsDir)
		}
	}

	// Boundary rejections
	invalidCases := []string{
		"",
		"../../etc/passwd",
		"/etc/passwd",
		"../outside/secret.ipynb",
		"week01/../../outside/secret.ipynb",
		"README.txt",
		"week01/helper.py",
		"escape.ipynb",
		"nonexistent.ipynb",
	}
	for _, tc := range invalidCases {
		if _, _, err := resolveLabPath(labsDir, tc); err == nil {
			t.Errorf("expected %q to be rejected, but got nil error", tc)
		}
	}
}

func TestHandleListLabs_DynamicFlatAndNested(t *testing.T) {
	labsDir, _ := setupTestLabsDir(t)
	t.Setenv("LABS_DIR", labsDir)

	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/api/labs", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	c.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})

	if err := handleListLabs(c); err != nil {
		t.Fatalf("handleListLabs returned error: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp struct {
		Labs []LabEntry `json:"labs"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}

	found := map[string]bool{}
	for _, l := range resp.Labs {
		found[l.Path] = true
	}
	if !found["01_hello_sandbox.ipynb"] {
		t.Errorf("expected 01_hello_sandbox.ipynb in lab list, got %+v", resp.Labs)
	}
	if !found["week01/lab01.ipynb"] {
		t.Errorf("expected week01/lab01.ipynb in lab list, got %+v", resp.Labs)
	}
	if found["README.txt"] || found["escape.ipynb"] {
		t.Errorf("unexpected non-notebook or symlink escape in lab list: %+v", resp.Labs)
	}
}

func TestHandleLaunchLab_SpawnReuseAndInvalid(t *testing.T) {
	labsDir, _ := setupTestLabsDir(t)
	t.Setenv("LABS_DIR", labsDir)

	fakeClient := fake.NewSimpleClientset()
	oldSM := sessionManager
	oldProbe := labReadyProbe
	oldManifestLookup := lookupJupyterManifest
	defer func() {
		sessionManager = oldSM
		labReadyProbe = oldProbe
		lookupJupyterManifest = oldManifestLookup
	}()

	sessionManager = &SessionManager{
		client:    fakeClient,
		namespace: "workload",
	}
	labReadyProbe = func(_ context.Context, _ string) error {
		return nil
	}
	lookupJupyterManifest = func(_ string) *AppManifest {
		return &AppManifest{
			ID:        "jupyterlab",
			Type:      "interactive",
			Image:     "interactive-jupyter:latest",
			SlurmArgs: map[string]string{"cpus-per-task": "2", "mem": "4G"},
		}
	}

	e := echo.New()

	// 1. Traversal rejection
	reqBad := httptest.NewRequest(http.MethodGet, "/launch?lab=../../etc/passwd", nil)
	recBad := httptest.NewRecorder()
	cBad := e.NewContext(reqBad, recBad)
	cBad.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})
	_ = handleLaunchLab(cBad)
	if recBad.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for traversal, got %d", recBad.Code)
	}

	// 2. First valid launch spawns pod and redirects 302
	req1 := httptest.NewRequest(http.MethodGet, "/launch?lab=01_hello_sandbox.ipynb", nil)
	rec1 := httptest.NewRecorder()
	c1 := e.NewContext(req1, rec1)
	c1.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})
	if err := handleLaunchLab(c1); err != nil {
		t.Fatalf("handleLaunchLab 1 failed: %v", err)
	}
	if rec1.Code != http.StatusFound {
		t.Fatalf("expected 302, got %d: %s", rec1.Code, rec1.Body.String())
	}
	loc1 := rec1.Header().Get("Location")
	if !strings.HasPrefix(loc1, "/user1/jupyterlab/") || !strings.HasSuffix(loc1, "/lab/tree/labs/01_hello_sandbox.ipynb") {
		t.Fatalf("unexpected Location header: %q", loc1)
	}

	pods, err := fakeClient.CoreV1().Pods("workload").List(context.Background(), metav1.ListOptions{})
	if err != nil || len(pods.Items) != 1 {
		t.Fatalf("expected 1 spawned pod, got %d (err=%v)", len(pods.Items), err)
	}
	firstSessionID := pods.Items[0].Labels["session-id"]
	// Mark pod Running so second launch reuses it
	pods.Items[0].Status.Phase = corev1.PodRunning
	_, _ = fakeClient.CoreV1().Pods("workload").UpdateStatus(context.Background(), &pods.Items[0], metav1.UpdateOptions{})

	// 3. Second valid launch reuses existing pod without spawning another
	req2 := httptest.NewRequest(http.MethodGet, "/launch?lab=week01/lab01.ipynb", nil)
	rec2 := httptest.NewRecorder()
	c2 := e.NewContext(req2, rec2)
	c2.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})
	if err := handleLaunchLab(c2); err != nil {
		t.Fatalf("handleLaunchLab 2 failed: %v", err)
	}
	if rec2.Code != http.StatusFound {
		t.Fatalf("expected 302 on reuse, got %d", rec2.Code)
	}
	loc2 := rec2.Header().Get("Location")
	expectedLoc2 := "/user1/jupyterlab/" + firstSessionID + "/lab/tree/labs/week01/lab01.ipynb"
	if loc2 != expectedLoc2 {
		t.Errorf("expected reused Location %q, got %q", expectedLoc2, loc2)
	}
	podsAfter, _ := fakeClient.CoreV1().Pods("workload").List(context.Background(), metav1.ListOptions{})
	if len(podsAfter.Items) != 1 {
		t.Errorf("expected still 1 pod after reuse, got %d", len(podsAfter.Items))
	}
}

func TestHandleCloneLab_FlatNestedAndNonClobber(t *testing.T) {
	labsDir, base := setupTestLabsDir(t)
	projectsDir := filepath.Join(base, "projects")
	if err := os.MkdirAll(filepath.Join(projectsDir, "project1"), 0755); err != nil {
		t.Fatalf("mkdir project1: %v", err)
	}
	t.Setenv("LABS_DIR", labsDir)
	t.Setenv("PROJECTS_DIR", projectsDir)

	e := echo.New()

	// 1. Clone flat lab
	body1 := bytes.NewBufferString(`{"lab":"01_hello_sandbox.ipynb"}`)
	req1 := httptest.NewRequest(http.MethodPost, "/api/labs/clone", body1)
	req1.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec1 := httptest.NewRecorder()
	c1 := e.NewContext(req1, rec1)
	c1.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})

	if err := handleCloneLab(c1); err != nil {
		t.Fatalf("handleCloneLab 1 failed: %v", err)
	}
	if rec1.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec1.Code, rec1.Body.String())
	}

	dest1 := filepath.Join(projectsDir, "project1", "my_labs", "01_hello_sandbox.ipynb")
	if _, err := os.Stat(dest1); err != nil {
		t.Fatalf("expected cloned file at %s: %v", dest1, err)
	}

	// 2. Repeat clone must not clobber original
	if err := os.WriteFile(dest1, []byte("STUDENT_EDITS"), 0644); err != nil {
		t.Fatalf("write student edits: %v", err)
	}
	body2 := bytes.NewBufferString(`{"lab":"01_hello_sandbox.ipynb"}`)
	req2 := httptest.NewRequest(http.MethodPost, "/api/labs/clone", body2)
	req2.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec2 := httptest.NewRecorder()
	c2 := e.NewContext(req2, rec2)
	c2.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})

	if err := handleCloneLab(c2); err != nil {
		t.Fatalf("handleCloneLab 2 failed: %v", err)
	}
	if rec2.Code != http.StatusOK {
		t.Fatalf("expected 200 on repeat clone, got %d: %s", rec2.Code, rec2.Body.String())
	}
	preserved, _ := os.ReadFile(dest1)
	if string(preserved) != "STUDENT_EDITS" {
		t.Errorf("repeat clone clobbered existing student edits")
	}

	// 3. Clone nested module lab copies sibling helper.py too
	body3 := bytes.NewBufferString(`{"lab":"week01/lab01.ipynb"}`)
	req3 := httptest.NewRequest(http.MethodPost, "/api/labs/clone", body3)
	req3.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec3 := httptest.NewRecorder()
	c3 := e.NewContext(req3, rec3)
	c3.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})

	if err := handleCloneLab(c3); err != nil {
		t.Fatalf("handleCloneLab nested failed: %v", err)
	}
	if rec3.Code != http.StatusOK {
		t.Fatalf("expected 200 on nested clone, got %d: %s", rec3.Code, rec3.Body.String())
	}
	if _, err := os.Stat(filepath.Join(projectsDir, "project1", "my_labs", "week01", "lab01.ipynb")); err != nil {
		t.Errorf("expected nested cloned notebook: %v", err)
	}
	if _, err := os.Stat(filepath.Join(projectsDir, "project1", "my_labs", "week01", "helper.py")); err != nil {
		t.Errorf("expected nested sibling helper.py to be cloned: %v", err)
	}

	// 4. Reject traversal
	bodyBad := bytes.NewBufferString(`{"lab":"../../etc/passwd"}`)
	reqBad := httptest.NewRequest(http.MethodPost, "/api/labs/clone", bodyBad)
	reqBad.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	recBad := httptest.NewRecorder()
	cBad := e.NewContext(reqBad, recBad)
	cBad.Set("unified_user", &UnifiedUserContext{StudentID: "user1", Role: "student"})
	_ = handleCloneLab(cBad)
	if recBad.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for clone traversal, got %d", recBad.Code)
	}
}
