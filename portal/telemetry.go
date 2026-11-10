package main

import (
	"bufio"
	"context"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	api "github.com/SlinkyProject/slurm-client/api/v0042"
	"github.com/SlinkyProject/slurm-client/pkg/client"
	"github.com/SlinkyProject/slurm-client/pkg/types"
	"github.com/labstack/echo/v4"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TelemetryResponse represents the cluster telemetry state payload.
type TelemetryResponse struct {
	Status      string            `json:"status" example:"healthy"`
	Timestamp   time.Time         `json:"timestamp"`
	ActiveUsers int               `json:"active_users" example:"2"`
	Workloads   WorkloadMetrics   `json:"workloads"`
	Services    map[string]string `json:"services"`
}

// WorkloadMetrics represents granular interactive and batch job counts.
type WorkloadMetrics struct {
	InteractiveSessions int `json:"interactive_sessions" example:"1"`
	RunningJobs         int `json:"running_jobs" example:"1"`
	QueueDepth          int `json:"queue_depth" example:"0"`
}

// SubsystemProbes contains raw probe observations across cluster subsystems.
type SubsystemProbes struct {
	VLLMReachable   bool
	MLflowReachable bool
	SlurmReachable  bool
	StorageOK       bool
	BatchGPURunning bool
	InteractivePods int
	RunningJobs     int
	QueuedJobs      int
	ActiveUserSet   map[string]bool
}

// TelemetryScraper manages caching and probing of cluster telemetry.
type TelemetryScraper struct {
	ttl         time.Duration
	authToken   string
	vllmURL     string
	mlflowURL   string
	storagePath string
	mu          sync.RWMutex
	lastRun     time.Time
	cachedResp  *TelemetryResponse
	httpClient  *http.Client
}

// NewTelemetryScraper initializes a TelemetryScraper with specified TTL and Bearer auth token.
func NewTelemetryScraper(ttl time.Duration, authToken string) *TelemetryScraper {
	return &TelemetryScraper{
		ttl:         ttl,
		authToken:   authToken,
		vllmURL:     getEnv("VLLM_HEALTH_URL", "http://vllm-service.services.svc.cluster.local:8000/health"),
		mlflowURL:   getEnv("MLFLOW_HEALTH_URL", "http://mlflow.services.svc.cluster.local:5000/health"),
		storagePath: getEnv("STORAGE_PROBE_PATH", "/mnt/storage"),
		httpClient: &http.Client{
			Timeout: 1500 * time.Millisecond,
		},
	}
}

// handleHealthz handles lightweight unauthenticated liveness probes for Kubelet.
// @Summary Kubelet liveness probe
// @Description Instant zero-allocation health check. Does not touch downstream network or storage.
// @Tags telemetry
// @Produce json
// @Success 200 {object} map[string]string
// @Router /healthz [get]
func handleHealthz(c echo.Context) error {
	return c.JSON(http.StatusOK, map[string]string{
		"status": "ok",
	})
}

// HandleTelemetry serves authenticated cluster telemetry.
// @Summary Cluster health & telemetry
// @Description Returns aggregate status, active user headcount, queue depth, and service health.
// @Tags telemetry
// @Security BearerAuth
// @Produce json
// @Success 200 {object} TelemetryResponse
// @Failure 401 {string} string "Unauthorized"
// @Router /api/v1/telemetry [get]
func (s *TelemetryScraper) HandleTelemetry(c echo.Context) error {
	authHeader := c.Request().Header.Get("Authorization")
	// Fail closed: if authToken is unconfigured or header does not match exactly, reject with 401
	if s.authToken == "" || authHeader != "Bearer "+s.authToken {
		return c.String(http.StatusUnauthorized, "Unauthorized")
	}

	resp := s.GetTelemetry(c.Request().Context())
	return c.JSON(http.StatusOK, resp)
}

// GetTelemetry returns the current telemetry state, utilizing in-memory cache if valid.
func (s *TelemetryScraper) GetTelemetry(ctx context.Context) *TelemetryResponse {
	s.mu.RLock()
	if s.cachedResp != nil && time.Since(s.lastRun) < s.ttl {
		cached := s.cachedResp
		s.mu.RUnlock()
		return cached
	}
	s.mu.RUnlock()

	// Decouple probe execution from client request cancellation to prevent client aborts from poisoning cache
	probeCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// Execute probes outside exclusive lock to avoid blocking readers during network I/O
	probes := s.gatherProbes(probeCtx)
	resp := s.computeTelemetry(probes)

	s.mu.Lock()
	s.cachedResp = resp
	s.lastRun = time.Now()
	s.mu.Unlock()

	return resp
}

// computeTelemetry transforms raw subsystem probes into the public TelemetryResponse.
func (s *TelemetryScraper) computeTelemetry(probes SubsystemProbes) *TelemetryResponse {
	services := make(map[string]string)

	// vLLM with ADR 0003 batch yield handling
	if probes.VLLMReachable {
		services["vllm"] = "healthy"
	} else if probes.BatchGPURunning {
		services["vllm"] = "yielded_for_batch"
	} else {
		services["vllm"] = "error"
	}

	// MLflow
	if probes.MLflowReachable {
		services["mlflow"] = "healthy"
	} else {
		services["mlflow"] = "error"
	}

	// Slurm
	if probes.SlurmReachable {
		services["slurm"] = "healthy"
	} else {
		services["slurm"] = "error"
	}

	// Storage
	if probes.StorageOK {
		services["storage"] = "healthy"
	} else {
		services["storage"] = "error"
	}

	// Determine root status
	status := "healthy"
	if !probes.SlurmReachable || !probes.StorageOK {
		// Core infrastructure failure
		status = "error"
	} else if services["vllm"] == "error" || services["mlflow"] == "error" {
		// Non-critical service failure
		status = "degraded"
	}

	activeUsers := len(probes.ActiveUserSet)

	return &TelemetryResponse{
		Status:      status,
		Timestamp:   time.Now().UTC(),
		ActiveUsers: activeUsers,
		Workloads: WorkloadMetrics{
			InteractiveSessions: probes.InteractivePods,
			RunningJobs:         probes.RunningJobs,
			QueueDepth:          probes.QueuedJobs,
		},
		Services: services,
	}
}

// gatherProbes performs isolated, non-blocking probes across cluster components.
func (s *TelemetryScraper) gatherProbes(ctx context.Context) SubsystemProbes {
	probes := SubsystemProbes{
		ActiveUserSet: make(map[string]bool),
	}

	// 1. Probe vLLM
	probes.VLLMReachable = s.probeHTTP(ctx, s.vllmURL)

	// 2. Probe MLflow
	probes.MLflowReachable = s.probeHTTP(ctx, s.mlflowURL)

	// 3. Probe Storage (non-blocking /proc/mounts + fast stat)
	probes.StorageOK = s.probeStorage(s.storagePath)

	// 4. Probe Slurm
	probes.SlurmReachable, probes.BatchGPURunning, probes.RunningJobs, probes.QueuedJobs = s.probeSlurm(ctx, probes.ActiveUserSet)

	// 5. Probe Interactive Pods in K8s workload namespace
	probes.InteractivePods = s.probeInteractivePods(ctx, probes.ActiveUserSet)

	return probes
}

// probeHTTP executes a quick GET request with timeout.
func (s *TelemetryScraper) probeHTTP(ctx context.Context, url string) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 400
}

