package services

import (
	"fmt"
	"os"
	"path/filepath"

	"portal/models"

	"gopkg.in/yaml.v3"
)

// ScanApps finds all manifest.yaml files in common storage and the user's project storage.
func ScanApps(project string) []models.AppManifest {
	var apps []models.AppManifest

	searchPaths := []string{
		"/mnt/storage/common/software/*/manifest.yaml",
		fmt.Sprintf("/mnt/storage/projects/%s/software/*/manifest.yaml", project),
	}

	for _, pattern := range searchPaths {
		files, _ := filepath.Glob(pattern)
		for _, file := range files {
			data, err := os.ReadFile(file)
			if err != nil {
				continue
			}
			var app models.AppManifest
			if err := yaml.Unmarshal(data, &app); err != nil {
				continue
			}
			app.SourcePath = filepath.Dir(file)
			if app.SlurmArgs == nil {
				app.SlurmArgs = make(map[string]string)
			}
			apps = append(apps, app)
		}
	}
	return apps
}
