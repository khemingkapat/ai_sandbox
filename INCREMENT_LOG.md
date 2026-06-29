# Slinky Migration: Project Increment Log

This file tracks every discrete increment made during the Slinky migration. Its goal is to keep the human lead (**Khem**) fully informed of design choices, modified files, and verification steps.

## [Increment 12] - 2026-07-06: Deploy slurm-bridge for Unified Pod Queueing

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Deploy the `slurm-bridge` to enable unified scheduling of Kubernetes pods via Slurm, ensuring interactive pods are queued and accounted for exactly like batch jobs.

### 📝 Key Changes & Files Modified

1.  **Slurm-Bridge Deployment:**
    *   Created `slurm-bridge-values.yaml`: Configured the bridge to manage the `workload` namespace and connect to the local `slurmrestd` API using a dedicated JWT token.
    *   Updated `scripts/start-slinky.sh`: Added the deployment sequence. Since `slurm-bridge` is a separate Helm chart requiring an active Slurm API token, the script now waits for `slurmctld`, generates a non-expiring JWT, stores it in a K8s secret, and installs the bridge.
2.  **Infrastructure Verification:**
    *   Updated `scripts/verify-infrastructure.sh`: Added Test 7 to deploy a test pod to the `workload` namespace and check if `slurm-bridge` attempts to intercept and schedule it into Slurm.

### 💡 Why This Design?
*   **Unified Queue:** Without `slurm-bridge`, standard Kubernetes pods bypass the Slurm scheduler completely. Deploying this chart bridges the gap, allowing data scientists to use standard K8s tools while enforcing Slurm's fairness and priority policies.
*   **Sequential Token Generation:** The bridge fundamentally requires an active `SLURM_JWT` to authenticate. It cannot be deployed purely declaratively via values.yaml; it requires dynamic token generation after the controller is up.

### 🛠️ Verification Steps
1.  **Run the verification script:** `./scripts/verify-infrastructure.sh`
    *(Check Test 7 for successful interception or warning if node annotations prevent scheduling).*

## [Increment 10] - 2026-06-28: Apptainer Integration & Traefik Bugfix

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Validate and integrate `apptainer-suid` with `proot` into the Slurm worker nodes to support rootless Apptainer execution within Kubernetes, and resolve a hidden Traefik file-watcher limit bug preventing proxy routing.

### 📝 Key Changes & Files Modified

1.  **Apptainer Worker Configuration:**
    *   Updated `scripts/build-custom-images.sh`: Added `apptainer`, `apptainer-suid`, and `proot` installation steps to the `slurmd-custom` image.
    *   Configured `apptainer.conf` to force the use of `proot` (`allow setuid = no`) to bypass Kubernetes unprivileged container restrictions on worker nodes.
2.  **Traefik Routing Fix:**
    *   Updated `scripts/start-slinky.sh`: Added a dynamic fix that increases the host `inotify.max_user_instances` limit to 8192 on all Kind nodes prior to portal deployment. This prevents Traefik from silently failing to watch the `dynamic-routes.yml` file due to "too many open files".
3.  **Project Tracking:**
    *   Updated `WORK_PACKAGES.md`: Marked WP3-1-6 (Apptainer batch validation) as completed (🟢).

### 💡 Why This Design?
*   **Rootless Apptainer in K8s:** Kubernetes strictly limits privileged operations. By injecting `proot` and disabling `setuid` in the Apptainer configuration, we achieve fully rootless container nesting without needing `--privileged` worker pods.
*   **Host-Level Inotify Limits:** Traefik's dynamic file provider relies heavily on `inotify`. Kind inherits host OS limits, which are often too low (default 128). Automatically increasing this limit in the startup script ensures Traefik functions reliably across environments.

### 🛠️ Verification Steps
1.  **Check Apptainer execution:** 
    Submit an interactive job from the portal and verify the generated `jupyterlab.err` shows it launching correctly.
2.  **Verify Traefik Routing:**
    Run `kubectl port-forward svc/portal -n slurm 8000:80` and ensure accessing `http://localhost:8000/...` correctly proxies into the JupyterLab container without a 404 error.


## [Increment 9] - 2026-06-28: Deploy Go Portal with Traefik Sidecar in Kind Cluster

*   **Author:** Jules (Async)
*   **Goal:** Migrate the Go portal from host-running to a containerized deployment within the Kind cluster, using a Traefik sidecar for dynamic routing.

### 📝 Key Changes & Files Modified

