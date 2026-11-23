package main

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
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

	_, err := sm.CreateSession(context.Background(), manifest, nil, username, project, sessionID, "student")
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
		"project":    {"/mnt/storage/projects/project1", "projects/project1", false},
		"labs":       {"/mnt/storage/projects/project1/labs", "labs", true},
		"scratch":    {"/mnt/storage/scratch", "scratch", false},
		"datasets":   {"/mnt/storage/datasets", "datasets", true},
		"models":     {"/mnt/storage/models", "models", true},
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

	// 3. Check Central Services Environment Injection (WP11 MLflow & WP14 Qdrant)
	expectedEnvs := map[string]string{
		"MLFLOW_TRACKING_URI": "http://mlflow.services.svc.cluster.local:5000",
		"QDRANT_URL":          "http://qdrant.services.svc.cluster.local:6333",
	}
	for expK, expV := range expectedEnvs {
		found := false
		for _, env := range container.Env {
			if env.Name == expK {
				found = true
				if env.Value != expV {
					t.Errorf("expected env %s=%s, got %s", expK, expV, env.Value)
				}
				break
			}
		}
		if !found {
			t.Errorf("expected env %s=%s to be injected into session container, but not found", expK, expV)
		}
	}
}

func TestCreateSession_RoleBasedLabsMount(t *testing.T) {
	tests := []struct {
		name             string
		role             string
		expectedRoleLbl  string
		expectedReadOnly bool
		expectStaffGID   bool
	}{
		{
			name:             "student gets read-only labs mount without staff GID",
			role:             "student",
			expectedRoleLbl:  "student",
			expectedReadOnly: true,
			expectStaffGID:   false,
		},
		{
			name:             "instructor gets read-write labs mount with staff GID 2999",
			role:             "instructor",
			expectedRoleLbl:  "instructor",
			expectedReadOnly: false,
			expectStaffGID:   true,
		},
		{
			name:             "ta normalizes to instructor with read-write labs mount and staff GID 2999",
			role:             "ta",
			expectedRoleLbl:  "instructor",
			expectedReadOnly: false,
			expectStaffGID:   true,
		},
		{
			name:             "admin gets read-write labs mount with staff GID 2999",
			role:             "admin",
			expectedRoleLbl:  "admin",
			expectedReadOnly: false,
			expectStaffGID:   true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fakeClient := fake.NewSimpleClientset()
			sm := &SessionManager{
				client:    fakeClient,
				namespace: "workload",
			}
			manifest := &AppManifest{
				ID:    "jupyterlab",
				Type:  "interactive",
				Image: "interactive-jupyter:latest",
			}

			_, err := sm.CreateSession(context.Background(), manifest, nil, "user1", "project1", "sess1", tc.role)
			if err != nil {
				t.Fatalf("CreateSession(%s) failed: %v", tc.role, err)
			}

			pod, err := fakeClient.CoreV1().Pods("workload").Get(context.Background(), "session-sess1", metav1.GetOptions{})
			if err != nil {
				t.Fatalf("get pod failed: %v", err)
			}

			if got := pod.Labels["role"]; got != tc.expectedRoleLbl {
				t.Errorf("expected pod label role=%q, got %q", tc.expectedRoleLbl, got)
			}

			foundLabs := false
			for _, vm := range pod.Spec.Containers[0].VolumeMounts {
				if vm.MountPath == "/mnt/storage/projects/project1/labs" {
					foundLabs = true
					if vm.SubPath != "labs" {
						t.Errorf("expected subPath=labs, got %q", vm.SubPath)
					}
					if vm.ReadOnly != tc.expectedReadOnly {
						t.Errorf("role %q: expected labs ReadOnly=%v, got %v", tc.role, tc.expectedReadOnly, vm.ReadOnly)
					}
				}
			}
			if !foundLabs {
				t.Fatalf("expected labs volumeMount at /mnt/storage/projects/project1/labs, not found")
			}

			hasStaffGID := false
			if pod.Spec.SecurityContext != nil {
				for _, g := range pod.Spec.SecurityContext.SupplementalGroups {
					if g == 2999 {
						hasStaffGID = true
						break
					}
				}
			}
			if hasStaffGID != tc.expectStaffGID {
				t.Errorf("role %q: expected SupplementalGroups contains 2999 = %v, got %v", tc.role, tc.expectStaffGID, hasStaffGID)
			}
		})
	}
}

func TestFindActiveSession_ReuseAndRoleIsolation(t *testing.T) {
	fakeClient := fake.NewSimpleClientset(&corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "session-1700000001",
			Namespace: "workload",
			Labels: map[string]string{
				"app":        "interactive-session",
				"app-id":     "jupyterlab",
				"session-id": "1700000001",
				"user":       "user1",
				"project":    "project1",
				"role":       "student",
			},
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	})

	sm := &SessionManager{
		client:    fakeClient,
		namespace: "workload",
	}

	// Exact match should reuse
	sid, basePath, err := sm.FindActiveSession(context.Background(), "user1", "project1", "jupyterlab", "student")
	if err != nil {
		t.Fatalf("FindActiveSession failed: %v", err)
	}
	if sid != "1700000001" {
		t.Errorf("expected sessionID 1700000001, got %q", sid)
	}
	if basePath != "/user1/jupyterlab/1700000001/" {
		t.Errorf("expected basePath /user1/jupyterlab/1700000001/, got %q", basePath)
	}

	// Role mismatch must NOT reuse student RO pod for instructor
	sid, _, err = sm.FindActiveSession(context.Background(), "user1", "project1", "jupyterlab", "instructor")
	if err != nil {
		t.Fatalf("FindActiveSession role mismatch returned error: %v", err)
	}
	if sid != "" {
		t.Errorf("expected empty sessionID for instructor role mismatch, got %q", sid)
	}

	// User mismatch must NOT reuse
	sid, _, err = sm.FindActiveSession(context.Background(), "user2", "project1", "jupyterlab", "student")
	if err != nil {
		t.Fatalf("FindActiveSession user mismatch returned error: %v", err)
	}
	if sid != "" {
		t.Errorf("expected empty sessionID for user2, got %q", sid)
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
