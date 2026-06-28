package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	api "github.com/SlinkyProject/slurm-client/api/v0042"
	"github.com/SlinkyProject/slurm-client/pkg/client"
	"github.com/SlinkyProject/slurm-client/pkg/types"
	"github.com/golang-jwt/jwt/v5"
	echojwt "github.com/labstack/echo-jwt/v4"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"gopkg.in/yaml.v3"
	"k8s.io/utils/ptr"
)

var (
	slurmRestURL  string
	jwtKeyPath    string
	tokenLifespan int
	portManager   *PortManager
)


// AppManifest represents an application configuration loaded from a yaml file
type AppManifest struct {
	ID          string            `yaml:"id"`
	Name        string            `yaml:"name"`
	Description string            `yaml:"description"`
	Icon        string            `yaml:"icon"`
	Type        string            `yaml:"type"`       // "interactive" or "batch"
	Image       string            `yaml:"image"`      // OCI image ref (e.g., "localhost:5000/sandbox/jupyterlab:latest")
	ImageFile   string            `yaml:"image_file"` // Apptainer SIF file (e.g., "python.sif")
	ExecCommand string            `yaml:"exec_command"`
	SourcePath  string            `yaml:"-"` // We fill this manually
	SlurmArgs   map[string]string `yaml:"slurm_args"`
}

// scanApps finds all manifest.yaml files in common storage and the user's project storage
func scanApps(project string) []AppManifest {
	var apps []AppManifest

	searchPaths := []string{
		"/mnt/storage/common/software/*/manifest.yaml",
		fmt.Sprintf("/mnt/storage/projects/%s/software/*/manifest.yaml", project),
	}

	for _, searchPath := range searchPaths {
		files, _ := filepath.Glob(searchPath)
		for _, file := range files {
			data, err := os.ReadFile(file)
			if err == nil {
				var app AppManifest
				if err := yaml.Unmarshal(data, &app); err == nil {
					// Validation logic
					if app.Type == "" {
						app.Type = "batch"
					}

					if app.Type != "interactive" && app.Type != "batch" {
						fmt.Printf("Warning: manifest %s has invalid type %s, skipping\n", file, app.Type)
						continue
					}

					if app.Type == "interactive" && app.Image == "" {
						fmt.Printf("Warning: interactive manifest %s is missing image field, skipping\n", file)
						continue
					}

					app.SourcePath = filepath.Dir(file)
					// Initialize map if missing
					if app.SlurmArgs == nil {
						app.SlurmArgs = make(map[string]string)
					}
					apps = append(apps, app)
				}
			}
		}
	}
	return apps
}

// Template renderer for Echo
type TemplateRenderer struct {
	templates *template.Template
}

func (t *TemplateRenderer) Render(w io.Writer, name string, data interface{}, c echo.Context) error {
	return t.templates.ExecuteTemplate(w, name, data)
}

func readSlurmKey() ([]byte, error) {
	return os.ReadFile(jwtKeyPath)
}

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

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
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

func main() {
	slurmRestURL = getEnv("SLURMRESTD_URL", "http://slurmrestd:6820")
	jwtKeyPath = getEnv("JWT_KEY_PATH", "/etc/slurm/jwt_hs256.key")
	tokenLifespan, _ = strconv.Atoi(getEnv("TOKEN_LIFESPAN", "1800"))

	dbPath := getEnv("PORT_DB_PATH", "/var/lib/portal/leases.db")
	traefikDir := getEnv("TRAEFIK_CONFIG_DIR", "/etc/traefik/dynamic")

	portManager = NewPortManager(dbPath, 30000, 31000, traefikDir)

	e := echo.New()
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())

	e.Renderer = &TemplateRenderer{
		templates: template.Must(template.New("").Funcs(template.FuncMap{
			"upper": strings.ToUpper,
		}).ParseGlob("templates/*.html")),
	}

	e.POST("/api/internal/allocate-port", handleAllocatePort)
	e.POST("/api/internal/release-port", handleReleasePort)

	e.GET("/login", loginPage)
	e.POST("/login", loginAction)
	e.GET("/logout", logoutAction)

	ui := e.Group("")
	ui.Use(echojwt.WithConfig(echojwt.Config{
		TokenLookup: "cookie:session",
		KeyFunc: func(token *jwt.Token) (interface{}, error) {
			return readSlurmKey()
		},
		ErrorHandler: func(c echo.Context, err error) error {
			return c.Redirect(http.StatusFound, "/login")
		},
	}))

	ui.GET("/", indexPage)
	ui.POST("/jobs/submit", submitJob)
	ui.GET("/jobs/:job_id", jobStatus)
	ui.GET("/jobs/:job_id/log", jobLog)
	ui.DELETE("/jobs/:job_id", cancelJob)

	ui.GET("/api/jobs", apiUserJobs)
	ui.GET("/api/cluster/status", apiClusterStatus)

	e.Logger.Fatal(e.Start(":8080"))
}