1.  **Kubernetes Manifests:**
    *   Created `portal-deployment.yaml`: Defines the `hpc-portal` Deployment and `portal` Service.
    *   Implemented the Sidecar pattern: `portal` container for the Go app and `traefik` container for the proxy.
    *   Configured shared `emptyDir` volume for dynamic Traefik route generation.
    *   Mounted `slinky-storage-pvc` for job log and app manifest access.
    *   Mounted `slurm-auth-jwt` secret for secure Slurm REST API communication.
2.  **Automation Scripts:**
    *   Updated `scripts/start-slinky.sh`: Added local Docker build, image loading into Kind, and manifest application steps to the core startup workflow.

### 💡 Why This Design?
*   **Local Development Parity:** Containerizing the portal ensures the development environment closely matches production.
*   **Sidecar for Dynamic Routing:** Using Traefik as a sidecar allows the portal to dynamically manage routes for interactive jobs (like Jupyter) by writing simple YAML files to a shared ephemeral volume, avoiding complex ingress controller reconfigurations.
*   **Security:** Leveraging Kubernetes Secrets for the JWT key ensures sensitive credentials are managed natively by the cluster.

### 🛠️ Verification Steps
1.  **Build the Portal:** `cd portal && go build ./...`
2.  **Run Startup Script:** `./scripts/start-slinky.sh`
3.  **Verify Deployment:** `kubectl get pods -n slurm -l app=hpc-portal`
    *(Confirm both containers are ready).*
4.  **Check Connectivity:**
    *   `kubectl port-forward svc/portal -n slurm 8080:8080` (UI access).
    *   `kubectl port-forward svc/portal -n slurm 8000:80` (Proxy access).

---

## [Increment 10] - 2026-07-02: Curated OCI Images for Interactive Workloads

*   **Author:** Jules (Async)
*   **Goal:** Provide specialized OCI container images for JupyterLab, Code-server, and Bash workloads to replace Apptainer SIF files, ensuring compatibility with the cluster's dynamic user resolution and storage model.

### 📝 Key Changes & Files Modified

1.  **Image Dockerfiles:**
    *   `images/jupyterlab/Dockerfile`: Based on `jupyter/scipy-notebook`, adds `libnss-extrausers` and a custom startup script.
    *   `images/codeserver/Dockerfile`: Based on `codercom/code-server`, adds `libnss-extrausers`.
    *   `images/bash/Dockerfile`: Minimal Ubuntu-based image with common CLI tools and `libnss-extrausers`.
2.  **Automation & Integration:**
    *   Created `scripts/build-oci-images.sh`: Builds all three interactive images and loads them into the Kind cluster.
    *   Updated `scripts/start-slinky.sh`: Integrated the image building and loading process into the cluster startup workflow.
3.  **Dynamic Configuration:**
    *   Implemented `images/jupyterlab/start-jupyter.sh` to allow the portal to inject `$ALLOCATED_PORT` and `$BASE_URL` for Traefik-ready routing.

### 💡 Why This Design?
*   **Performance & Flexibility:** Native OCI images are faster to launch and easier to customize than Apptainer SIF images within a Kubernetes environment.
*   **Unified Identity:** Including `libnss-extrausers` in all interactive images ensures they can resolve the same dynamic UIDs used by the Slurm daemons, maintaining strict storage isolation.
*   **Portal Compatibility:** Exposing port and base URL configuration in the Jupyter image prepares the system for the upcoming dynamic proxy routing feature.

### 🛠️ Verification Steps
1.  **Build and Load Images:** `./scripts/build-oci-images.sh`
2.  **Verify Cluster Integration:** Run `./scripts/start-slinky.sh` and ensure no `ImagePullBackOff` errors occur when interactive pods are launched.
3.  **Manual Test Pod:**
    ```bash
    kubectl apply -f test-interactive-pod.yaml
    kubectl exec -n slurm test-interactive-pod -- id user1
    ```
    *(Confirm UID 1001 is resolved and `/mnt/storage` is writable).*
## [Increment 11] - 2026-07-05: Adopt slurm-client Library in Go Portal

*   **Author:** Jules (Async)
*   **Goal:** Replace manual HTTP calls to the Slurm REST API with the official `slurm-client` Go library to improve type safety and maintainability.

### 📝 Key Changes & Files Modified

1.  **Dependency Management:**
    *   Updated `portal/go.mod`: Added `github.com/SlinkyProject/slurm-client` and `k8s.io/utils/ptr`.
2.  **Portal Backend Refactoring:**
    *   Updated `portal/main.go`:
        *   Replaced all manual `http.NewRequest` calls to Slurm REST API with `slurmClient.List`, `slurmClient.Create`, `slurmClient.Get`, and `slurmClient.Delete`.
        *   Refactored `apiUserJobs`, `apiClusterStatus`, `submitJob`, `jobStatus`, and `cancelJob` handlers to instantiate a fresh `slurm-client` per request using the user's JWT token.
        *   Removed legacy Slurm API structs (`SlurmJob`, `SlurmJobResponse`, etc.) in favor of typed structures from the `slurm-client` library.
        *   Eliminated hardcoded `/slurm/v0.0.42/` paths in the main job/node handlers.

