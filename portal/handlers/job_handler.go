package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"portal/models"
	"portal/ports"
	"portal/services"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"
)

// JobHandler handles job submission, status polling, log streaming, and cancellation.
type JobHandler struct {
	Slurm       *services.SlurmService
	PortManager *ports.PortManager
}

// Submit builds a job script from the app manifest and submits it via the Slurm REST API.
func (h *JobHandler) Submit(c echo.Context) error {
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	project := claims["prj"].(string)
	tokenString := userToken.Raw
	hasQueue, checkErr := h.Slurm.CheckPendingQueue(c.Request().Context(), username, tokenString)
    
    	// fmt.Println("==========================================")
    	// fmt.Printf("DEBUG [QueueCheck]: User: %s | Has Pending: %v | Error: %v\n", username, hasQueue, checkErr)
    	// fmt.Println("==========================================")

	appID := c.FormValue("app_id")

	apps := services.ScanApps(project)
	targetApp := findApp(apps, appID)
	if targetApp == nil {
		return c.String(http.StatusBadRequest, "Application not found")
	}

	workspace := workspacePath(username, project)
	finalSlurmArgs := mergeSlurmArgs(targetApp.SlurmArgs, formSlurmArgs(c))
	script := buildScript(username, workspace, targetApp, finalSlurmArgs)
	payload := buildPayload(username, workspace, targetApp, finalSlurmArgs, script)

	resp, err := h.Slurm.Do(context.Background(), http.MethodPost, "/slurm/v0.0.42/job/submit", username, tokenString, payload)
	if err != nil || resp.StatusCode != http.StatusOK {
		return c.String(http.StatusInternalServerError, "Slurm API error")
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&result)


	return c.JSON(http.StatusOK, map[string]interface{}{"job_id": result["job_id"]})
}

// Status polls a job's state and returns a proxy URL if the job is running.
func (h *JobHandler) Status(c echo.Context) error {
	jobID := c.Param("job_id")
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	tokenString := userToken.Raw

	resp, err := h.Slurm.Do(context.Background(), http.MethodGet, "/slurm/v0.0.42/job/"+jobID, username, tokenString, nil)
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm API error")
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return c.String(http.StatusInternalServerError, "Invalid JSON")
	}

	jobs, ok := result["jobs"].([]interface{})
	if !ok || len(jobs) == 0 {
		return c.String(http.StatusNotFound, "Job not found")
	}
	jobData, ok := jobs[0].(map[string]interface{})
	if !ok {
		return c.String(http.StatusInternalServerError, "Invalid job format")
	}

	stateStr := extractJobState(jobData)

	var proxyURL *string
	if stateStr == "RUNNING" {
		jID, err := strconv.Atoi(jobID)
		if err == nil {
			lease, _ := h.PortManager.GetLeaseByJob(jID)
			if lease != nil {
				url := fmt.Sprintf("http://localhost:8000/%s/jupyter/%d", lease.Username, lease.JobID)
				proxyURL = &url
			}
		}
	}

	return c.JSON(http.StatusOK, map[string]interface{}{
		"job_id":    jobID,
		"state":     stateStr,
		"proxy_url": proxyURL,
	})
}

