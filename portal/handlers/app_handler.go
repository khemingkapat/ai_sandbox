package handlers

import (
	"net/http"
	"time"

	"portal/services"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"
)

// AppHandler serves the main index page with the application catalogue.
type AppHandler struct {
	Slurm *services.SlurmService
}

// Index renders the dashboard with the list of available applications.
func (h *AppHandler) Index(c echo.Context) error {
	userToken := c.Get("user").(*jwt.Token)
	claims := userToken.Claims.(jwt.MapClaims)
	username := claims["sun"].(string)
	project := claims["prj"].(string)
	exp := int64(claims["exp"].(float64))
	expiresIn := exp - time.Now().Unix()

	apps := services.ScanApps(project)

	return c.Render(http.StatusOK, "index.html", map[string]interface{}{
		"username":   username,
		"project":    project,
		"apps":       apps,
		"expires_in": expiresIn,
	})
}
