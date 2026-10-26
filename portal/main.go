package main

import (
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/golang-jwt/jwt/v5"
	echojwt "github.com/labstack/echo-jwt/v4"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

var (
	// slurmRestURL is the URL of the Slurm REST API.
	slurmRestURL string
	// jwtKeyPath is the file path to the JWT shared secret key.
	jwtKeyPath string
	// tokenLifespan is the duration in seconds for which a JWT is valid.
	tokenLifespan int
	// portManager manages the allocation and release of ports for interactive jobs.
	portManager *PortManager
	// sessionManager manages interactive OCI sessions.
	sessionManager *SessionManager
)

func main() {
	slurmRestURL = getEnv("SLURMRESTD_URL", "http://slurmrestd:6820")
	jwtKeyPath = getEnv("JWT_KEY_PATH", "/etc/slurm/jwt_hs256.key")
	tokenLifespan, _ = strconv.Atoi(getEnv("TOKEN_LIFESPAN", "1800"))

	dbPath := getEnv("PORT_DB_PATH", "/var/lib/portal/leases.db")
	traefikDir := getEnv("TRAEFIK_CONFIG_DIR", "/etc/traefik/dynamic")

	portManager = NewPortManager(dbPath, 30000, 31000, traefikDir)

	sm, err := NewSessionManager("workload", traefikDir)
	if err == nil {
		sessionManager = sm
	} else {
		fmt.Printf("Warning: Failed to initialize session manager: %v\n", err)
	}

	e := echo.New()
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())

	tmplGlob := "templates/*.html"
	if _, err := os.Stat("/mnt/storage/common/templates/index.html"); err == nil {
		tmplGlob = "/mnt/storage/common/templates/*.html"
	}
	e.Renderer = &TemplateRenderer{
		templates: template.Must(template.New("").Funcs(template.FuncMap{
			"upper": strings.ToUpper,
		}).ParseGlob(tmplGlob)),
	}

	e.POST("/api/internal/allocate-port", handleAllocatePort)
	e.POST("/api/internal/release-port", handleReleasePort)
	e.GET("/api/auth/vllm", handleVLLMAuth)
	e.POST("/api/auth/vllm", handleVLLMAuth)

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
	ui.GET("/api/tokens/inference", handleGetInferenceToken)
	ui.POST("/api/tokens/inference", handleGetInferenceToken)
	ui.POST("/jobs/submit", submitJob)
	ui.GET("/jobs/:job_id", jobStatus)
	ui.GET("/jobs/:job_id/log", jobLog)
	ui.DELETE("/jobs/:job_id", cancelJob)

	ui.GET("/api/jobs", apiUserJobs)
	ui.GET("/api/cluster/status", apiClusterStatus)

	// Proxy interactive session requests to the internal Traefik proxy on port 80
	url1, err := url.Parse("http://localhost:80")
	if err != nil {
		e.Logger.Fatal(err)
	}
	proxyTarget := middleware.ProxyTarget{
		URL: url1,
	}
	e.Group("/:user/:app").Use(middleware.Proxy(middleware.NewRoundRobinBalancer([]*middleware.ProxyTarget{&proxyTarget})))

	e.Logger.Fatal(e.Start(":8080"))
}
