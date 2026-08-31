package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	corev1 "k8s.io/api/core/v1"
	netv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// SessionManager handles the lifecycle of interactive OCI-based sessions in Kubernetes.
type SessionManager struct {
	// client is the Kubernetes clientset used for API operations.
	client *kubernetes.Clientset
	// namespace is the Kubernetes namespace where session resources are created.
	namespace string
	// traefikDir is the directory where dynamic Traefik YAML configuration files are written.
	traefikDir string
}

// NewSessionManager initializes a new SessionManager using the in-cluster configuration.
func NewSessionManager(namespace, traefikDir string) (*SessionManager, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to get in-cluster config: %w", err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create clientset: %w", err)
	}
	return &SessionManager{
		client:     clientset,
		namespace:  namespace,
		traefikDir: traefikDir,
	}, nil
}

// CreateSession provisions a new interactive session (Pod, Service, and Ingress).
func (sm *SessionManager) CreateSession(ctx context.Context, manifest *AppManifest, slurmArgs map[string]string, username, project, sessionID string) (string, error) {
	labels := map[string]string{
		"app":        "interactive-session",
		"app-id":     manifest.ID,
		"session-id": sessionID,
		"user":       username,
		"project":    project,
	}

	workspace := fmt.Sprintf("/mnt/storage/projects/%s", project)
	if username == "root" {
		workspace = "/root"
	}

	if slurmArgs == nil {
		slurmArgs = manifest.SlurmArgs
	}

	basePath := fmt.Sprintf("/%s/%s/%s", username, manifest.ID, sessionID)

	// 1. Create Pod
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("session-%s", sessionID),
			Namespace: sm.namespace,
			Labels:    labels,
			Annotations: map[string]string{
				"slurmjob.slinky.slurm.net/job-name":  fmt.Sprintf("%s-%s", manifest.ID, sessionID),
				"slurmjob.slinky.slurm.net/partition": "interactive",
				"slurmjob.slinky.slurm.net/account":   project,
				"slurmjob.slinky.slurm.net/user-id":   username,
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name:            "session",
					Image:           manifest.Image,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Env: []corev1.EnvVar{
						{Name: "WORKSPACE", Value: workspace},
						{Name: "USER", Value: username},
						{Name: "HOME", Value: workspace},
						{Name: "ALLOCATED_PORT", Value: "8888"},
						{Name: "BASE_URL", Value: "/"},
						{Name: "HF_HOME", Value: fmt.Sprintf("%s/.cache/huggingface", workspace)},
						{Name: "HF_HUB_CACHE", Value: "/mnt/storage/models/huggingface/hub"},
						{Name: "TORCH_HOME", Value: "/mnt/storage/models/torch"},
						{Name: "TRANSFORMERS_OFFLINE", Value: "0"},
						{Name: "KAGGLE_CONFIG_DIR", Value: fmt.Sprintf("%s/.kaggle", workspace)},
						{Name: "KAGGLEHUB_CACHE", Value: fmt.Sprintf("%s/.cache/kagglehub", workspace)},
						{Name: "TMPDIR", Value: fmt.Sprintf("/mnt/storage/scratch/%s", username)},
					},
					Ports: []corev1.ContainerPort{
						{ContainerPort: 8888},
					},
					VolumeMounts: []corev1.VolumeMount{
						{Name: "storage", MountPath: "/mnt/storage"},
					},
					Resources: corev1.ResourceRequirements{
						Requests: corev1.ResourceList{},
						Limits:   corev1.ResourceList{},
					},
				},
			},
			Volumes: []corev1.Volume{
				{
					Name: "storage",
					VolumeSource: corev1.VolumeSource{
						PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
							ClaimName: "slinky-storage-pvc",
						},
					},
				},
			},
			RestartPolicy: corev1.RestartPolicyNever,
		},
	}

	if cpus, ok := slurmArgs["cpus-per-task"]; ok {
		if q, err := resource.ParseQuantity(cpus); err == nil {
			pod.Spec.Containers[0].Resources.Requests[corev1.ResourceCPU] = q
			pod.Spec.Containers[0].Resources.Limits[corev1.ResourceCPU] = q
		}
	}
	if mem, ok := slurmArgs["mem"]; ok {
		if q, err := resource.ParseQuantity(mem); err == nil {
			pod.Spec.Containers[0].Resources.Requests[corev1.ResourceMemory] = q
			pod.Spec.Containers[0].Resources.Limits[corev1.ResourceMemory] = q
		}
	}

	_, err := sm.client.CoreV1().Pods(sm.namespace).Create(ctx, pod, metav1.CreateOptions{})
	if err != nil {
		return "", fmt.Errorf("failed to create pod: %w", err)
	}

	// 2. Create Service
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("svc-%s", sessionID),
			Namespace: sm.namespace,
			Labels:    labels,
		},
		Spec: corev1.ServiceSpec{
			Selector: labels,
			Ports: []corev1.ServicePort{
				{
					Port:       8888,
					TargetPort: intstr.FromInt(8888),
				},
			},
			Type: corev1.ServiceTypeClusterIP,
		},
	}
	_, err = sm.client.CoreV1().Services(sm.namespace).Create(ctx, svc, metav1.CreateOptions{})
	if err != nil {
		return "", fmt.Errorf("failed to create service: %w", err)
	}

	// 3. Create Ingress
	pathType := netv1.PathTypePrefix
	ingress := &netv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("ing-%s", sessionID),
			Namespace: sm.namespace,
			Labels:    labels,
			Annotations: map[string]string{
				"traefik.ingress.kubernetes.io/router.entrypoints": "web",
			},
		},
		Spec: netv1.IngressSpec{
			Rules: []netv1.IngressRule{
				{
					IngressRuleValue: netv1.IngressRuleValue{
						HTTP: &netv1.HTTPIngressRuleValue{
							Paths: []netv1.HTTPIngressPath{
								{
									Path:     basePath,
									PathType: &pathType,
									Backend: netv1.IngressBackend{
										Service: &netv1.IngressServiceBackend{
											Name: svc.Name,
											Port: netv1.ServiceBackendPort{
												Number: 8888,
											},
										},
									},
								},
							},
						},
					},
				},
			},
		},
	}
	_, err = sm.client.NetworkingV1().Ingresses(sm.namespace).Create(ctx, ingress, metav1.CreateOptions{})
	if err != nil {
		return "", fmt.Errorf("failed to create ingress: %w", err)
	}

	// 4. Create Dynamic Traefik Route with StripPrefix
	if sm.traefikDir != "" {
		traefikCfg := fmt.Sprintf("http:\n  routers:\n    session-%[1]s:\n      entryPoints:\n        - web\n      rule: \"PathPrefix(\x60%[2]s\x60)\"\n      priority: 100\n      middlewares:\n        - strip-%[1]s\n      service: svc-%[1]s\n  middlewares:\n    strip-%[1]s:\n      stripPrefix:\n        prefixes:\n          - \"%[2]s/\"\n          - \"%[2]s\"\n  services:\n    svc-%[1]s:\n      loadBalancer:\n        servers:\n          - url: \"http://svc-%[1]s.%[3]s.svc.cluster.local:8888\"\n", sessionID, basePath, sm.namespace)

		cfgPath := filepath.Join(sm.traefikDir, fmt.Sprintf("session-%s.yaml", sessionID))
		if err := os.WriteFile(cfgPath, []byte(traefikCfg), 0644); err != nil {
			fmt.Printf("Warning: failed to write traefik session route: %v\n", err)
		}
	}

	return basePath + "/", nil
}

