package main

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestCreateSession_ScopedSubPathsAndSecurityContext(t *testing.T) {
	fakeClient := fake.NewSimpleClientset()
	sm := &SessionManager{
		client:     fakeClient,
		namespace:  "workload",
		traefikDir: "",
	}

	manifest := &AppManifest{
		ID:        "jupyterlab",
		Type:      "interactive",
		Image:     "interactive-jupyter:latest",
		SlurmArgs: map[string]string{"cpus-per-task": "2", "mem": "4G"},
	}

	sessionID := "1700000000000"
	username := "user1"
	project := "project1"

	_, err := sm.CreateSession(context.Background(), manifest, nil, username, project, sessionID)
	if err != nil {
		t.Fatalf("CreateSession failed: %v", err)
	}

	pod, err := fakeClient.CoreV1().Pods("workload").Get(context.Background(), "session-"+sessionID, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("failed to get created pod: %v", err)
	}

	// 1. Check SecurityContext (Trap 3)
	if pod.Spec.SecurityContext == nil {
		t.Fatal("expected pod.Spec.SecurityContext to be set, got nil")
	}
	if pod.Spec.SecurityContext.RunAsUser == nil || *pod.Spec.SecurityContext.RunAsUser != 1001 {
		t.Errorf("expected RunAsUser=1001, got %v", pod.Spec.SecurityContext.RunAsUser)
	}
	if pod.Spec.SecurityContext.RunAsGroup == nil || *pod.Spec.SecurityContext.RunAsGroup != 2001 {
		t.Errorf("expected RunAsGroup=2001, got %v", pod.Spec.SecurityContext.RunAsGroup)
	}

	// 2. Check Scoped VolumeMounts (Trap 2 - No monolithic /mnt/storage mount)
	container := pod.Spec.Containers[0]
	expectedMounts := map[string]struct {
		mountPath string
		subPath   string
		readOnly  bool
	}{
		"project":  {"/mnt/storage/projects/project1", "projects/project1", false},
		"scratch":  {"/mnt/storage/scratch", "scratch", false},
		"datasets": {"/mnt/storage/datasets", "datasets", true},
		"models":   {"/mnt/storage/models", "models", true},
		"extrausers": {"/var/lib/extrausers", "common/etc", true},
	}

	mountsFound := 0
	for _, vm := range container.VolumeMounts {
		if vm.MountPath == "/mnt/storage" && vm.SubPath == "" {
			t.Errorf("found forbidden monolithic /mnt/storage mount without subPath")
		}
		for _, exp := range expectedMounts {
			if vm.MountPath == exp.mountPath {
				mountsFound++
				if vm.SubPath != exp.subPath {
					t.Errorf("mount %s expected subPath %s, got %s", exp.mountPath, exp.subPath, vm.SubPath)
				}
				if vm.ReadOnly != exp.readOnly {
					t.Errorf("mount %s expected readOnly %v, got %v", exp.mountPath, exp.readOnly, vm.ReadOnly)
				}
			}
		}
	}

	if mountsFound != len(expectedMounts) {
		t.Errorf("expected %d scoped subPath mounts, found %d", len(expectedMounts), mountsFound)
	}
}

func TestResolveUserSecurityContext(t *testing.T) {
	// Test root
	rootCtx := resolveUserSecurityContext("root", "admin")
	if rootCtx.RunAsUser == nil || *rootCtx.RunAsUser != 0 {
		t.Errorf("root expected RunAsUser=0, got %v", rootCtx.RunAsUser)
	}

	// Test user1 / project1 fallback
	userCtx := resolveUserSecurityContext("user1", "project1")
	if userCtx.RunAsUser == nil || *userCtx.RunAsUser != 1001 {
		t.Errorf("user1 expected RunAsUser=1001, got %v", userCtx.RunAsUser)
	}
	if userCtx.RunAsGroup == nil || *userCtx.RunAsGroup != 2001 {
		t.Errorf("user1 expected RunAsGroup=2001, got %v", userCtx.RunAsGroup)
	}
}
