package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"
)

// LabEntry describes a discoverable curriculum notebook under LABS_DIR.
type LabEntry struct {
	Path      string `json:"path"`
	Title     string `json:"title"`
	Module    string `json:"module"`
	SizeBytes int64  `json:"size_bytes"`
}

var (
	// labReadyProbe checks whether a JupyterLab session pod is serving HTTP requests.
	// Swappable in unit tests.
	labReadyProbe = defaultLabReadyProbe

	// lookupJupyterManifest locates the jupyterlab AppManifest for a project.
	// Swappable in unit tests.
	lookupJupyterManifest = defaultLookupJupyterManifest
)

func getLabsDir() string {
	return getEnv("LABS_DIR", "/mnt/storage/labs")
}

func getProjectsDir() string {
	return getEnv("PROJECTS_DIR", "/mnt/storage/projects")
}

// resolveLabPath validates rawLab as a safe relative .ipynb path inside labsDir,
// blocking directory traversal, absolute paths, non-.ipynb files, and symlinks escaping labsDir.
func resolveLabPath(labsDir, rawLab string) (string, string, error) {
	rawLab = strings.TrimSpace(rawLab)
	if rawLab == "" {
		return "", "", errors.New("missing lab parameter")
	}
	if strings.ContainsRune(rawLab, '\x00') {
		return "", "", errors.New("invalid null byte in lab path")
	}
	if filepath.IsAbs(rawLab) || strings.HasPrefix(rawLab, "/") || strings.HasPrefix(rawLab, "\\") {
		return "", "", errors.New("absolute lab path is not allowed")
	}

	cleaned := filepath.ToSlash(filepath.Clean(rawLab))
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") || strings.Contains(cleaned, "/../") {
		return "", "", errors.New("path traversal is not allowed")
	}
	if !strings.HasSuffix(strings.ToLower(cleaned), ".ipynb") {
		return "", "", errors.New("lab must be a .ipynb notebook")
	}

	canonicalRoot, err := filepath.EvalSymlinks(labsDir)
	if err != nil {
		return "", "", fmt.Errorf("labs directory unavailable: %w", err)
	}
	canonicalRoot, err = filepath.Abs(canonicalRoot)
	if err != nil {
		return "", "", fmt.Errorf("failed to resolve labs root: %w", err)
	}

	joined := filepath.Join(canonicalRoot, filepath.FromSlash(cleaned))
	resolved, err := filepath.EvalSymlinks(joined)
	if err != nil {
		return "", "", fmt.Errorf("lab not found: %w", err)
	}
	resolved, err = filepath.Abs(resolved)
	if err != nil {
		return "", "", fmt.Errorf("failed to resolve lab path: %w", err)
	}

	rootPrefix := canonicalRoot + string(filepath.Separator)
	if !strings.HasPrefix(resolved, rootPrefix) {
		return "", "", errors.New("symlink escape outside labs directory is not allowed")
	}

	info, err := os.Stat(resolved)
	if err != nil {
		return "", "", fmt.Errorf("cannot stat lab: %w", err)
	}
	if info.IsDir() {
		return "", "", errors.New("lab path points to a directory")
	}

	return cleaned, resolved, nil
}

func formatLabTitle(relPath string) string {
	base := strings.TrimSuffix(filepath.Base(relPath), filepath.Ext(relPath))
	base = strings.ReplaceAll(base, "_", " ")
	base = strings.ReplaceAll(base, "-", " ")
	return base
}

func resolveActiveUserAndProject(c echo.Context) (string, string, string, error) {
	uCtx, ok := c.Get("unified_user").(*UnifiedUserContext)
	if !ok || uCtx == nil || uCtx.StudentID == "" {
		return "", "", "", errors.New("unauthorized")
	}
	username := uCtx.StudentID
	role := NormalizeRole(uCtx.Role)

	project := ""
	if tok, ok := c.Get("user").(*jwt.Token); ok && tok != nil {
		if claims, ok := tok.Claims.(jwt.MapClaims); ok {
			if prj, ok := claims["prj"].(string); ok && prj != "" {
				project = prj
			}
		}
	}
	if project == "" && identityManager != nil {
		if _, defProj, err := identityManager.EnsureStudentProvisioned(username); err == nil && defProj != "" {
			project = defProj
		}
	}
	if project == "" {
		project = "project1"
	}

	return username, project, role, nil
}

func defaultLookupJupyterManifest(project string) *AppManifest {
	for _, app := range scanApps(project) {
		if app.ID == "jupyterlab" && app.Type == "interactive" {
			manifest := app
			return &manifest
		}
	}
	return &AppManifest{
		ID:        "jupyterlab",
		Name:      "JupyterLab",
		Type:      "interactive",
		Image:     "interactive-jupyter:latest",
		SlurmArgs: map[string]string{"cpus-per-task": "2", "mem": "4G"},
	}
}

