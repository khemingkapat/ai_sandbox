package main

import (
	"fmt"
	"html/template"
	"net/http"
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

	sm, err := NewSessionManager("slurm")
	if err == nil {
		sessionManager = sm
	} else {
		fmt.Printf("Warning: failed to initialize session manager: %v\n", err)
	}

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
