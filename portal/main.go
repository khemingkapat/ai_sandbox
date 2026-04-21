package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	echojwt "github.com/labstack/echo-jwt/v4"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

var (
	slurmRestURL  string
	jwtKeyPath    string
	tokenLifespan int
	portManager   *PortManager
)

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

func makeSlurmToken(username string) (string, error) {
	key, err := readSlurmKey()
	if err != nil {
		return "", err
	}

	claims := jwt.MapClaims{
		"sun": username,
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(time.Duration(tokenLifespan) * time.Second).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(key)
}

func main() {
	// Setup Environment Variables
	slurmRestURL = getEnv("SLURMRESTD_URL", "http://slurmrestd:6820")
	jwtKeyPath = getEnv("JWT_KEY_PATH", "/etc/slurm/jwt_hs256.key")
	tokenLifespan, _ = strconv.Atoi(getEnv("TOKEN_LIFESPAN", "1800"))

	dbPath := getEnv("PORT_DB_PATH", "/var/lib/portal/leases.db")
	traefikDir := getEnv("TRAEFIK_CONFIG_DIR", "/etc/traefik/dynamic")

	portManager = NewPortManager(dbPath, 30000, 31000, traefikDir)

	e := echo.New()
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())

	// Templates
	// ADDED: Register the "upper" function here so the HTML templates can use it
	e.Renderer = &TemplateRenderer{
		templates: template.Must(template.New("").Funcs(template.FuncMap{
			"upper": strings.ToUpper,
		}).ParseGlob("templates/*.html")),
	}

	// Internal APIs for Compute Nodes
	e.POST("/api/internal/allocate-port", handleAllocatePort)
	e.POST("/api/internal/release-port", handleReleasePort)

	// Auth Routes
	e.GET("/login", loginPage)
	e.POST("/login", loginAction)
	e.GET("/logout", logoutAction)

	// Protected UI Routes
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

	e.Logger.Fatal(e.Start(":8080"))
}

// --- Route Handlers ---

func loginPage(c echo.Context) error {
	users := []string{"user1", "root"}
	return c.Render(http.StatusOK, "login.html", map[string]interface{}{"users": users})
}

func loginAction(c echo.Context) error {
	username := c.FormValue("username")
	if username != "user1" && username != "root" {
		return c.String(http.StatusBadRequest, "Unknown user")
	}

	token, err := makeSlurmToken(username)
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
	exp := int64(claims["exp"].(float64))
	expiresIn := exp - time.Now().Unix()

	apps := []map[string]string{{
		"id":          "jupyterlab",
		"name":        "JupyterLab",
		"description": "Interactive Python notebook environment",
		"icon":        "⬡",
	}}

	return c.Render(http.StatusOK, "index.html", map[string]interface{}{
		"username":   username,
		"apps":       apps,
		"expires_in": expiresIn,
	})
}

func submitJob(c echo.Context) error {
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	tokenString := userToken.Raw

	home := "/mnt/storage/users/" + username
	if username == "root" {
		home = "/root"
	}

	// This is the EXACT script template you used in Python
	scriptTemplate := fmt.Sprintf(`#!/bin/bash
#SBATCH --job-name=jupyter_server
#SBATCH --output=%s/logs/jupyterlab_%%j.out
#SBATCH --error=%s/logs/jupyterlab_%%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=2G

mkdir -p %s/logs
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

BASE_URL="/%s/jupyter/$SLURM_JOB_ID"

apptainer exec --bind /mnt/storage:/mnt/storage \
    /mnt/storage/public/containers/jupyterlab.sif \
    bash -c "jupyter lab --ip=0.0.0.0 --port=$ALLOCATED_PORT --no-browser --ServerApp.base_url=$BASE_URL --ServerApp.token='' --allow-root"

echo "Releasing port..."
curl -s -X POST http://portal:8080/api/internal/release-port \
    -H "Content-Type: application/json" \
    -d '{"job_id": "'$SLURM_JOB_ID'"}'
`, home, home, home, username, username)

	payload := map[string]interface{}{
		"job": map[string]interface{}{
			"current_working_directory": home,
			"environment": map[string]string{
				"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
				"HOME": home,
				"USER": username,
			},
		},
		"script": scriptTemplate,
	}

	body, _ := json.Marshal(payload)
	req, _ := http.NewRequest("POST", slurmRestURL+"/slurm/v0.0.42/job/submit", bytes.NewBuffer(body))
	req.Header.Set("X-SLURM-USER-TOKEN", tokenString)
	req.Header.Set("X-SLURM-USER-NAME", username)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != 200 {
		return c.String(http.StatusInternalServerError, "Slurm API Error")
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&result)

	return c.JSON(http.StatusOK, map[string]interface{}{"job_id": result["job_id"]})
}

func jobStatus(c echo.Context) error {
	jobID := c.Param("job_id")
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	tokenString := userToken.Raw

	req, _ := http.NewRequest("GET", slurmRestURL+"/slurm/v0.0.42/job/"+jobID, nil)
	req.Header.Set("X-SLURM-USER-TOKEN", tokenString)
	req.Header.Set("X-SLURM-USER-NAME", username)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return c.String(http.StatusInternalServerError, "Slurm API Error")
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return c.String(http.StatusInternalServerError, "Invalid JSON")
	}

	jobsInterface, ok := result["jobs"]
	if !ok {
		return c.String(http.StatusNotFound, "Job not found")
	}

	jobs, ok := jobsInterface.([]interface{})
	if !ok || len(jobs) == 0 {
		return c.String(http.StatusNotFound, "Job not found")
	}

	jobData, ok := jobs[0].(map[string]interface{})
	if !ok {
		return c.String(http.StatusInternalServerError, "Invalid job format")
	}

	// ---> BULLETPROOF STATE PARSING <---
	// Safely checks if Slurm returned a string or a list of strings
	var stateStr string
	switch v := jobData["job_state"].(type) {
	case string:
		stateStr = v
	case []interface{}:
		if len(v) > 0 {
			stateStr = fmt.Sprintf("%v", v[0])
		} else {
			stateStr = "UNKNOWN"
		}
	default:
		stateStr = "UNKNOWN"
	}

	var proxyURL *string
	if stateStr == "RUNNING" {
		jID, err := strconv.Atoi(jobID)
		if err == nil {
			lease, _ := portManager.GetLeaseByJob(jID)
			// Wait until the compute node has fully run "curl allocate-port" and saved to SQLite
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

func jobLog(c echo.Context) error {
	jobID := c.Param("job_id")
	userToken := c.Get("user").(*jwt.Token)
	username := userToken.Claims.(jwt.MapClaims)["sun"].(string)

	logPath := fmt.Sprintf("/mnt/storage/users/%s/logs/jupyterlab_%s.out", username, jobID)
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
