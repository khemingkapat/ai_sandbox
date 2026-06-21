# Slinky Migration: Project Increment Log

This file tracks every discrete increment made during the Slinky migration. Its goal is to keep the human lead (**Khem**) fully informed of design choices, modified files, and verification steps.

## [Increment 7] - 2026-06-21: Web Portal Enhancements

*   **Author:** Jules (Async)
*   **Goal:** Enhance the Go/Echo web portal to natively query the Slurm REST API for job tracking and resource status, adding a user dashboard and resource availability views.

### 📝 Key Changes & Files Modified

1.  **Backend Enhancements:**
    *   Updated `portal/main.go`:
        *   Implemented `apiUserJobs` handler to fetch and filter jobs for the logged-in user via Slurm REST API.
        *   Implemented `apiClusterStatus` handler to calculate cluster metrics (active jobs, nodes, queue depth) from Slurm REST API.
        *   Updated `submitJob` to correctly map CPU requirements and partition selection to the Slurm REST API payload.
        *   Registered new API routes: `GET /api/jobs` and `GET /api/cluster/status`.
2.  **Frontend Enhancements:**
    *   Updated `portal/templates/index.html`:
        *   Added a live "Resource Status" panel showing cluster-wide metrics.
        *   Added a "My Jobs" dashboard section to list user-specific jobs and their states.
        *   Implemented JavaScript polling to dynamically update the UI from the new backend API endpoints.
        *   Added a "Track" feature to allow monitoring of existing jobs directly from the dashboard.

### 💡 Why This Design?
*   **Native Slurm Integration:** Eliminates the need for external CLI wrappers by leveraging the Slurm REST API directly within the portal backend.
*   **Improved User Experience:** Provides users with real-time visibility into cluster availability and their own job statuses, making the platform more transparent and easier to use.
*   **Scalability:** The dashboard-driven approach prepares the portal for more complex multi-user environments by centralizing status tracking.

### 🛠️ Verification Steps
1.  **Compile the portal:**
    ```bash
    cd portal
    go mod tidy
    go build -o portal_bin main.go port_manager.go
    ```
    *(Confirm successful compilation without errors).*
2.  **Deploy and Verify UI:**
    *(Once deployed in the cluster, log in and verify that the Resource Status panel and My Jobs list update dynamically).*

---

## [Increment 6] - 2026-06-21: Multi-User Concurrent Job & Isolation Verification Suite

*   **Author:** Jules (Async) & Antigravity
*   **Goal:** Implement a verification suite to test concurrent Slurm job submissions and project directory access isolation under multiple user identities.

### 📝 Key Changes & Files Modified

1.  **Multi-User Verification Script:**
    *   Created [scripts/verify-multi-user-jobs.sh](scripts/verify-multi-user-jobs.sh): A bash script that provisions four test users (`user1-4`), sets up test project directories, submits concurrent jobs to verify parallel execution, and asserts file access permissions for each user.

### 💡 Why This Design?
*   **End-to-End Multi-Tenancy Validation:** Simulates realistic student workflows (submitting multiple parallel jobs) while ensuring strict Unix directory isolation boundaries remain functional at the scheduler and compute nodes level.
*   **Environment Adaptability:** Dynamically detects SlurmDBD accounting mode or standard mode, and properly cleans up test users and resources on completion.

### 🛠️ Verification Steps
To execute the multi-user test suite:
1.  **Run the Verification:** `./scripts/verify-multi-user-jobs.sh`
    *(Confirm that users are created, jobs run in parallel, all isolation permissions pass, and cleanup finishes successfully).*

---

## [Increment 5] - 2026-06-21: Unix Permissions Isolation Verification Suite

*   **Author:** Jules (Interactive)
*   **Goal:** Implement a verification suite to ensure Kubernetes-native storage isolation via Unix permissions is working as intended.

### 📝 Key Changes & Files Modified

1.  **Isolation Verification Suite:**
    *   Created [scripts/verify-isolation.sh](scripts/verify-isolation.sh): A bash script that simulates multiple UIDs (1001, 1002) and asserts their access to project-specific and common directories.
2.  **Test Environment Setup:**
    *   Established the expected directory structure and permission model for testing:
        *   `/mnt/storage/projects/project1` owned by UID 1001 (700).
        *   `/mnt/storage/projects/project2` owned by UID 1002 (700).
        *   `/mnt/storage/common` owned by root (755).

### 💡 Why This Design?
*   **Standardized Validation:** Provides a repeatable way to verify that the Unix-level isolation (which replaces LDAP/SSSD) correctly prevents unauthorized access between projects while allowing shared access to common resources.
*   **Zero-Dependency Execution:** Uses standard `sudo` and `bash` commands, making it easy to run in various environments including local development and CI/CD pipelines.

### 🛠️ Verification Steps
To execute the isolation test suite:
1.  **Run the Verification:** `./scripts/verify-isolation.sh`
    *(Verify that it checks both users and all directory combinations, exiting with code 0).*

---