func defaultLabReadyProbe(ctx context.Context, probeURL string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, probeURL, nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode >= 200 && resp.StatusCode < 400 {
		return nil
	}
	return fmt.Errorf("jupyterlab not ready: HTTP %d", resp.StatusCode)
}

func waitForLabReady(ctx context.Context, probeURL string) error {
	pollCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	if err := labReadyProbe(pollCtx, probeURL); err == nil {
		return nil
	}

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-pollCtx.Done():
			return pollCtx.Err()
		case <-ticker.C:
			if err := labReadyProbe(pollCtx, probeURL); err == nil {
				return nil
			}
		}
	}
}

// handleListLabs dynamically walks LABS_DIR and returns all valid flat and nested .ipynb labs.
func handleListLabs(c echo.Context) error {
	if _, _, _, err := resolveActiveUserAndProject(c); err != nil {
		return c.JSON(http.StatusUnauthorized, map[string]string{"error": "Unauthorized"})
	}

	labsDir := getLabsDir()
	labs := make([]LabEntry, 0)

	err := filepath.WalkDir(labsDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if d.IsDir() {
			// Skip hidden directories like .ipynb_checkpoints
			if path != labsDir && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(strings.ToLower(d.Name()), ".ipynb") {
			return nil
		}

		rel, err := filepath.Rel(labsDir, path)
		if err != nil {
			return nil
		}
		cleanRel, resolvedAbs, err := resolveLabPath(labsDir, rel)
		if err != nil {
			return nil
		}
		info, err := os.Stat(resolvedAbs)
		if err != nil {
			return nil
		}

		mod := filepath.ToSlash(filepath.Dir(cleanRel))
		if mod == "." {
			mod = ""
		}

		labs = append(labs, LabEntry{
			Path:      cleanRel,
			Title:     formatLabTitle(cleanRel),
			Module:    mod,
			SizeBytes: info.Size(),
		})
		return nil
	})
	if err != nil && !os.IsNotExist(err) {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to list labs"})
	}

	sort.Slice(labs, func(i, j int) bool {
		return labs[i].Path < labs[j].Path
	})

	return c.JSON(http.StatusOK, map[string]interface{}{
		"labs": labs,
	})
}

// handleLaunchLab validates ?lab=<relpath>, reuses or spawns a JupyterLab pod, waits for readiness, and 302 redirects.
func handleLaunchLab(c echo.Context) error {
	username, project, role, err := resolveActiveUserAndProject(c)
	if err != nil {
		return c.String(http.StatusUnauthorized, "Unauthorized")
	}

	rawLab := c.QueryParam("lab")
	relPath, _, err := resolveLabPath(getLabsDir(), rawLab)
	if err != nil {
		return c.String(http.StatusBadRequest, fmt.Sprintf("Invalid lab path: %v", err))
	}

	if sessionManager == nil {
		return c.String(http.StatusServiceUnavailable, "Session manager unavailable")
	}

	unlock := sessionManager.lockUserProject(username, project)
	ctx := c.Request().Context()
	sessionID, basePath, err := sessionManager.FindActiveSession(ctx, username, project, "jupyterlab", role)
	if err != nil {
		unlock()
		return c.String(http.StatusInternalServerError, fmt.Sprintf("Failed to check active session: %v", err))
	}

	if sessionID == "" {
		manifest := lookupJupyterManifest(project)
		if manifest == nil {
			unlock()
			return c.String(http.StatusInternalServerError, "JupyterLab manifest not found")
		}
		sessionID = fmt.Sprintf("%d", time.Now().UnixMilli())
		basePath, err = sessionManager.CreateSession(ctx, manifest, nil, username, project, sessionID, role)
		if err != nil {
			unlock()
			return c.String(http.StatusInternalServerError, fmt.Sprintf("Failed to create interactive session: %v", err))
		}
	}
	unlock()

	probeURL := fmt.Sprintf("http://svc-%s.%s.svc.cluster.local:8888%sapi", sessionID, sessionManager.namespace, basePath)
	if err := waitForLabReady(ctx, probeURL); err != nil {
		return c.String(http.StatusGatewayTimeout, fmt.Sprintf("Lab environment timed out starting: %v", err))
	}

	targetURL := fmt.Sprintf("%slab/tree/labs/%s", basePath, relPath)
	return c.Redirect(http.StatusFound, targetURL)
}

func bestEffortChown(path string, uid, gid int) {
	if uid >= 0 && gid >= 0 {
		_ = os.Chown(path, uid, gid)
	}
}

func copyFileWithPerms(src, dst string, uid, gid int) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0664)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	_ = os.Chmod(dst, 0664)
	bestEffortChown(dst, uid, gid)
	return nil
}