func loginPage(c echo.Context) error {
	accessMatrix := fetchAccessMatrix()
	matrixJSON, _ := json.Marshal(accessMatrix)
	return c.Render(http.StatusOK, "login.html", map[string]interface{}{
		"accessJSON": string(matrixJSON),
	})
}

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

func loginAction(c echo.Context) error {
	username := c.FormValue("username")
	project := c.FormValue("project")

	accessMatrix := fetchAccessMatrix()
	validProject := false
	for _, p := range accessMatrix[username] {
		if p == project {
			validProject = true
			break
		}
	}
	if !validProject {
		return c.String(http.StatusForbidden, "User does not have access to this project")
	}

	if err := registerUserExtrausers(username, project); err != nil {
		fmt.Printf("Error registering extrauser: %v\n", err)
	}

	token, err := makeSlurmToken(username, project)
	if err != nil {
		return c.String(http.StatusInternalServerError, "Key error")
	}

	c.SetCookie(&http.Cookie{
		Name:     "session",
		Value:    token,
		HttpOnly: true,
		MaxAge:   tokenLifespan,
	})
	return c.Redirect(http.StatusSeeOther, "/")
}

func logoutAction(c echo.Context) error {
	c.SetCookie(&http.Cookie{Name: "session", MaxAge: -1})
	return c.Redirect(http.StatusSeeOther, "/login")
}

func indexPage(c echo.Context) error {
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	project := claims["prj"].(string)
	exp := int64(claims["exp"].(float64))
	expiresIn := exp - time.Now().Unix()

	// Dynamically scan for apps
	apps := scanApps(project)

	return c.Render(http.StatusOK, "index.html", map[string]interface{}{
		"username":   username,
		"project":    project,
		"apps":       apps,
		"expires_in": expiresIn,
	})
}

func apiUserJobs(c echo.Context) error {
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	tokenString := userToken.Raw

	slurmClient, err := client.NewClient(&client.Config{Server: slurmRestURL, AuthToken: tokenString})
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm Client Error")
	}

	jobList := &types.V0042JobInfoList{}
	if err := slurmClient.List(context.Background(), jobList); err != nil {
		return c.String(http.StatusInternalServerError, "Slurm API Error")
	}

	userJobs := []types.V0042JobInfo{}
	for _, job := range jobList.Items {
		if ptr.Deref(job.UserName, "") == username {
			userJobs = append(userJobs, job)
		}
	}

	return c.JSON(http.StatusOK, userJobs)
}

func apiClusterStatus(c echo.Context) error {
	userToken := c.Get("user").(*jwt.Token)
	tokenString := userToken.Raw

	slurmClient, err := client.NewClient(&client.Config{Server: slurmRestURL, AuthToken: tokenString})
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm Client Error")
	}

	// 1. Fetch Jobs for Active & Queue Depth
	activeJobs := 0
	queueDepth := 0
	jobList := &types.V0042JobInfoList{}
	if err := slurmClient.List(context.Background(), jobList); err == nil {
		for _, j := range jobList.Items {
			stateSet := j.GetStateAsSet()
			if stateSet.Has(api.V0042JobInfoJobStateRUNNING) {
				activeJobs++
			} else if stateSet.Has(api.V0042JobInfoJobStatePENDING) {
				queueDepth++
			}
		}
	}

	// 2. Fetch Nodes for Resource counts
	nodesTotal := 0
	nodesFree := 0
	nodeList := &types.V0042NodeList{}
	if err := slurmClient.List(context.Background(), nodeList); err == nil {
		nodesTotal = len(nodeList.Items)
		for _, n := range nodeList.Items {
			stateSet := n.GetStateAsSet()
			if stateSet.Has(api.V0042NodeStateIDLE) {
				nodesFree++
			}
		}
	}

	return c.JSON(http.StatusOK, map[string]interface{}{
		"active_jobs":     activeJobs,
		"cpu_nodes_total": nodesTotal,
		"cpu_nodes_free":  nodesFree,
		"queue_depth":     queueDepth,
	})
}