// Log reads the job's stdout log file from shared storage.
func (h *JobHandler) Log(c echo.Context) error {
	jobID := c.Param("job_id")
	appID := c.QueryParam("app_id")
	if appID == "" {
		appID = "jupyterlab"
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

// Cancel sends a DELETE request to the Slurm API to terminate a job.
func (h *JobHandler) Cancel(c echo.Context) error {
	jobID := c.Param("job_id")
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	tokenString := userToken.Raw

	resp, err := h.Slurm.Do(context.Background(), http.MethodDelete, "/slurm/v0.0.42/job/"+jobID, username, tokenString, nil)
	if err != nil || resp.StatusCode >= 400 {
		return c.String(http.StatusInternalServerError, "Failed to cancel job")
	}
	defer resp.Body.Close()
	return c.JSON(http.StatusOK, map[string]string{"status": "cancelled"})
}

// --- Internal port allocation endpoints (called by the worker node job script) ---

// AllocatePort reserves a proxy port for a running job.
func (h *JobHandler) AllocatePort(c echo.Context) error {
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
	port, _ := h.PortManager.AllocatePort(jID, req.Username, req.NodeHostname, req.NodeIP)
	return c.JSON(http.StatusOK, map[string]int{"port": port})
}

// ReleasePort frees the port associated with a completed job.
func (h *JobHandler) ReleasePort(c echo.Context) error {
	var req struct {
		JobID string `json:"job_id"`
	}
	c.Bind(&req)
	jID, _ := strconv.Atoi(req.JobID)
	h.PortManager.ReleasePort(jID)
	return c.JSON(http.StatusOK, map[string]string{"status": "released"})
}

// --- helpers ---

func findApp(apps []models.AppManifest, id string) *models.AppManifest {
	for i := range apps {
		if apps[i].ID == id {
			return &apps[i]
		}
	}
	return nil
}

func workspacePath(username, project string) string {
	if username == "root" {
		return "/root"
	}
	return "/mnt/storage/projects/" + project
}

// formSlurmArgs extracts slurm_* form fields submitted alongside the job.
func formSlurmArgs(c echo.Context) map[string]string {
	args := make(map[string]string)
	params, _ := c.FormParams()
	for key, values := range params {
		if strings.HasPrefix(key, "slurm_") && len(values) > 0 && values[0] != "" {
			args[strings.TrimPrefix(key, "slurm_")] = values[0]
		}
	}
	return args
}

// mergeSlurmArgs overlays form overrides on top of manifest defaults.
func mergeSlurmArgs(defaults, overrides map[string]string) map[string]string {
	merged := make(map[string]string, len(defaults))
	for k, v := range defaults {
		merged[k] = v
	}
	for k, v := range overrides {
		merged[k] = v
	}
	return merged
}

func buildScript(username, workspace string, app *models.AppManifest, slurmArgs map[string]string) string {
	var sb strings.Builder

	// #SBATCH header
	sb.WriteString("#!/bin/bash\n")
	sb.WriteString(fmt.Sprintf("#SBATCH --job-name=%s\n", app.ID))
	sb.WriteString(fmt.Sprintf("#SBATCH --output=%s/logs/%s_%%j.out\n", workspace, app.ID))
	sb.WriteString(fmt.Sprintf("#SBATCH --error=%s/logs/%s_%%j.err\n", workspace, app.ID))
	for k, v := range slurmArgs {
		sb.WriteString(fmt.Sprintf("#SBATCH --%s=%s\n", k, v))
	}
	sb.WriteString("\n")

	// Bash body
	sb.WriteString(fmt.Sprintf("mkdir -p %s/logs\n", workspace))
	sb.WriteString(fmt.Sprintf("export WORKSPACE=%q\n", workspace))

	needsPort := strings.Contains(app.ExecCommand, "$ALLOCATED_PORT")
	if needsPort {
		sb.WriteString(portAllocationBlock(username))
	}

	if app.ImageFile != "" {
		sb.WriteString(fmt.Sprintf(
			"\napptainer exec --bind %s:%s \\\n    --bind /mnt/storage/common:/mnt/storage/common:ro \\\n    %s/%s \\\n    bash -c %q\n",
			workspace, workspace, app.SourcePath, app.ImageFile, app.ExecCommand,
		))
	} else {
		sb.WriteString(fmt.Sprintf("\nbash -c %q\n", app.ExecCommand))
	}

	if needsPort {
		sb.WriteString(portReleaseBlock())
	}

	return sb.String()
}

func portAllocationBlock(username string) string {
	return fmt.Sprintf(`
NODE_IP=$(hostname -I | awk '{print $1}')
NODE_HOSTNAME=$(hostname)

echo "Requesting port from Portal..."
RESPONSE=$(curl -s -X POST http://portal:8080/api/internal/allocate-port \
    -H "Content-Type: application/json" \
    -d '{"job_id": "'$SLURM_JOB_ID'", "username": "%s", "node_hostname": "'$NODE_HOSTNAME'", "node_ip": "'$NODE_IP'"}')

ALLOCATED_PORT=$(python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('port', ''))" <<< "$RESPONSE")

if [ -z "$ALLOCATED_PORT" ]; then
    echo "ERROR: Failed to allocate port. $RESPONSE"
    exit 1
fi

echo "Allocated port: $ALLOCATED_PORT"
export ALLOCATED_PORT=$ALLOCATED_PORT
export BASE_URL="/%s/jupyter/$SLURM_JOB_ID"
`, username, username)
}

func portReleaseBlock() string {
	return `
echo "Releasing port..."
curl -s -X POST http://portal:8080/api/internal/release-port \
    -H "Content-Type: application/json" \
    -d '{"job_id": "'$SLURM_JOB_ID'"}'
`
}

func buildPayload(username, workspace string, app *models.AppManifest, slurmArgs map[string]string, script string) map[string]interface{} {
	props := map[string]interface{}{
		"current_working_directory": workspace,
		"environment": map[string]string{
			"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
			"HOME": workspace,
			"USER": username,
		},
		"name":            app.ID,
		"standard_output": fmt.Sprintf("%s/logs/%s_%%j.out", workspace, app.ID),
		"standard_error":  fmt.Sprintf("%s/logs/%s_%%j.err", workspace, app.ID),
	}
	if v, ok := slurmArgs["ntasks"]; ok {
		if n, err := strconv.Atoi(v); err == nil {
			props["tasks"] = n
		}
	}
	if v, ok := slurmArgs["nodes"]; ok {
		if n, err := strconv.Atoi(v); err == nil {
			props["minimum_nodes"] = n
		}
	}
	if v, ok := slurmArgs["cpus-per-task"]; ok {
		if n, err := strconv.Atoi(v); err == nil {
			props["cpus_per_task"] = n
		}
	}
	return map[string]interface{}{"job": props, "script": script}
}

func extractJobState(jobData map[string]interface{}) string {
	switch v := jobData["job_state"].(type) {
	case string:
		return v
	case []interface{}:
		if len(v) > 0 {
			return fmt.Sprintf("%v", v[0])
		}
	}
	return "UNKNOWN"
}