// GetSessionInfo retrieves the current phase and proxy path of the Pod associated with an interactive session.
func (sm *SessionManager) GetSessionInfo(ctx context.Context, sessionID string) (string, string, error) {
	pod, err := sm.client.CoreV1().Pods(sm.namespace).Get(ctx, fmt.Sprintf("session-%s", sessionID), metav1.GetOptions{})
	if err != nil {
		return "", "", fmt.Errorf("failed to get pod: %w", err)
	}

	username := pod.Labels["user"]
	appID := pod.Labels["app-id"]
	if appID == "" {
		appID = "jupyterlab"
	}
	proxyPath := fmt.Sprintf("/%s/%s/%s/", username, appID, sessionID)

	state := "UNKNOWN"
	switch pod.Status.Phase {
	case corev1.PodPending:
		state = "PENDING"
	case corev1.PodRunning:
		state = "RUNNING"
	case corev1.PodSucceeded:
		state = "COMPLETED"
	case corev1.PodFailed:
		state = "FAILED"
	}
	return state, proxyPath, nil
}

// GetSessionStatus retrieves the current phase of the Pod associated with an interactive session.
func (sm *SessionManager) GetSessionStatus(ctx context.Context, sessionID string) (string, error) {
	status, _, err := sm.GetSessionInfo(ctx, sessionID)
	return status, err
}

// DeleteSession removes all Kubernetes resources associated with an interactive session.
func (sm *SessionManager) DeleteSession(ctx context.Context, sessionID string) error {
	var errs []string

	if sm.traefikDir != "" {
		cfgPath := filepath.Join(sm.traefikDir, fmt.Sprintf("session-%s.yaml", sessionID))
		_ = os.Remove(cfgPath)
	}

	err := sm.client.NetworkingV1().Ingresses(sm.namespace).Delete(ctx, fmt.Sprintf("ing-%s", sessionID), metav1.DeleteOptions{})
	if err != nil {
		errs = append(errs, err.Error())
	}

	err = sm.client.CoreV1().Services(sm.namespace).Delete(ctx, fmt.Sprintf("svc-%s", sessionID), metav1.DeleteOptions{})
	if err != nil {
		errs = append(errs, err.Error())
	}

	err = sm.client.CoreV1().Pods(sm.namespace).Delete(ctx, fmt.Sprintf("session-%s", sessionID), metav1.DeleteOptions{})
	if err != nil {
		errs = append(errs, err.Error())
	}

	if len(errs) > 0 {
		return fmt.Errorf("failed to delete session: %s", strings.Join(errs, ", "))
	}
	return nil
}
