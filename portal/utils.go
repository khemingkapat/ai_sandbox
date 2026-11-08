package main

import (
	"html/template"
	"io"
	"os"

	"github.com/labstack/echo/v4"
)

// TemplateRenderer handles the rendering of HTML templates for the Echo framework.
// It wraps a collection of pre-parsed templates.
type TemplateRenderer struct {
	// templates is the collection of templates to use for rendering.
	templates *template.Template
}

// Render renders an HTML template by its name with the provided data.
// It implements the echo.Renderer interface.
func (t *TemplateRenderer) Render(w io.Writer, name string, data interface{}, c echo.Context) error {
	return t.templates.ExecuteTemplate(w, name, data)
}

// getEnv retrieves the value of the environment variable named by the key.
// It returns the value if it exists, or the provided fallback string otherwise.
func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
