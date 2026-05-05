package models

// AppManifest represents an application configuration loaded from a manifest.yaml file.
type AppManifest struct {
	ID          string            `yaml:"id"`
	Name        string            `yaml:"name"`
	Description string            `yaml:"description"`
	Icon        string            `yaml:"icon"`
	ImageFile   string            `yaml:"image_file"`
	ExecCommand string            `yaml:"exec_command"`
	SourcePath  string            `yaml:"-"` // filled in at scan time
	SlurmArgs   map[string]string `yaml:"slurm_args"`
}

// PortLease represents an active port allocation for a running job.
type PortLease struct {
	Port         int
	JobID        int
	Username     string
	NodeHostname string
	NodeIP       string
	LeasedAt     string
	Status       string
}