## [Increment 4] - 2026-06-14: Kubelet Feature Gate Bypass, Custom IPv4 Network & Verification Suite Fixes

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Resolve Kubelet start crash due to missing kernel key parameters, fix multi-node join DNS failure, fix script typos/race conditions, and successfully pass the 5-part verification suite.

### 📝 Key Changes & Files Modified

1.  **Kubelet In User Namespace:**
    *   Updated [kind-config.yaml](file:///home/khemi/workspace/ai_sandbox/kind-config.yaml): Enabled the `KubeletInUserNamespace=true` feature gate for all nodes. This allows Kubelet to ignore missing kernel parameters (such as `/proc/sys/kernel/keys/root_maxkeys`) when running in restricted environments, preventing startup crashes.
2.  **Custom IPv4 Network:**
    *   Recreated the `kind` Docker network as an IPv4-only network. This works around host `ip6tables` limitations while keeping container-name DNS resolution active so worker nodes can join the cluster.
3.  **Script Bug & Race Fixes:**
    *   Updated [scripts/verify-infrastructure.sh](file:///home/khemi/workspace/ai_sandbox/scripts/verify-infrastructure.sh):
        *   Fixed worker pod waiting race condition by polling until worker pods are created.
        *   Fixed incorrect label selector for worker pods (`app.kubernetes.io/name=slurmd` instead of `app.kubernetes.io/component=slurmd`).
        *   Replaced `sacct` calls with `scontrol show job` to enable job verification when Slurm accounting (`slurmdbd`) is disabled.
        *   Added `sleep 3` sync delay in Test 5 to let Slurmctld write checkpoints to persistent storage before crash simulation.
4.  **Directory Permissions:**
    *   Updated host directory permissions (`chmod -R 777 ./storage`) to ensure the containerized `slurm` user (UID 401) has write permissions to write job outputs and logs.
5.  **Repository Cleanup:**
    *   Deleted the obsolete `docker-compose.yml` file, which was left over from the old LDAP/SSSD container setup.

### 💡 Why This Design?
*   **Zero-Host-Kernel Overhead:** Bypassing the kernel key check inside Kubelet means developers and CI environments don't need to rebuild or recompile host kernels.
*   **Robust Verification:** Eliminating race conditions and incorrect selectors makes the verification suite robust, preparing it for Jules' weekly automated stability runs.

### 🛠️ Verification Steps
To execute the test suite:
1.  **Run the Verification:** `./scripts/verify-infrastructure.sh`
    *(Verify that it builds the cluster, runs all 5 test scenarios, and exits with code 0).*

---

## [Increment 3] - 2026-06-13: Detailed Automation Docs & Central Branch Integration

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Document the 5-part verification suite under the automation workflow and push the complete codebase to the central `development` branch for Jules integration.

### 📝 Key Changes & Files Modified

1.  **Workflow Documentation:**
    *   Updated [DEVELOPMENT_WORKFLOW.md](file:///home/khemi/workspace/ai_sandbox/DEVELOPMENT_WORKFLOW.md): Listed and detailed the 5 core test cases (Clean Cluster Spawn, Standard Queueing, Parallel Node Execution, Persistent Shared Storage, and Disaster Recovery) under Task A (Stability Check).
2.  **Central Branch Integration:**
    *   Merged the `feature/k8s-native-isolation` branch into `development` and successfully pushed it to remote `origin/development`. This enables Jules to locate and run [scripts/verify-infrastructure.sh](file:///home/khemi/workspace/ai_sandbox/scripts/verify-infrastructure.sh).

---

## [Increment 5] - 2026-06-21: Storage Layout and Permissions Script

*   **Author:** Jules (Async)
*   **Goal:** Initialize the directory hierarchy and set up Unix permissions to isolate student projects under `/mnt/storage`.

### 📝 Key Changes & Files Modified

1.  **Storage Initialization Script:**
    *   Created [scripts/init-storage.sh](file:///app/scripts/init-storage.sh): A Bash script that ensures the existence of `/mnt/storage` subdirectories (`projects/project1`, `projects/project2`, `common`, `datasets`) and applies specific UID/GID and chmod permissions to ensure tenant isolation and shared access to common resources.

### 💡 Why This Design?
*   **Native Isolation:** Leveraging standard Linux filesystem permissions (UID/GID) provides a robust and low-overhead method for isolating multi-tenant workloads.
*   **Consistency:** Standardizing the directory layout ensures that the web portal and Slurm compute nodes have a predictable environment for accessing user data and shared datasets.

### 🛠️ Verification Steps
To execute the storage initialization:
1.  **Run the script:** `sudo bash scripts/init-storage.sh`
2.  **Verify results:** `ls -lnR /mnt/storage`
    *(Confirm that `project1` is 1001:1001/700, `project2` is 1002:1002/700, and `common`/`datasets` are 0:0/555).*

---

## [Increment 2] - 2026-06-13: Slinky Infrastructure Verification Suite & Automation Plan

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Establish a robust infrastructure continuity test suite and define the branching and automation strategy for Jules (GCP).

### 📝 Key Changes & Files Modified

1.  **Infrastructure Verification Suite:**
    *   Created [scripts/verify-infrastructure.sh](file:///home/khemi/workspace/ai_sandbox/scripts/verify-infrastructure.sh): Implemented a 5-part test suite (Clean Spawn, Standard Queueing, Parallel Node Execution, Persistent Storage Mounts, and Disaster Recovery / Crash Simulation) that dynamically bootstraps its own dependencies (`kind`, `kubectl`, and `helm`) if they are missing from the path.
2.  **Workflow & Automation Design:**
    *   Updated [DEVELOPMENT_WORKFLOW.md](file:///home/khemi/workspace/ai_sandbox/DEVELOPMENT_WORKFLOW.md): Established the central `development` branch and defined standard prompt templates for recurring tasks (Stability Check, Code Quality, and Repo Cleanup) to be run asynchronously on GCP via `jules.google.com`.
3.  **Cleanups:**
    *   Removed temporary check scripts and kept the workspace clean.

### 💡 Why This Design?
*   **Decoupled Heavy Compute:** By using jules.google.com to execute `verify-infrastructure.sh` on GCP VMs, Khem's local machine is spared the overhead of booting Kubernetes clusters and running multi-node simulations.
*   **Zero-Dependency Portability:** Dynamic bootstrapping of CLI tools ensures the script runs immediately on any fresh VM without needing Nix installation or tool configuration overhead.
*   **Isolated Integration:** Merging features into `development` and letting Jules verify it ensures that any configuration errors or regression failures are caught in staging before ever touching `main`.

### 🛠️ Verification Steps
To execute the newly created test suite:
1.  **Run the Verification:** `./scripts/verify-infrastructure.sh`
    *(Wait for it to download any missing tools, execute all 5 test scenarios, and verify that it exits with code 0).*

---

## [Increment 1] - 2026-06-13: Kubernetes-Native Storage Isolation

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Replace complex LDAP/SSSD user directory synchronization with native Kubernetes Persistent Volume mounts mapped directly to host-level directories for isolation.

### 📝 Key Changes & Files Modified

1.  **Kind Cluster Configuration:**
    *   Updated [kind-config.yaml](file:///home/khemi/workspace/ai_sandbox/kind-config.yaml): Configured all Kind cluster nodes (control-plane, worker 1, worker 2) to mount the local workspace path `/home/khemi/workspace/ai_sandbox/storage` to `/mnt/storage` inside the cluster container.
2.  **Persistent Volume & Claim Definitions:**
    *   Created [pv-pvc.yaml](file:///home/khemi/workspace/ai_sandbox/pv-pvc.yaml): Defined a ReadWriteMany PersistentVolume (`slinky-storage-pv`) targeting host path `/mnt/storage` and a corresponding PersistentVolumeClaim (`slinky-storage-pvc`) within the `slurm` namespace.
3.  **Helm Chart Customization:**
    *   Updated [values.yaml](file:///home/khemi/workspace/ai_sandbox/values.yaml):
        *   Cleared out the complex and unused `sssd` configuration block (`sssd: {}`).
        *   Added volume mounts and volumes to the worker `nodesets`, making `slinky-storage-pvc` available at `/mnt/storage` inside the Slurm compute pods.
4.  **SSSD / LDAP Cleanup:**
    *   Deleted unused files (`Dockerfile`, `groups.ldif`, `sssd.conf`, `users.ldif`) that were previously used for LDAP integration.
5.  **Git Configuration & Storage Tracking:**
    *   Updated [.gitignore](file:///home/khemi/workspace/ai_sandbox/.gitignore): Set up rules to keep [storage/projects/project1](file:///home/khemi/workspace/ai_sandbox/storage/projects/project1) tracked as the core example, while ignoring all other dynamic projects (`project2`, `project3`), temporary checkpoints, python cache, and Kaggle cache files.
    *   Staged and committed the sample application files under [storage/projects/project1](file:///home/khemi/workspace/ai_sandbox/storage/projects/project1).

### 💡 Why This Design?
*   **Simplicity:** Running a custom OpenLDAP server and configuring SSSD client daemons on every container is error-prone and adds high overhead. Native Kubernetes volumes handle file sharing and user directory separation much more reliably for local development.
*   **Local Dev Fidelity:** Mapping the host storage directory directly allows developers to inspect job output, logs, and workspace files directly from their local IDE without SSH or container-exec commands.

### 🛠️ Verification Steps
To spin up the cluster and verify this storage isolation setup:

1.  **Boot the cluster:**
    ```bash
    kup
    ```
    *(This creates the Kind cluster using [kind-config.yaml](file:///home/khemi/workspace/ai_sandbox/kind-config.yaml) and deploys Slinky with the storage mounts).*

2.  **Check PersistentVolume and PersistentVolumeClaim status:**
    ```bash
    kubectl get pv,pvc -n slurm
    ```
    *Ensure both `slinky-storage-pv` and `slinky-storage-pvc` show status `Bound`.*

3.  **Confirm the mount inside a compute pod:**
    ```bash
    kstat
    ```
    Find a running slurmd worker pod name, then run:
    ```bash
    kubectl exec -n slurm -it <pod-name> -c slurmd -- ls -la /mnt/storage
    ```
    *Confirm that the project folders (`project1`, etc.) are visible.*

---