func uniqueFilePath(dst string) string {
	if _, err := os.Stat(dst); os.IsNotExist(err) {
		return dst
	}
	ext := filepath.Ext(dst)
	stem := strings.TrimSuffix(dst, ext)
	ts := time.Now().Format("20060102_150405")
	candidate := fmt.Sprintf("%s_%s%s", stem, ts, ext)
	for i := 1; ; i++ {
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate
		}
		candidate = fmt.Sprintf("%s_%s_%d%s", stem, ts, i, ext)
	}
}

func uniqueDirPath(dst string) string {
	if _, err := os.Stat(dst); os.IsNotExist(err) {
		return dst
	}
	ts := time.Now().Format("20060102_150405")
	candidate := fmt.Sprintf("%s_%s", dst, ts)
	for i := 1; ; i++ {
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate
		}
		candidate = fmt.Sprintf("%s_%s_%d", dst, ts, i)
	}
}

func copyModuleDir(canonicalRoot, srcDir, dstDir string, uid, gid int) error {
	if err := os.MkdirAll(dstDir, 0770); err != nil {
		return err
	}
	_ = os.Chmod(dstDir, 02770)
	bestEffortChown(dstDir, uid, gid)

	rootPrefix := canonicalRoot + string(filepath.Separator)

	return filepath.WalkDir(srcDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}

		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			return nil
		}
		resolvedAbs, err := filepath.Abs(resolved)
		if err != nil || !strings.HasPrefix(resolvedAbs, rootPrefix) {
			return nil
		}

		target := filepath.Join(dstDir, rel)
		if d.IsDir() {
			if strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			if err := os.MkdirAll(target, 0770); err != nil {
				return err
			}
			_ = os.Chmod(target, 02770)
			bestEffortChown(target, uid, gid)
			return nil
		}
		return copyFileWithPerms(resolvedAbs, target, uid, gid)
	})
}

// handleCloneLab copies a flat notebook (or nested module folder) from LABS_DIR into projects/<active_project>/my_labs/.
func handleCloneLab(c echo.Context) error {
	username, project, _, err := resolveActiveUserAndProject(c)
	if err != nil {
		return c.JSON(http.StatusUnauthorized, map[string]string{"error": "Unauthorized"})
	}

	rawLab := c.FormValue("lab")
	if rawLab == "" && c.Request().Body != nil {
		var body struct {
			Lab string `json:"lab"`
		}
		if err := json.NewDecoder(c.Request().Body).Decode(&body); err == nil {
			rawLab = body.Lab
		}
	}

	labsDir := getLabsDir()
	relPath, srcAbs, err := resolveLabPath(labsDir, rawLab)
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("Invalid lab path: %v", err)})
	}

	uid, gid := -1, -1
	if secCtx := resolveUserSecurityContext(username, project); secCtx != nil {
		if secCtx.RunAsUser != nil {
			uid = int(*secCtx.RunAsUser)
		}
		if secCtx.RunAsGroup != nil {
			gid = int(*secCtx.RunAsGroup)
		}
	}

	projectDir := filepath.Join(getProjectsDir(), project)
	myLabsDir := filepath.Join(projectDir, "my_labs")
	if err := os.MkdirAll(myLabsDir, 0770); err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": fmt.Sprintf("Failed to create my_labs directory: %v", err)})
	}
	_ = os.Chmod(myLabsDir, 02770)
	bestEffortChown(myLabsDir, uid, gid)

	modDir := filepath.ToSlash(filepath.Dir(relPath))
	var clonedRel string

	if modDir == "." {
		dstAbs := uniqueFilePath(filepath.Join(myLabsDir, filepath.Base(relPath)))
		if err := copyFileWithPerms(srcAbs, dstAbs, uid, gid); err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]string{"error": fmt.Sprintf("Failed to clone lab: %v", err)})
		}
		clonedRel = filepath.ToSlash(filepath.Join("my_labs", filepath.Base(dstAbs)))
	} else {
		canonicalRoot, err := filepath.EvalSymlinks(labsDir)
		if err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]string{"error": "Labs directory unavailable"})
		}
		canonicalRoot, _ = filepath.Abs(canonicalRoot)

		srcModDir := filepath.Join(canonicalRoot, filepath.FromSlash(modDir))
		dstModDir := uniqueDirPath(filepath.Join(myLabsDir, filepath.FromSlash(modDir)))
		if err := copyModuleDir(canonicalRoot, srcModDir, dstModDir, uid, gid); err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]string{"error": fmt.Sprintf("Failed to clone lab module: %v", err)})
		}
		relToMyLabs, _ := filepath.Rel(myLabsDir, filepath.Join(dstModDir, filepath.Base(relPath)))
		clonedRel = filepath.ToSlash(filepath.Join("my_labs", relToMyLabs))
	}

	return c.JSON(http.StatusOK, map[string]interface{}{
		"status":      "cloned",
		"lab":         relPath,
		"cloned_path": clonedRel,
		"project":     project,
	})
}