func submitJob(c echo.Context) error {
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	project := claims["prj"].(string)
	tokenString := userToken.Raw

	appID := c.FormValue("app_id")

	// Find the targeted AppManifest
	apps := scanApps(project)
	var targetApp *AppManifest
	for _, app := range apps {
		if app.ID == appID {
			targetApp = &app
			break
		}
	}

	if targetApp == nil {
		return c.String(http.StatusBadRequest, "Application not found")
	}

	workspace := "/mnt/storage/projects/" + project
	if username == "root" {
		workspace = "/root"
	}

	// 1. Prepare Slurm arguments (Override defaults with Form data)
	finalSlurmArgs := make(map[string]string)
	for k, v := range targetApp.SlurmArgs {
		finalSlurmArgs[k] = v // copy defaults
	}

	formParams, _ := c.FormParams()
	for key, values := range formParams {
		if strings.HasPrefix(key, "slurm_") && len(values) > 0 && values[0] != "" {
			argName := strings.TrimPrefix(key, "slurm_")
			finalSlurmArgs[argName] = values[0]
		}
	}

	// 2. Build the #SBATCH header block
	sbatchHeader := "#!/bin/bash\n"
	sbatchHeader += fmt.Sprintf("#SBATCH --job-name=%s\n", targetApp.ID)
	sbatchHeader += fmt.Sprintf("#SBATCH --output=%s/logs/%s_%%j.out\n", workspace, targetApp.ID)
	sbatchHeader += fmt.Sprintf("#SBATCH --error=%s/logs/%s_%%j.err\n", workspace, targetApp.ID)

	for key, value := range finalSlurmArgs {
		sbatchHeader += fmt.Sprintf("#SBATCH --%s=%s\n", key, value)
	}

	// 3. Build the bash logic dynamically
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("mkdir -p %s/logs\n", workspace))
	sb.WriteString(fmt.Sprintf("export WORKSPACE=\"%s\"\n", workspace))

	needsPort := strings.Contains(targetApp.ExecCommand, "$ALLOCATED_PORT")
	
	// Conditionally allocate port only if the app needs it
	if needsPort {
		sb.WriteString(fmt.Sprintf(`
NODE_IP=$(hostname -I | awk '{print $1}')
NODE_HOSTNAME=$(hostname)

echo "Requesting port from Portal..."
RESPONSE=$(curl -s -X POST http://portal:8080/api/internal/allocate-port \
    -H "Content-Type: application/json" \
    -d '{"job_id": "'$SLURM_JOB_ID'", "username": "%[1]s", "node_hostname": "'$NODE_HOSTNAME'", "node_ip": "'$NODE_IP'"}')

ALLOCATED_PORT=$(python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('port', ''))" <<< "$RESPONSE")

if [ -z "$ALLOCATED_PORT" ]; then
    echo "ERROR: Failed to allocate port. $RESPONSE"
    exit 1
fi

echo "Allocated port: $ALLOCATED_PORT"
export ALLOCATED_PORT=$ALLOCATED_PORT
export BASE_URL="/%[1]s/jupyter/$SLURM_JOB_ID"
`, username))
	}

	// Conditionally run in Apptainer or directly on the host
	if targetApp.ImageFile != "" {
		sb.WriteString(fmt.Sprintf(`
apptainer exec --bind %[1]s:%[1]s \
    --bind /mnt/storage/common:/mnt/storage/common:ro \
    %[2]s/%[3]s \
    bash -c "%[4]s"
`, workspace, targetApp.SourcePath, targetApp.ImageFile, targetApp.ExecCommand))
	} else {
		sb.WriteString(fmt.Sprintf(`
bash -c "%s"
`, targetApp.ExecCommand))
	}

	// Conditionally release the port
	if needsPort {
		sb.WriteString(`
echo "Releasing port..."
curl -s -X POST http://portal:8080/api/internal/release-port \
    -H "Content-Type: application/json" \
    -d '{"job_id": "'$SLURM_JOB_ID'"}'
`)
	}

	scriptTemplate := sbatchHeader + "\n" + sb.String()

	jobDesc := &api.V0042JobDescMsg{
		CurrentWorkingDirectory: ptr.To(workspace),
		Environment: &api.V0042StringArray{
			"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
			"HOME=" + workspace,
			"USER=" + username,
		},
		Name: ptr.To(targetApp.ID),
		StandardOutput: ptr.To(fmt.Sprintf("%s/logs/%s_%%j.out", workspace, targetApp.ID)),
		StandardError:  ptr.To(fmt.Sprintf("%s/logs/%s_%%j.err", workspace, targetApp.ID)),
	}

	// Map common Slurm arguments directly to the REST API fields
	if val, ok := finalSlurmArgs["ntasks"]; ok {
		if v, err := strconv.Atoi(val); err == nil {
			jobDesc.Tasks = ptr.To(int32(v))
		}
	}
	if val, ok := finalSlurmArgs["nodes"]; ok {
		if v, err := strconv.Atoi(val); err == nil {
			jobDesc.MinimumNodes = ptr.To(int32(v))
		}
	}
	if val, ok := finalSlurmArgs["cpus-per-task"]; ok {
		if v, err := strconv.Atoi(val); err == nil {
			jobDesc.CpusPerTask = ptr.To(int32(v))
		}
	}
	if val, ok := finalSlurmArgs["partition"]; ok {
		jobDesc.Partition = ptr.To(val)
	}

	submitReq := api.V0042JobSubmitReq{
		Job:    jobDesc,
		Script: ptr.To(scriptTemplate),
	}

	slurmClient, err := client.NewClient(&client.Config{Server: slurmRestURL, AuthToken: tokenString})
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm Client Error")
	}

	job := &types.V0042JobInfo{}
	err = slurmClient.Create(context.Background(), job, submitReq)
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm API Error: "+err.Error())
	}

	return c.JSON(http.StatusOK, map[string]interface{}{"job_id": ptr.Deref(job.JobId, 0)})
}

