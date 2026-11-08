package main

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// AppManifest represents an application configuration loaded from a YAML file.
type AppManifest struct {
	// ID is the unique identifier for the application.
	ID string `yaml:"id"`
	// Name is the display name of the application.
	Name string `yaml:"name"`
	// Description is a brief summary of the application's purpose.
	Description string `yaml:"description"`
	// Icon is the CSS class name or path for the application's icon.
	Icon string `yaml:"icon"`
	// Type specifies the execution model: "interactive" or "batch".
	Type string `yaml:"type"`
	// Image is the OCI image reference for "interactive" applications.
	Image string `yaml:"image"`
	// ImageFile is the path to an Apptainer SIF file for "batch" applications.
	ImageFile string `yaml:"image_file"`
	// ExecCommand is the command string to execute within the application context.
	ExecCommand string `yaml:"exec_command"`
	// SourcePath is the directory containing the manifest file (not serialized).
	SourcePath string `yaml:"-"`
	// SlurmArgs contains default Slurm job submission arguments.
	SlurmArgs map[string]string `yaml:"slurm_args"`
}

// scanApps searches for manifest.yaml files in global and project-specific paths.
// It parses valid manifests into AppManifest structs.
func scanApps(project string) []AppManifest {
	var apps []AppManifest

	searchPaths := []string{
		"/mnt/storage/common/software/*/manifest.yaml",
		fmt.Sprintf("/mnt/storage/projects/%s/software/*/manifest.yaml", project),
	}

	for _, searchPath := range searchPaths {
		files, _ := filepath.Glob(searchPath)
		for _, file := range files {
			data, err := os.ReadFile(file)
			if err == nil {
				var app AppManifest
				if err := yaml.Unmarshal(data, &app); err == nil {
					// Validation logic
					if app.Type == "" {
						app.Type = "batch"
					}

					if app.Type != "interactive" && app.Type != "batch" {
						fmt.Printf("Warning: manifest %s has invalid type %s, skipping\n", file, app.Type)
						continue
					}

					if app.Type == "interactive" && app.Image == "" {
						fmt.Printf("Warning: interactive manifest %s is missing image field, skipping\n", file)
						continue
					}

					app.SourcePath = filepath.Dir(file)
					// Initialize map if missing
					if app.SlurmArgs == nil {
						app.SlurmArgs = make(map[string]string)
					}
					apps = append(apps, app)
				}
			}
		}
	}
	return apps
}
