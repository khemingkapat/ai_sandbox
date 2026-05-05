package handlers

import (
	"encoding/json"
	"net/http"

	"portal/services"

	"github.com/labstack/echo/v4"
)

// AuthHandler handles login/logout flows.
type AuthHandler struct {
	Slurm *services.SlurmService
}

// LoginPage renders the login form, populating it with the live access matrix.
func (h *AuthHandler) LoginPage(c echo.Context) error {
	matrix := h.Slurm.FetchAccessMatrix()
	matrixJSON, _ := json.Marshal(matrix)
	return c.Render(http.StatusOK, "login.html", map[string]interface{}{
		"accessJSON": string(matrixJSON),
	})
}

// LoginAction validates the submitted username/project and issues a session cookie.
func (h *AuthHandler) LoginAction(c echo.Context) error {
	username := c.FormValue("username")
	project := c.FormValue("project")

	matrix := h.Slurm.FetchAccessMatrix()
	if !projectAllowed(matrix[username], project) {
		return c.String(http.StatusForbidden, "User does not have access to this project")
	}

	token, err := h.Slurm.MakeToken(username, project)
	if err != nil {
		return c.String(http.StatusInternalServerError, "Key error")
	}

	c.SetCookie(&http.Cookie{
		Name:     "session",
		Value:    token,
		HttpOnly: true,
		MaxAge:   h.Slurm.TokenLifespan,
	})
	return c.Redirect(http.StatusSeeOther, "/")
}

// Logout clears the session cookie.
func (h *AuthHandler) Logout(c echo.Context) error {
	c.SetCookie(&http.Cookie{Name: "session", MaxAge: -1})
	return c.Redirect(http.StatusSeeOther, "/login")
}

func projectAllowed(projects []string, target string) bool {
	for _, p := range projects {
		if p == target {
			return true
		}
	}
	return false
}