// probeStorage verifies storage availability without risk of kernel D-state hung traversals.
func (s *TelemetryScraper) probeStorage(path string) bool {
	// First check /proc/mounts for the mount point if Linux
	if file, err := os.Open("/proc/mounts"); err == nil {
		defer file.Close()
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields) >= 2 && fields[1] == path {
				// Mount is present in kernel table
				return true
			}
		}
	}

	// Fallback fast stat
	statChan := make(chan bool, 1)
	go func() {
		info, err := os.Stat(path)
		statChan <- (err == nil && info.IsDir())
	}()

	select {
	case ok := <-statChan:
		return ok
	case <-time.After(500 * time.Millisecond):
		return false
	}
}

// probeSlurm contacts slurmrestd using an internal minted token.
func (s *TelemetryScraper) probeSlurm(ctx context.Context, userSet map[string]bool) (reachable bool, batchGPURunning bool, running int, queued int) {
	if slurmRestURL == "" {
		return false, false, 0, 0
	}

	// Mint short-lived internal token for Slurm (POSIX user root)
	adminToken, err := makeSlurmToken("root", "root")
	if err != nil {
		return false, false, 0, 0
	}

	slurmClient, err := client.NewClient(&client.Config{Server: slurmRestURL, AuthToken: adminToken})
	if err != nil {
		return false, false, 0, 0
	}

	jobList := &types.V0042JobInfoList{}
	if err := slurmClient.List(ctx, jobList); err != nil {
		return false, false, 0, 0
	}

	reachable = true
	for _, j := range jobList.Items {
		stateSet := j.GetStateAsSet()
		if stateSet.Has(api.V0042JobInfoJobStateRUNNING) {
			running++
			if j.Partition != nil && *j.Partition == "batch-gpu" {
				batchGPURunning = true
			}
			if j.UserName != nil && *j.UserName != "" {
				userSet[*j.UserName] = true
			}
		} else if stateSet.Has(api.V0042JobInfoJobStatePENDING) {
			queued++
		}
	}
	return reachable, batchGPURunning, running, queued
}

// probeInteractivePods counts running pods in workload namespace via SessionManager's client.
func (s *TelemetryScraper) probeInteractivePods(ctx context.Context, userSet map[string]bool) int {
	if sessionManager == nil || sessionManager.client == nil {
		return 0
	}

	pods, err := sessionManager.client.CoreV1().Pods(sessionManager.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "app=interactive-session",
	})
	if err != nil {
		return 0
	}

	count := 0
	for _, pod := range pods.Items {
		if pod.Status.Phase == "Running" {
			count++
			if user, ok := pod.Labels["user"]; ok && user != "" {
				userSet[user] = true
			}
		}
	}
	return count
}
