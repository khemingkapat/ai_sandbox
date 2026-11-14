package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/labstack/echo/v4"
	_ "github.com/lib/pq"
	_ "github.com/mattn/go-sqlite3"
)

var (
	validUsernameRegex = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,31}$`)
	reservedUsernames  = map[string]bool{
		"root":    true,
		"admin":   true,
		"daemon":  true,
		"bin":     true,
		"sys":     true,
		"sync":    true,
		"slurm":   true,
		"nobody":  true,
		"postfix": true,
	}
)

type ProjectInfo struct {
	ProjectID   string   `json:"project_id"`
	DisplayName string   `json:"display_name"`
	GID         int      `json:"gid"`
	Owner       string   `json:"owner"`
	Members     []string `json:"members"`
	IsActive    bool     `json:"is_active"`
}

type IdentityManager struct {
	db            *sql.DB
	driver        string
	extrausersDir string
	projectsDir   string
	slurmURL      string
	slurmToken    string
	slurmCluster  string
	maxProjects   int
	mu            sync.Mutex
}

func NewIdentityManager(driver, dsn, extrausersDir, projectsDir, slurmURL string) (*IdentityManager, error) {
	if driver == "" {
		driver = "sqlite3"
	}
	db, err := sql.Open(driver, dsn)
	if err != nil {
		return nil, fmt.Errorf("failed to open database (%s): %w", driver, err)
	}

	im := &IdentityManager{
		db:            db,
		driver:        driver,
		extrausersDir: extrausersDir,
		projectsDir:   projectsDir,
		slurmURL:      slurmURL,
		slurmToken:    os.Getenv("SLURM_JWT"),
		slurmCluster:  "slurm_slurm",
		maxProjects:   5,
	}

	if clusterEnv := os.Getenv("SLURM_CLUSTER_NAME"); clusterEnv != "" {
		im.slurmCluster = clusterEnv
	}

	if err := im.initSchema(); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to init schema: %w", err)
	}

	if err := im.seedBaseline(); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to seed baseline accounts: %w", err)
	}

	return im, nil
}

func (im *IdentityManager) Close() error {
	if im.db != nil {
		return im.db.Close()
	}
	return nil
}

func (im *IdentityManager) initSchema() error {
	queries := []string{
		`CREATE TABLE IF NOT EXISTS portal_users (
			student_id VARCHAR(64) PRIMARY KEY,
			uid INTEGER UNIQUE NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		);`,
		`CREATE TABLE IF NOT EXISTS portal_projects (
			project_id VARCHAR(64) PRIMARY KEY,
			display_name VARCHAR(128) NOT NULL,
			gid INTEGER UNIQUE NOT NULL,
			owner_student_id VARCHAR(64) NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		);`,
		`CREATE TABLE IF NOT EXISTS portal_memberships (
			project_id VARCHAR(64) NOT NULL,
			student_id VARCHAR(64) NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (project_id, student_id)
		);`,
	}

	for _, q := range queries {
		if _, err := im.db.Exec(q); err != nil {
			return err
		}
	}
	return nil
}

func (im *IdentityManager) seedBaseline() error {
	baselineUsers := []struct {
		studentID string
		uid       int
	}{
		{"user1", 1001},
		{"user2", 1002},
		{"user3", 1003},
		{"user4", 1004},
	}

	for _, u := range baselineUsers {
		if im.driver == "postgres" {
			_, err := im.db.Exec(`INSERT INTO portal_users (student_id, uid) VALUES ($1, $2) ON CONFLICT (student_id) DO NOTHING;`, u.studentID, u.uid)
			if err != nil {
				return err
			}
		} else {
			_, err := im.db.Exec(`INSERT OR IGNORE INTO portal_users (student_id, uid) VALUES (?, ?);`, u.studentID, u.uid)
			if err != nil {
				return err
			}
		}
	}

	baselineProjects := []struct {
		projectID   string
		displayName string
		gid         int
		owner       string
	}{
		{"project1", "Baseline Project 1", 2001, "user1"},
		{"project2", "Baseline Project 2", 2002, "user2"},
		{"project3", "Baseline Project 3", 2003, "user3"},
	}

	for _, p := range baselineProjects {
		if im.driver == "postgres" {
			_, err := im.db.Exec(`INSERT INTO portal_projects (project_id, display_name, gid, owner_student_id) VALUES ($1, $2, $3, $4) ON CONFLICT (project_id) DO NOTHING;`, p.projectID, p.displayName, p.gid, p.owner)
			if err != nil {
				return err
			}
			_, err = im.db.Exec(`INSERT INTO portal_memberships (project_id, student_id) VALUES ($1, $2) ON CONFLICT (project_id, student_id) DO NOTHING;`, p.projectID, p.owner)
			if err != nil {
				return err
			}
		} else {
			_, err := im.db.Exec(`INSERT OR IGNORE INTO portal_projects (project_id, display_name, gid, owner_student_id) VALUES (?, ?, ?, ?);`, p.projectID, p.displayName, p.gid, p.owner)
			if err != nil {
				return err
			}
			_, err = im.db.Exec(`INSERT OR IGNORE INTO portal_memberships (project_id, student_id) VALUES (?, ?);`, p.projectID, p.owner)
			if err != nil {
				return err
			}
		}
	}

	return nil
}

func ValidateStudentID(studentID string) error {
	if len(studentID) == 0 || len(studentID) > 32 {
		return fmt.Errorf("invalid student_id length: %q", studentID)
	}
	if !validUsernameRegex.MatchString(studentID) {
		return fmt.Errorf("invalid characters in student_id: %q", studentID)
	}
	if reservedUsernames[studentID] {
		return fmt.Errorf("student_id %q is reserved", studentID)
	}
	return nil
}

func (im *IdentityManager) GetUserUID(username string) (int, error) {
	im.mu.Lock()
	defer im.mu.Unlock()
	var uid int
	row := im.db.QueryRow("SELECT uid FROM portal_users WHERE student_id = $1;", username)
	if im.driver == "sqlite3" {
		row = im.db.QueryRow("SELECT uid FROM portal_users WHERE student_id = ?;", username)
	}
	if err := row.Scan(&uid); err != nil {
		return 0, err
	}
	return uid, nil
}

func (im *IdentityManager) GetProjectGID(project string) (int, error) {
	im.mu.Lock()
	defer im.mu.Unlock()
	var gid int
	row := im.db.QueryRow("SELECT gid FROM portal_projects WHERE project_id = $1;", project)
	if im.driver == "sqlite3" {
		row = im.db.QueryRow("SELECT gid FROM portal_projects WHERE project_id = ?;", project)
	}
	if err := row.Scan(&gid); err != nil {
		return 0, err
	}
	return gid, nil
}

func (im *IdentityManager) EnsureStudentProvisioned(studentID string) (int, string, error) {
	if err := ValidateStudentID(studentID); err != nil {
		return 0, "", err
	}

	im.mu.Lock()
	defer im.mu.Unlock()

	var existingUID int
	query := "SELECT uid FROM portal_users WHERE student_id = $1;"
	if im.driver == "sqlite3" {
		query = "SELECT uid FROM portal_users WHERE student_id = ?;"
	}
	err := im.db.QueryRow(query, studentID).Scan(&existingUID)
	if err == nil {
		// Existing user - find their first project or default project
		var projID string
		pQuery := "SELECT project_id FROM portal_memberships WHERE student_id = $1 ORDER BY created_at ASC LIMIT 1;"
		if im.driver == "sqlite3" {
			pQuery = "SELECT project_id FROM portal_memberships WHERE student_id = ? ORDER BY created_at ASC LIMIT 1;"
		}
		pErr := im.db.QueryRow(pQuery, studentID).Scan(&projID)
		if pErr == nil {
			return existingUID, projID, nil
		}
		// If user exists without project, create their personal project
		projSlug, _, createErr := im.createProjectInternal(studentID, fmt.Sprintf("%s Default Project", studentID), "p-"+studentID)
		return existingUID, projSlug, createErr
	}

	if !errors.Is(err, sql.ErrNoRows) {
		return 0, "", err
	}

	// Calculate monotonic UID >= 2000
	var maxUID sql.NullInt64
	_ = im.db.QueryRow("SELECT MAX(uid) FROM portal_users;").Scan(&maxUID)
	newUID := 2000
	if maxUID.Valid && int(maxUID.Int64) >= 2000 {
		newUID = int(maxUID.Int64) + 1
	}

	insertUser := "INSERT INTO portal_users (student_id, uid) VALUES ($1, $2);"
	if im.driver == "sqlite3" {
		insertUser = "INSERT INTO portal_users (student_id, uid) VALUES (?, ?);"
	}
	if _, err := im.db.Exec(insertUser, studentID, newUID); err != nil {
		return 0, "", fmt.Errorf("failed to insert student: %w", err)
	}

	defaultProjSlug, _, err := im.createProjectInternal(studentID, fmt.Sprintf("%s Default Project", studentID), "p-"+studentID)
	if err != nil {
		return 0, "", fmt.Errorf("failed to create default project: %w", err)
	}

	return newUID, defaultProjSlug, nil
}

func (im *IdentityManager) CreateProject(ownerStudentID, displayName string) (string, int, error) {
	if err := ValidateStudentID(ownerStudentID); err != nil {
		return "", 0, err
	}
	displayName = strings.TrimSpace(displayName)
	if len(displayName) == 0 || len(displayName) > 64 {
		return "", 0, fmt.Errorf("invalid display_name length (must be 1-64 chars)")
	}

	im.mu.Lock()
	defer im.mu.Unlock()

	// Enforce quota
	var ownedCount int
	countQuery := "SELECT COUNT(*) FROM portal_projects WHERE owner_student_id = $1;"
	if im.driver == "sqlite3" {
		countQuery = "SELECT COUNT(*) FROM portal_projects WHERE owner_student_id = ?;"
	}
	if err := im.db.QueryRow(countQuery, ownerStudentID).Scan(&ownedCount); err != nil {
		return "", 0, err
	}
	if ownedCount >= im.maxProjects {
		return "", 0, fmt.Errorf("quota exceeded: user %s has reached maximum active projects (%d)", ownerStudentID, im.maxProjects)
	}

	randomHex := make([]byte, 4)
	if _, err := rand.Read(randomHex); err != nil {
		return "", 0, err
	}
	slug := fmt.Sprintf("p-%s", hex.EncodeToString(randomHex))

	return im.createProjectInternal(ownerStudentID, displayName, slug)
}

func (im *IdentityManager) createProjectInternal(ownerStudentID, displayName, slug string) (string, int, error) {
	// Monotonic GID >= 10000
	var maxGID sql.NullInt64
	_ = im.db.QueryRow("SELECT MAX(gid) FROM portal_projects;").Scan(&maxGID)
	newGID := 10000
	if maxGID.Valid && int(maxGID.Int64) >= 10000 {
		newGID = int(maxGID.Int64) + 1
	}

	insertProj := "INSERT INTO portal_projects (project_id, display_name, gid, owner_student_id) VALUES ($1, $2, $3, $4);"
	insertMem := "INSERT INTO portal_memberships (project_id, student_id) VALUES ($1, $2);"
	if im.driver == "sqlite3" {
		insertProj = "INSERT INTO portal_projects (project_id, display_name, gid, owner_student_id) VALUES (?, ?, ?, ?);"
		insertMem = "INSERT INTO portal_memberships (project_id, student_id) VALUES (?, ?);"
	}

	if _, err := im.db.Exec(insertProj, slug, displayName, newGID, ownerStudentID); err != nil {
		return "", 0, fmt.Errorf("failed to insert project: %w", err)
	}
	if _, err := im.db.Exec(insertMem, slug, ownerStudentID); err != nil {
		return "", 0, fmt.Errorf("failed to insert project owner membership: %w", err)
	}

	// Create project directory with 2770 permissions
	if im.projectsDir != "" {
		projPath := filepath.Join(im.projectsDir, slug)
		if err := os.MkdirAll(projPath, 0755); err != nil {
			return "", 0, fmt.Errorf("failed to mkdir project dir: %w", err)
		}
		// Apply setgid | 0770 (2770)
		if err := os.Chmod(projPath, os.ModeSetgid|0770); err != nil {
			return "", 0, fmt.Errorf("failed to chmod 2770: %w", err)
		}
	}

	return slug, newGID, nil
}

func (im *IdentityManager) InviteMember(callerStudentID, projectID, targetStudentID string) error {
	if err := ValidateStudentID(callerStudentID); err != nil {
		return err
	}
	if err := ValidateStudentID(targetStudentID); err != nil {
		return err
	}

	im.mu.Lock()
	defer im.mu.Unlock()

	// Verify caller is a member of projectID
	var callerIsMember int
	mQuery := "SELECT COUNT(*) FROM portal_memberships WHERE project_id = $1 AND student_id = $2;"
	if im.driver == "sqlite3" {
		mQuery = "SELECT COUNT(*) FROM portal_memberships WHERE project_id = ? AND student_id = ?;"
	}
	if err := im.db.QueryRow(mQuery, projectID, callerStudentID).Scan(&callerIsMember); err != nil || callerIsMember == 0 {
		return fmt.Errorf("caller %s is not a member of project %s", callerStudentID, projectID)
	}

	// Ensure target student exists in portal_users (pre-provision if necessary)
	var targetUID int
	uQuery := "SELECT uid FROM portal_users WHERE student_id = $1;"
	if im.driver == "sqlite3" {
		uQuery = "SELECT uid FROM portal_users WHERE student_id = ?;"
	}
	err := im.db.QueryRow(uQuery, targetStudentID).Scan(&targetUID)
	if errors.Is(err, sql.ErrNoRows) {
		var maxUID sql.NullInt64
		_ = im.db.QueryRow("SELECT MAX(uid) FROM portal_users;").Scan(&maxUID)
		newUID := 2000
		if maxUID.Valid && int(maxUID.Int64) >= 2000 {
			newUID = int(maxUID.Int64) + 1
		}
		insUser := "INSERT INTO portal_users (student_id, uid) VALUES ($1, $2);"
		if im.driver == "sqlite3" {
			insUser = "INSERT INTO portal_users (student_id, uid) VALUES (?, ?);"
		}
		if _, err := im.db.Exec(insUser, targetStudentID, newUID); err != nil {
			return fmt.Errorf("failed to pre-provision target user: %w", err)
		}
	} else if err != nil {
		return err
	}

	// Insert membership
	insMem := "INSERT INTO portal_memberships (project_id, student_id) VALUES ($1, $2) ON CONFLICT (project_id, student_id) DO NOTHING;"
	if im.driver == "sqlite3" {
		insMem = "INSERT OR IGNORE INTO portal_memberships (project_id, student_id) VALUES (?, ?);"
	}
	if _, err := im.db.Exec(insMem, projectID, targetStudentID); err != nil {
		return fmt.Errorf("failed to add membership: %w", err)
	}

	return nil
}

func (im *IdentityManager) ListUserProjects(studentID string) ([]ProjectInfo, error) {
	im.mu.Lock()
	defer im.mu.Unlock()
	query := `
		SELECT p.project_id, p.display_name, p.gid, p.owner_student_id
		FROM portal_projects p
		JOIN portal_memberships m ON p.project_id = m.project_id
		WHERE m.student_id = $1
		ORDER BY p.created_at ASC;
	`
	if im.driver == "sqlite3" {
		query = `
			SELECT p.project_id, p.display_name, p.gid, p.owner_student_id
			FROM portal_projects p
			JOIN portal_memberships m ON p.project_id = m.project_id
			WHERE m.student_id = ?
			ORDER BY p.created_at ASC;
		`
	}

	rows, err := im.db.Query(query, studentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var projects []ProjectInfo
	for rows.Next() {
		var p ProjectInfo
		if err := rows.Scan(&p.ProjectID, &p.DisplayName, &p.GID, &p.Owner); err != nil {
			return nil, err
		}
		projects = append(projects, p)
	}

	// Fetch members for each project
	for i := range projects {
		mQuery := "SELECT student_id FROM portal_memberships WHERE project_id = $1 ORDER BY student_id ASC;"
		if im.driver == "sqlite3" {
			mQuery = "SELECT student_id FROM portal_memberships WHERE project_id = ? ORDER BY student_id ASC;"
		}
		mRows, err := im.db.Query(mQuery, projects[i].ProjectID)
		if err != nil {
			continue
		}
		for mRows.Next() {
			var m string
			if err := mRows.Scan(&m); err == nil {
				projects[i].Members = append(projects[i].Members, m)
			}
		}
		mRows.Close()
	}

	return projects, nil
}

func (im *IdentityManager) CompileExtrausers() error {
	if im.extrausersDir == "" {
		return nil
	}
	im.mu.Lock()
	defer im.mu.Unlock()

	if err := os.MkdirAll(im.extrausersDir, 0755); err != nil {
		return err
	}

	lockFile := filepath.Join(im.extrausersDir, ".extrausers.lock")
	lockFd, err := os.OpenFile(lockFile, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return fmt.Errorf("failed to open lockfile: %w", err)
	}
	defer lockFd.Close()

	if err := syscall.Flock(int(lockFd.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("failed to flock: %w", err)
	}
	defer syscall.Flock(int(lockFd.Fd()), syscall.LOCK_UN)

	// Read all users
	uRows, err := im.db.Query("SELECT student_id, uid FROM portal_users ORDER BY uid ASC;")
	if err != nil {
		return err
	}
	defer uRows.Close()

	var passwdBuf bytes.Buffer
	for uRows.Next() {
		var user string
		var uid int
		if err := uRows.Scan(&user, &uid); err != nil {
			return err
		}
		// student_id:x:uid:uid:Student User:/home/student_id:/bin/bash
		fmt.Fprintf(&passwdBuf, "%s:x:%d:%d:Student User:/home/%s:/bin/bash\n", user, uid, uid, user)
	}

	// Read all projects & memberships
	pRows, err := im.db.Query("SELECT project_id, gid FROM portal_projects ORDER BY gid ASC;")
	if err != nil {
		return err
	}
	defer pRows.Close()

	var groupBuf bytes.Buffer
	for pRows.Next() {
		var projID string
		var gid int
		if err := pRows.Scan(&projID, &gid); err != nil {
			return err
		}

		mQuery := "SELECT student_id FROM portal_memberships WHERE project_id = $1 ORDER BY student_id ASC;"
		if im.driver == "sqlite3" {
			mQuery = "SELECT student_id FROM portal_memberships WHERE project_id = ? ORDER BY student_id ASC;"
		}
		mRows, err := im.db.Query(mQuery, projID)
		var members []string
		if err == nil {
			for mRows.Next() {
				var s string
				if err := mRows.Scan(&s); err == nil {
					members = append(members, s)
				}
			}
			mRows.Close()
		}
		// proj_id:x:gid:member1,member2
		fmt.Fprintf(&groupBuf, "%s:x:%d:%s\n", projID, gid, strings.Join(members, ","))
	}

	// Atomic write passwd
	tmpPasswd := filepath.Join(im.extrausersDir, "passwd.tmp")
	if err := os.WriteFile(tmpPasswd, passwdBuf.Bytes(), 0644); err != nil {
		return err
	}
	if err := os.Rename(tmpPasswd, filepath.Join(im.extrausersDir, "passwd")); err != nil {
		return err
	}

	// Atomic write group
	tmpGroup := filepath.Join(im.extrausersDir, "group.tmp")
	if err := os.WriteFile(tmpGroup, groupBuf.Bytes(), 0644); err != nil {
		return err
	}
	if err := os.Rename(tmpGroup, filepath.Join(im.extrausersDir, "group")); err != nil {
		return err
	}

	return nil
}

func (im *IdentityManager) ReconcileSlurm(ctx context.Context) error {
	if im.slurmURL == "" {
		return nil
	}

	// 1. Fetch all projects and sync as accounts
	pRows, err := im.db.Query("SELECT project_id, display_name FROM portal_projects;")
	if err != nil {
		return err
	}
	var projects []struct {
		id   string
		name string
	}
	for pRows.Next() {
		var p struct {
			id   string
			name string
		}
		if err := pRows.Scan(&p.id, &p.name); err == nil {
			projects = append(projects, p)
		}
	}
	pRows.Close()

	for _, p := range projects {
		accPayload := map[string]interface{}{
			"accounts": []map[string]interface{}{
				{
					"name":         p.id,
					"description":  p.name,
					"organization": "ai-sandbox",
				},
			},
		}
		im.postSlurmrestd(ctx, "/slurmdb/v0.0.42/accounts", accPayload)
	}

	// 2. Fetch all users and sync
	uRows, err := im.db.Query("SELECT student_id FROM portal_users;")
	if err != nil {
		return err
	}
	var users []string
	for uRows.Next() {
		var u string
		if err := uRows.Scan(&u); err == nil {
			users = append(users, u)
		}
	}
	uRows.Close()

	for _, u := range users {
		userPayload := map[string]interface{}{
			"users": []map[string]interface{}{
				{
					"name": u,
				},
			},
		}
		im.postSlurmrestd(ctx, "/slurmdb/v0.0.42/users", userPayload)
	}

	// 3. Fetch all memberships and sync associations
	mRows, err := im.db.Query("SELECT project_id, student_id FROM portal_memberships;")
	if err != nil {
		return err
	}
	var assocs []map[string]interface{}
	for mRows.Next() {
		var prj, usr string
		if err := mRows.Scan(&prj, &usr); err == nil {
			assocs = append(assocs, map[string]interface{}{
				"account": prj,
				"cluster": im.slurmCluster,
				"user":    usr,
			})
		}
	}
	mRows.Close()

	if len(assocs) > 0 {
		assocPayload := map[string]interface{}{
			"associations": assocs,
		}
		im.postSlurmrestd(ctx, "/slurmdb/v0.0.42/associations", assocPayload)
	}

	return nil
}

func (im *IdentityManager) postSlurmrestd(ctx context.Context, endpoint string, payload interface{}) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	url := fmt.Sprintf("%s%s", strings.TrimRight(im.slurmURL, "/"), endpoint)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	token := im.slurmToken
	// Dynamically sign a fresh Slurm JWT if SLURM_JWT is unset or is a raw key rather than a 3-part JWT.
	if token == "" || strings.Count(token, ".") != 2 {
		if signed, err := makeSlurmToken("root", "root"); err == nil && signed != "" {
			token = signed
		}
	}
	if token != "" {
		req.Header.Set("X-SLURM-USER-TOKEN", token)
		req.Header.Set("X-SLURM-USER-NAME", "root")
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}

var identityHTTPHandlerSecret []byte

type IdentityHTTPHandler struct {
	im        *IdentityManager
	jwtSecret []byte
}

func (h *IdentityHTTPHandler) HandleLogin(c echo.Context) error {
	identityHTTPHandlerSecret = h.jwtSecret
	identityManager = h.im
	return loginAction(c)
}

func (h *IdentityHTTPHandler) HandleListProjects(c echo.Context) error {
	studentID, ok := c.Get("user_student_id").(string)
	if !ok || studentID == "" {
		cookie, err := c.Cookie("session")
		if err == nil && cookie.Value != "" {
			parts := strings.Split(cookie.Value, ":")
			if len(parts) >= 1 {
				studentID = parts[0]
			}
		}
	}

	if studentID == "" {
		return c.JSON(http.StatusUnauthorized, map[string]string{"error": "unauthenticated"})
	}

	projects, err := h.im.ListUserProjects(studentID)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	if projects == nil {
		projects = []ProjectInfo{}
	}

	return c.JSON(http.StatusOK, projects)
}