### 💡 Why This Design?
*   **Type Safety:** Using a generated client library reduces the risk of errors from manual JSON unmarshaling and ensures compatibility with the Slurm REST API schema.
*   **Security & Isolation:** Instantiating a new client per request with the user's own token ensures that all Slurm operations are performed with the correct user identity and permissions, maintaining strict multi-user isolation.
*   **Maintainability:** Removing boilerplate HTTP code and hardcoded version strings makes the portal easier to update for future Slurm versions.

### 🛠️ Verification Steps
1.  **Compile the portal:**
    ```bash
    cd portal
    go build ./...
    ```
    *(Confirm successful compilation without errors).*

---

## [Increment 10] - 2026-06-30: Manifest Schema Migration (type + OCI image fields)

*   **Author:** Jules (Async)
*   **Goal:** Migrate the app manifest schema to support both OCI container images (for interactive workloads) and SIF images (for batch workloads).

### 📝 Key Changes & Files Modified

1.  **Backend Logic:**
    *   Updated `portal/main.go`:
        *   Expanded `AppManifest` struct with `Type` ("interactive" or "batch") and `Image` (OCI ref) fields.
        *   Enhanced `scanApps()` with validation: defaults `Type` to "batch" for backward compatibility and ensures "interactive" apps have an OCI image defined.
2.  **Application Manifests:**
    *   Updated `storage/common/software/jupyterlab/manifest.yaml`: Converted to `type: interactive` using an OCI image ref.
    *   Updated `storage/projects/project1/software/hello/manifest.yaml`: Explicitly set `type: batch`.

### 💡 Why This Design?
*   **Dispatcher Readiness:** Providing a clear type discriminator enables the portal to route jobs either to Kubernetes-native OCI pods (interactive) or Slurm-based Apptainer execs (batch).
*   **Backward Compatibility:** Defaulting the type to "batch" ensures that existing Apptainer-only manifests continue to work without modification.

### 🛠️ Verification Steps
1.  **Compile the portal:**
    ```bash
    cd portal
    go build ./...
    ```
    *(Confirm successful compilation without errors).*
2.  **Verify Manifests:**
    *(Confirm that JupyterLab and Hello manifests now contain the `type` field and JupyterLab has the `image` ref).*

---

## [Increment 8] - 2026-06-24: Dynamic User Resolution via libnss-extrausers

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Implement dynamic user resolution across Slurm pods using `libnss-extrausers` and a shared volume mount, enabling multi-user job submission and isolation without manual provisioning.

### 📝 Key Changes & Files Modified

1.  **Custom Image Generation:**
    *   Created [scripts/build-custom-images.sh](scripts/build-custom-images.sh): Shell script to compile custom `slurmctld`, `slurmrestd`, and `slurmd` Docker images with `libnss-extrausers` packages and update `/etc/nsswitch.conf` inside the containers.
2.  **Helm Volume Mounting:**
    *   Updated [values.yaml](values.yaml): Configured `extrausers-vol` volumes and `volumeMounts` mapping `/mnt/storage/common/etc` to `/var/lib/extrausers/` across all Slurm pods (controller, restapi, worker nodes).
3.  **Portal Dynamic Mapping:**
    *   Updated [portal/main.go](portal/main.go): Implemented `registerUserExtrausers` helper function inside `loginAction` to atomically register users inside the shared `/mnt/storage/common/etc/passwd` and `group` files upon login.
4.  **Verification Script Update:**
    *   Updated [scripts/test_api_isolation.py](scripts/test_api_isolation.py): Modified the Python test script to dynamically register users in the shared passwd/group folders, verifying job resolution and filesystem isolation boundaries.

### 💡 Why This Design?
*   **Decoupled & Native:** Avoids complex, high-overhead SSSD/LDAP infrastructure for prototyping while matching the exact numeric UID/GID permission boundaries of the production system.
*   **Zero-Overhead Scaling:** Adding new users is a simple, atomic write to a text file that updates all nodes instantly.

### 🛠️ Verification Steps
To execute the dynamic isolation test:
1.  **Run the verification script:**
    ```bash
    nix-shell -p kubectl -p python3 --run "python3 scripts/test_api_isolation.py"
    ```
    *(Confirm both test users are registered, jobs run under UIDs 1001/1002, and directory cross-writes are blocked).*


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
