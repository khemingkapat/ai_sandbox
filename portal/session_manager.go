package main

import (
	"context"
	"fmt"
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
}

// NewSessionManager initializes a new SessionManager using the in-cluster configuration.
func NewSessionManager(namespace string) (*SessionManager, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to get in-cluster config: %w", err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create clientset: %w", err)
	}
	return &SessionManager{
		client:    clientset,
		namespace: namespace,
	}, nil
}

// CreateSession provisions a new interactive session (Pod, Service, and Ingress).
func (sm *SessionManager) CreateSession(ctx context.Context, manifest *AppManifest, slurmArgs map[string]string, username, project, sessionID string) (string, error) {
	labels := map[string]string{
		"app":        "interactive-session",
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

	// 1. Create Pod
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("session-%s", sessionID),
			Namespace: sm.namespace,
			Labels:    labels,
			Annotations: map[string]string{
				"slurmjob.slinky.slurm.net/job-name":  fmt.Sprintf("jupyter-%s", sessionID),
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
						{Name: "BASE_URL", Value: fmt.Sprintf("/%s/jupyter/%s", username, sessionID)},
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
									Path:     fmt.Sprintf("/%s/jupyter/%s", username, sessionID),
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

	return fmt.Sprintf("/%s/jupyter/%s", username, sessionID), nil
}

// GetSessionStatus retrieves the current phase of the Pod associated with an interactive session.
func (sm *SessionManager) GetSessionStatus(ctx context.Context, sessionID string) (string, error) {
	pod, err := sm.client.CoreV1().Pods(sm.namespace).Get(ctx, fmt.Sprintf("session-%s", sessionID), metav1.GetOptions{})
	if err != nil {
		return "", fmt.Errorf("failed to get pod: %w", err)
	}
	switch pod.Status.Phase {
	case corev1.PodPending:
		return "PENDING", nil
	case corev1.PodRunning:
		return "RUNNING", nil
	case corev1.PodSucceeded:
		return "COMPLETED", nil
	case corev1.PodFailed:
		return "FAILED", nil
	default:
		return "UNKNOWN", nil
	}
}

// DeleteSession removes all Kubernetes resources associated with an interactive session.
func (sm *SessionManager) DeleteSession(ctx context.Context, sessionID string) error {
	var errs []string

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
