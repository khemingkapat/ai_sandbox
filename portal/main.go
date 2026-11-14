package main

import (
	"context"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	echojwt "github.com/labstack/echo-jwt/v4"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	echoSwagger "github.com/swaggo/echo-swagger"

	_ "portal/docs"
)

// @title AI Sandbox Portal API
// @version 1.0
// @description AI Sandbox student workloads and cluster telemetry API.
// @securityDefinitions.apikey BearerAuth
// @in header
// @name Authorization

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
	// telemetryScraper manages telemetry cache and background probes.
	telemetryScraper *TelemetryScraper
	// identityManager manages dynamic identity, project allocation and extrausers sync.
	identityManager *IdentityManager
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

	telemetryTTL, _ := strconv.Atoi(getEnv("TELEMETRY_CACHE_TTL_SEC", "30"))
	telemetryToken := getEnv("TELEMETRY_TOKEN", "")
	telemetryScraper = NewTelemetryScraper(time.Duration(telemetryTTL)*time.Second, telemetryToken)

	// Initialize IdentityManager backed by Postgres 16 (or local fallback)
	dbDriver := getEnv("IDENTITY_DB_DRIVER", "")
	dbURL := getEnv("DATABASE_URL", "")
	extrausersDir := getEnv("EXTRAUSERS_DIR", "/mnt/storage/common/etc")
	projectsDir := getEnv("PROJECTS_DIR", "/mnt/storage/projects")

	if dbURL != "" {
		if strings.HasPrefix(dbURL, "postgres://") || strings.HasPrefix(dbURL, "postgresql://") {
			dbDriver = "postgres"
		}
	} else {
		dbDriver = "sqlite3"
		dbURL = "/var/lib/portal/identity.db"
	}

	// Retry connecting to DB on boot (e.g. CNI netpol sync latency)
	var im *IdentityManager
	for attempts := 1; attempts <= 10; attempts++ {
		im, err = NewIdentityManager(dbDriver, dbURL, extrausersDir, projectsDir, slurmRestURL)
		if err == nil {
			break
		}
		fmt.Printf("Attempt %d: failed to initialize IdentityManager: %v (retrying in 2s)\n", attempts, err)
		time.Sleep(2 * time.Second)
	}

	if err != nil {
		fmt.Printf("Warning: failed to initialize IdentityManager after retries: %v\n", err)
	} else {
		identityManager = im
		// Initial compile to ensure extrausers exists
		_ = identityManager.CompileExtrausers()
		// Start background reconciler ticker (every 60s)
		go func() {
			ticker := time.NewTicker(60 * time.Second)
			for range ticker.C {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				_ = identityManager.ReconcileSlurm(ctx)
				cancel()
			}
		}()
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

	e.GET("/healthz", handleHealthz)
	e.GET("/api/v1/telemetry", telemetryScraper.HandleTelemetry)
	e.GET("/api/v1/telemetry/incidents", telemetryScraper.HandleTelemetryIncidents)
	e.GET("/swagger/*", echoSwagger.WrapHandler)

	e.POST("/api/internal/allocate-port", handleAllocatePort)
	e.POST("/api/internal/release-port", handleReleasePort)
	e.POST("/api/internal/webhook/slurm", telemetryScraper.HandleSlurmWebhook)
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
	ui.GET("/api/projects", handleListProjectsUI)
	ui.POST("/api/projects", handleCreateProjectUI)
	ui.POST("/api/projects/:id/members", handleInviteMemberUI)
	ui.POST("/api/projects/switch", handleSwitchProjectUI)
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
