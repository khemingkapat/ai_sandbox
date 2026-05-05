package main

import (
	"html/template"
	"io"
	"os"
	"strconv"
	"strings"

	"portal/handlers"
	portalmw "portal/middleware"
	"portal/ports"
	"portal/services"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

// TemplateRenderer adapts Go's html/template to Echo's Renderer interface.
type TemplateRenderer struct {
	templates *template.Template
}

func (t *TemplateRenderer) Render(w io.Writer, name string, data interface{}, c echo.Context) error {
	return t.templates.ExecuteTemplate(w, name, data)
}

func main() {
	// --- Configuration ---
	slurmURL := getEnv("SLURMRESTD_URL", "http://slurmrestd:6820")
	jwtKeyPath := getEnv("JWT_KEY_PATH", "/etc/slurm/jwt_hs256.key")
	tokenLifespan, _ := strconv.Atoi(getEnv("TOKEN_LIFESPAN", "1800"))
	dbPath := getEnv("PORT_DB_PATH", "/var/lib/portal/leases.db")
	traefikDir := getEnv("TRAEFIK_CONFIG_DIR", "/etc/traefik/dynamic")

	// --- Dependencies ---
	slurm := services.NewSlurmService(slurmURL, jwtKeyPath, tokenLifespan)
	pm := ports.NewPortManager(dbPath, 30000, 31000, traefikDir)

	authH := &handlers.AuthHandler{Slurm: slurm}
	appH := &handlers.AppHandler{Slurm: slurm}
	jobH := &handlers.JobHandler{Slurm: slurm, PortManager: pm}

	// --- Echo setup ---
	e := echo.New()
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())

	e.Renderer = &TemplateRenderer{
		templates: template.Must(template.New("").Funcs(template.FuncMap{
			"upper": strings.ToUpper,
		}).ParseGlob("templates/*.html")),
	}

	// --- Public routes ---
	e.GET("/login", authH.LoginPage)
	e.POST("/login", authH.LoginAction)
	e.GET("/logout", authH.Logout)

	// Internal node callbacks — no JWT required, network-level access control assumed
	e.POST("/api/internal/allocate-port", jobH.AllocatePort)
	e.POST("/api/internal/release-port", jobH.ReleasePort)

	// --- Authenticated routes ---
	ui := e.Group("")
	ui.Use(portalmw.JWTMiddleware(slurm))

	ui.GET("/", appH.Index)
	ui.POST("/jobs/submit", jobH.Submit)
	ui.GET("/jobs/:job_id", jobH.Status)
	ui.GET("/jobs/:job_id/log", jobH.Log)
	ui.DELETE("/jobs/:job_id", jobH.Cancel)

	e.Logger.Fatal(e.Start(":8080"))
}

func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}