func jobStatus(c echo.Context) error {
	jobIDStr := c.Param("job_id")
	userToken := c.Get("user").(*jwt.Token)
	tokenString := userToken.Raw

	slurmClient, err := client.NewClient(&client.Config{Server: slurmRestURL, AuthToken: tokenString})
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm Client Error")
	}

	job := &types.V0042JobInfo{}
	err = slurmClient.Get(context.Background(), client.ObjectKey(jobIDStr), job)
	if err != nil {
		return c.String(http.StatusNotFound, "Job not found")
	}

	stateSet := job.GetStateAsSet()
	stateStr := "UNKNOWN"
	if len(ptr.Deref(job.JobState, []api.V0042JobInfoJobState{})) > 0 {
		stateStr = string((*job.JobState)[0])
	}

	var proxyURL *string
	if stateSet.Has(api.V0042JobInfoJobStateRUNNING) {
		jID, err := strconv.Atoi(jobIDStr)
		if err == nil {
			lease, _ := portManager.GetLeaseByJob(jID)
			if lease != nil {
				url := fmt.Sprintf("http://localhost:8000/%s/jupyter/%d", lease.Username, lease.JobID)
				proxyURL = &url
			}
		}
	}

	return c.JSON(http.StatusOK, map[string]interface{}{
		"job_id":    jobIDStr,
		"state":     stateStr,
		"proxy_url": proxyURL,
	})
}

func jobLog(c echo.Context) error {
	jobID := c.Param("job_id")
	appID := c.QueryParam("app_id") // Pass app id to locate the log file
	if appID == "" {
		appID = "jupyterlab" // fallback
	}

	userToken := c.Get("user").(*jwt.Token)
	project := userToken.Claims.(jwt.MapClaims)["prj"].(string)

	logPath := fmt.Sprintf("/mnt/storage/projects/%s/logs/%s_%s.out", project, appID, jobID)
	content, err := os.ReadFile(logPath)
	if err != nil {
		return c.JSON(http.StatusOK, map[string]interface{}{"log": "Log not yet available."})
	}
	return c.JSON(http.StatusOK, map[string]interface{}{"log": string(content)})
}

// --- Node Internal APIs ---

func handleAllocatePort(c echo.Context) error {
	var req struct {
		JobID        string `json:"job_id"`
		Username     string `json:"username"`
		NodeHostname string `json:"node_hostname"`
		NodeIP       string `json:"node_ip"`
	}
	if err := c.Bind(&req); err != nil {
		return err
	}
	jID, _ := strconv.Atoi(req.JobID)
	port, _ := portManager.AllocatePort(jID, req.Username, req.NodeHostname, req.NodeIP)
	return c.JSON(http.StatusOK, map[string]int{"port": port})
}

func handleReleasePort(c echo.Context) error {
	var req struct {
		JobID string `json:"job_id"`
	}
	c.Bind(&req)
	jID, _ := strconv.Atoi(req.JobID)
	portManager.ReleasePort(jID)
	return c.JSON(http.StatusOK, map[string]string{"status": "released"})
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}

func cancelJob(c echo.Context) error {
	jobIDStr := c.Param("job_id")
	userToken := c.Get("user").(*jwt.Token)
	tokenString := userToken.Raw

	slurmClient, err := client.NewClient(&client.Config{Server: slurmRestURL, AuthToken: tokenString})
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm Client Error")
	}

	jobID, _ := strconv.Atoi(jobIDStr)
	job := &types.V0042JobInfo{
		V0042JobInfo: api.V0042JobInfo{
			JobId: ptr.To(int32(jobID)),
		},
	}
	err = slurmClient.Delete(context.Background(), job)
	if err != nil {
		return c.String(http.StatusInternalServerError, "Failed to cancel job: "+err.Error())
	}

	return c.JSON(http.StatusOK, map[string]string{"status": "cancelled"})
}
