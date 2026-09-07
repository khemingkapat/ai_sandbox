# Slinky Migration: Project Increment Log

This file tracks every discrete increment made during the Slinky migration. Its goal is to keep the human lead (**Khem**) fully informed of design choices, modified files, and verification steps.

## [Increment 29] - 2026-09-07: WP3-1-8-3 Traefik Ingress TLS & Security Headers

*   **Author:** Jules (Async)
*   **Goal:** Secure Traefik ingress by terminating HTTPS on port 443 with self-signed TLS certificates, automatically enforcing HTTP-to-HTTPS redirects from port 80 to 443, and injecting standard security headers (`nosniff`, frame protection, XSS protection).

### 📝 Key Changes & Files Modified

1.  **Certificate Generation Script (`scripts/generate-certs.sh`):**
    *   Created `scripts/generate-certs.sh`: Shell script that uses `openssl` to generate a 2048-bit RSA private key and self-signed certificate valid for 365 days with SANs: `localhost`, `127.0.0.1`, `portal`, `portal.slurm.svc.cluster.local`, and `*.sandbox.local`.
    *   Generates or updates Kubernetes Secret `traefik-tls-cert` in namespace `slurm` (`--from-file=tls.crt=... --from-file=tls.key=...`).
2.  **Traefik Dynamic Security ConfigMap (`k8s/traefik-security-configmap.yaml`):**
    *   Created `k8s/traefik-security-configmap.yaml`: ConfigMap `traefik-security-config` in namespace `slurm` containing dynamic Traefik file configuration.
    *   Configures `tls.stores.default.defaultCertificate` referencing `/etc/traefik/certs/tls.crt` and `/etc/traefik/certs/tls.key`.
    *   Defines middleware `security-headers` under `http.middlewares.security-headers.headers` with `contentTypeNosniff: true`, `browserXssFilter: true`, and `customFrameOptionsValue: "SAMEORIGIN"`.
3.  **Deployment & Service Hardening (`k8s/portal-deployment.yaml`):**
    *   Updated `traefik` container in `hpc-portal` Deployment:
        *   Exposed container port `name: websecure, containerPort: 443`.
        *   Configured Traefik CLI arguments for `websecure` entrypoint (:443), TLS enablement (`--entrypoints.websecure.http.tls=true`), default middleware (`security-headers@file`), HTTP-to-HTTPS redirection (`web` -> `websecure`), and security file provider (`--providers.file.directory=/etc/traefik/security`).
        *   Mounted volumes `traefik-certs` at `/etc/traefik/certs` (readOnly) and `traefik-security` at `/etc/traefik/security` (readOnly).
    *   Updated Pod volumes sourcing Secret `traefik-tls-cert` and ConfigMap `traefik-security-config`.
    *   Updated Service `portal`: Added port `name: https, port: 443, targetPort: 443`.
4.  **Cluster Startup Integration (`scripts/start-slinky.sh`):**
    *   Integrated `./scripts/generate-certs.sh` execution and `kubectl apply -f k8s/traefik-security-configmap.yaml` into the cluster bootstrap sequence.

### 💡 Why This Design?
*   **Decoupled Security Management:** Leveraging Traefik's dynamic file provider mounted via a Kubernetes ConfigMap decouples TLS store configuration and middleware security policy definitions from application source code.
*   **Defense-in-Depth:** Mandatory HTTPS redirection and standard security headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `X-XSS-Protection`) protect student sessions, interactive notebooks, and terminal proxies against credential eavesdropping, MIME sniffing, and clickjacking attacks.

### 🛠️ Verification Steps
1.  **Script & YAML Syntax Verification:**
    *   Ran `bash -n scripts/generate-certs.sh` and `bash -n scripts/start-slinky.sh` (passed without errors).
    *   Validated YAML formatting and key structures for `k8s/traefik-security-configmap.yaml` and `k8s/portal-deployment.yaml`.
2.  **Certificate & SANs Verification:**
    *   Executed certificate generation logic using `openssl req` and verified `X509v3 Subject Alternative Name` output contains `DNS:localhost, IP Address:127.0.0.1, DNS:portal, DNS:portal.slurm.svc.cluster.local, DNS:*.sandbox.local` and 365-day validity.
3.  **Scope Guardrails:**
    *   Confirmed non-target files (`portal/main.go`, `portal/session_manager.go`, `k8s/values.yaml`, `k8s/kind-config.yaml`, `k8s/network-policies/*`) remained untouched.

---

## [Increment 28] - 2026-08-24: WP3-1-7 Central Shared Storage, Curated Datasets & Model Hub Repository

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Implement the central shared storage architecture (`/mnt/storage`), admin-curated read-only model hub, curated datasets repository, ephemeral scratch space with POSIX sticky bit, and dual-tier container runtime environment contracts across interactive Kubernetes pods and Slurm batch jobs.

### 📝 Key Changes & Files Modified

1.  **Storage Layout & POSIX Permissions (`scripts/init-storage.sh`):**
    *   Provisioned unified directory hierarchy: `/mnt/storage/{models/huggingface/hub,models/torch,models/ollama}`, `/mnt/storage/datasets/{kaggle,vision,nlp}`, `/mnt/storage/scratch`, `/mnt/storage/common/{etc,software}`, `/mnt/storage/registry`, and `/mnt/storage/projects/{project1,project2,project3}`.
    *   Enforced permissions: `root:root 755` for shared catalogs, `root:root 1777` with sticky bit for scratch space, and strict `<uid>:<uid> 700` for private student workspaces.
2.  **Model & Dataset Seeding Tooling:**
    *   Created `scripts/seed-models.sh`: Populates central read-only models in `/mnt/storage/models/` with `--test-mode` support for lightweight CPU fixtures (`BAAI/bge-small-en-v1.5`, `Qwen/Qwen2.5-0.5B-Instruct`, PyTorch ResNet, Ollama manifests).
    *   Created `scripts/seed-datasets.sh`: Populates benchmark starter datasets in `/mnt/storage/datasets/` (MNIST, CIFAR-10, IMDb, SQuAD, Titanic).
    *   Created `scripts/seed-kaggle.sh`: Admin helper to download/unpack course Kaggle competitions and public datasets.
3.  **Scratch Garbage Collection & Storage Auditing Tooling:**
    *   Created `scripts/clean-scratch.sh`: Automated purge script for stale scratch files older than retention threshold (default 7 days) with `--dry-run` support.
    *   Created `scripts/audit-storage.sh`: Analyzes storage utilization per project, checks Slurm associations, and scans for duplicate dataset directories across workspaces.
4.  **Container Environment Contract Injection:**
    *   Updated `portal/session_manager.go`: Injected `HF_HOME`, `HF_HUB_CACHE`, `TORCH_HOME`, `TRANSFORMERS_OFFLINE`, `KAGGLE_CONFIG_DIR`, `KAGGLEHUB_CACHE`, and `TMPDIR` into interactive session Pod definitions.
    *   Updated `portal/handlers.go`: Injected identical storage environment variables into `#SBATCH` batch script templates and Slurm REST API job descriptors.
5.  **Hardening, Automation & Verification Test Suite:**
    *   Created `scripts/verify-storage.sh`: Automated test runner executing all 6 acceptance tests end-to-end against Kind/storage.
    *   Created `k8s/clean-scratch-cronjob.yaml`: Automated daily Kubernetes CronJob to purge expired files from `/mnt/storage/scratch`.
    *   Hardened `.gitignore` and extracted `templates/projects/project1/`: Completely decoupled runtime student workspaces (`/storage/projects/`) from host git tracking, eliminating permission collisions on developer machines.
    *   Safeguarded `portal/handlers.go`: Added traversal depth guardrails to soft quota check to prevent HTTP handler latency spikes and documented Layer 2 storage quota architecture.
    *   Updated `scripts/start-slinky.sh`: Integrated storage initialization, model/dataset seeding, and scratch cleanup CronJob directly into cluster bootstrap.
    *   Created `docs/WP3-1-7_VERIFICATION.md`: Established comprehensive test plan and verified all 6 acceptance scenarios.
    *   Updated `docs/WORK_PACKAGES.md`: Marked WP3-1-7 as completed (🟢 Done).

### 💡 Why This Design?
*   **Tampering & Corruption Immunity:** Curating baseline models and datasets under `root:root 755` prevents race-condition deadlocks during concurrent multi-user student runs and eliminates risks of shared cache poisoning.
*   **Dual-Tier Flexibility:** Redirecting `HF_HUB_CACHE` to the shared read-only library while pointing `HF_HOME` to the private student workspace allows students to load standard models instantly with 0 extra disk usage, while retaining the freedom to download custom models into their private quota.
*   **Multi-Tenant Ephemeral Scratch:** World-writable sticky bit (`1777`) on `/mnt/storage/scratch` allows students to run high-throughput temp workloads without leaking files or allowing classmates to delete each other's temporary artifacts.

### 🛠️ Verification Steps
Executed automated test runner `scripts/verify-storage.sh` with 100% pass rate across all 6 scenarios:
1.  **Test 1 (Directory Layout & Permissions):** Validated `/mnt/storage/models` (755), `/mnt/storage/datasets` (755), `/mnt/storage/scratch` (1777), and `/mnt/storage/projects/*` (700). Verified student cannot tamper with models/datasets.
2.  **Test 2 (Dual-Tier Model Hub):** Seeded lightweight test model snapshot via `seed-models.sh --test-mode` and verified model files are discovered, readable, and write-protected.
3.  **Test 3 (Datasets & Kaggle Isolation):** Populated sample datasets via `seed-datasets.sh --test-mode` and confirmed unprivileged users are blocked from reading private `.kaggle/kaggle.json`.
4.  **Test 4 (Ephemeral Scratch Sticky Bit):** Created scratch file as UID 1001; confirmed deletion attempt by other user is denied by kernel sticky bit; confirmed cleanup via `clean-scratch.sh --dry-run`.
5.  **Test 5 (Environment Contract):** Compiled Go portal (`go build ./...`) without errors; verified interactive Pod and batch `#SBATCH` templates inject storage environment variables.
6.  **Test 6 (Storage Audit):** Executed `audit-storage.sh` and confirmed accurate directory breakdown and duplicate candidate scanning.

---

## [Increment 27] - 2026-08-23: WP3-1-6 Container Environment & Dual-Path Image Delivery Pipeline

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Implement and verify the complete dual-path container execution pipeline: in-cluster OCI distribution registry with on-demand containerd pulling for interactive workloads, and Apptainer SquashFS direct NFS streaming for batch workloads with read-only root security boundaries.

### 📝 Key Changes & Files Modified

1.  **In-Cluster OCI Distribution Registry (`registry:2`):**
    *   Created `k8s/registry.yaml`: Defined `registry-pv` (20Gi hostPath mapped to `/mnt/storage/registry`), `registry-pvc`, `Deployment` running `registry:2` on `kind-control-plane` with `hostPort: 5000`, and `registry` ClusterIP Service on port 5000 in namespace `slurm`.
    *   Updated `k8s/kind-config.yaml`: Added `extraPortMappings` for `5000:5000` on the control-plane node to route host Docker pushes directly to the in-cluster registry, and enabled `containerdConfigPatches` for certs.d.
2.  **Containerd Endpoint Discovery & Plain HTTP Registry Mirroring:**
    *   Updated `scripts/start-slinky.sh`: Integrated registry deployment, health check polling, and automated `/etc/containerd/certs.d/localhost:5000/hosts.toml` provisioning across all Kind cluster nodes to mirror `localhost:5000` to `http://kind-control-plane:5000` over the internal Docker network.
    *   Updated `scripts/build-oci-images.sh`: Configured automated building, tagging (`localhost:5000/...`), and pushing of `interactive-jupyter`, `interactive-codeserver`, and `interactive-bash` directly to the local in-cluster registry.
3.  **Application Catalog Alignment:**
    *   Updated `storage/common/software/jupyterlab/manifest.yaml`: Set `image: "localhost:5000/interactive-jupyter:latest"`.
    *   Updated `storage/common/software/codeserver/manifest.yaml`: Set `image: "localhost:5000/interactive-codeserver:latest"`.
    *   Updated `storage/common/software/bash/manifest.yaml`: Set `image: "localhost:5000/interactive-bash:latest"`.
4.  **Batch Apptainer Pipeline & Shared Storage Hardening:**
    *   Built `storage/common/software/python.sif` from `storage/projects/project1/software/hello/python.def`.
    *   Hardened directory permissions on `/mnt/storage/common/software` to `root:root` `755` (directories) and `644` (files).
    *   Updated `docs/WP3-1-6_VERIFICATION.md` and `docs/WORK_PACKAGES.md` with complete passing verification status.

### 💡 Why This Design?
*   **Dual-Path Symmetry:** Interactive workloads get fast, on-demand OCI layer pulling via local cluster networking without maintenance-heavy Pre-pull DaemonSets. Batch workloads get zero-overhead sequential SquashFS block streaming from shared NFS storage directly into the Linux page cache.
*   **Tampering Immunity:** Restricting shared software directories to `root:root` `755`/`644` prevents cross-tenant poisoning or accidental deletion of baseline tools by student jobs.

### 🛠️ Verification Steps
1.  **Test 1 (OCI Registry & Host Push):** Pushed `localhost:5000/interactive-jupyter:latest`; queried `/v2/_catalog` and confirmed all 3 interactive images listed.
2.  **Test 2 (Interactive On-Demand Pull):** Launched test session pod from `localhost:5000/interactive-jupyter:latest`; containerd pulled layers on demand and pod reached `Ready`.
3.  **Test 3 (Batch Apptainer SIF):** Submitted `sbatch` job executing Python inside `python.sif` over `/mnt/storage`; executed with exit code 0 (`Apptainer batch execution SUCCESS on Python 3.10.21`).
4.  **Test 4 (Security & Tampering):** Attempted write to `python.sif` as unprivileged student user UID 1001; operation returned `Permission denied` and image binary integrity remained intact.

---

## [Increment 26] - 2026-08-17: Interactive Workbenches (VS Code Server & TTYD) Ingress & Launch Verification

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Enable interactive browser-based VS Code Server and TTYD web terminal workbenches with dynamic Traefik prefix-stripping reverse proxy routing.

### 📝 Key Changes & Files Modified

1.  **OCI Container Images & Entrypoint Scripts:**
    *   `images/codeserver/Dockerfile` & `images/codeserver/start-codeserver.sh`: Containerized `code-server` with dynamic extrausers UID resolution, binding to internal port `8888` at workspace `/mnt/storage/projects/<project>`.
    *   `images/bash/Dockerfile` & `images/bash/start-bash.sh`: Containerized `ttyd` interactive terminal with dynamic user resolution, web-ready terminal emulation, and root path compatibility.
2.  **App Manifests:**
    *   `storage/common/software/codeserver/manifest.yaml`: Registered `codeserver` interactive workbench application in common software catalog.
    *   `storage/common/software/bash/manifest.yaml`: Registered `bash` interactive shell application in common software catalog.
3.  **Dynamic Ingress & StripPrefix Routing:**
    *   `portal/session_manager.go`: Dynamically generates Traefik router specifications in `/etc/traefik/dynamic/session-<session_id>.yaml` configured with `stripPrefix` middleware to cleanly forward subpath requests (`/:user/:app/:session_id/`) to root `/` on workload pods.
    *   `portal/main.go`: Configured Echo reverse proxy wildcard group `/:user/:app` forwarding to Traefik on port `80` with full WebSocket tunneling support.
    *   `portal/handlers.go`: Normalized session proxy paths to include trailing slashes to prevent relative redirect path corruption.

### 💡 Why This Design?
*   **Subpath Isolation:** Interactive applications such as `code-server` and `ttyd` serve relative assets (`./_static/...`) and expect requests at their root context `/`. Dynamic Traefik prefix stripping allows multiple concurrent user sessions to share single-port ingress on `:8080` without path collision or container reconfiguration.

### 🛠️ Verification Steps
1.  **Launch Verification:** Successfully launched both **VS Code Server** and **Interactive Shell (TTYD)** from the web portal dashboard, verified active registration in Slurm (`squeue`), and confirmed browser UI accessibility through Traefik proxy.
2.  **Scope Boundary / Pending:** We have verified that the VS Code server and TTY interactive shell can be launched and reached via the web portal. Detailed validation for multi-tenant access control boundaries, filesystem isolation under active processes, and network security policies remains pending for subsequent test phases.

---

## [Increment 25] - 2026-08-17: Slurm-Bridge Pod Attribution & Portal Interactive Routing

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Enable strict multi-tenant Slurm job accounting and partition routing for Kubernetes interactive pods spawned from the HPC portal, and fix Traefik proxy port mappings.

### 📝 Key Changes & Files Modified

1.  **Slurm-Bridge Pod Annotations:**
    *   Updated `portal/session_manager.go`: Injected `slurmjob.slinky.slurm.net/job-name`, `slurmjob.slinky.slurm.net/partition` (`interactive`), `slurmjob.slinky.slurm.net/account` (`project`), and `slurmjob.slinky.slurm.net/user-id` (`username`) into interactive pod metadata.
    *   Updated `portal/handlers.go`: Propagated dynamic form parameters and custom Slurm resource arguments to `SessionManager.CreateSession()`.
2.  **Reverse Proxy Endpoint Alignment:**
    *   Updated `portal/handlers.go`: Corrected session status URLs to use host-accessible port `8080` for JupyterLab proxy endpoints.

### 💡 Why This Design?
*   **Unified Attribution:** Using standard `slurmjob.slinky.slurm.net/*` annotations ensures that `slurm-bridge` intercepting pods in the `workload` namespace registers them directly against the user's Slurm account and QOS policies rather than generic root accounts.

### 🛠️ Verification Steps
1.  **Launch Interactive Session:** Logged into portal as `user1`, launched JupyterLab on partition `interactive`.
2.  **Verify Slurm Queue:** Verified via `squeue` that the pod appears as an active Slurm job with account `project1` and user `user1`.

---

## [Increment 24] - 2026-08-17: QoS Memory Limit Unit Fix & Demo User Provisioning

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Fix silent sacctmgr memory unit parsing errors during QoS creation and provide automated provisioning for demo student users.

### 📝 Key Changes & Files Modified

1.  **QoS Definition Fix:**
    *   Updated `scripts/setup-accounting.sh`: Changed unitless integer values (e.g., `16384`) to standard gigabyte notation (`16G`, `64G`, `32G`) across all QoS entries (`interactive_qos`, `batch_cpu_qos`, `batch_gpu_qos`, `inference_qos`).
    *   Added Admin role grants and `slurm-bridge` deployment rollout restart to ensure permissions refresh cleanly.
2.  **Demo User Provisioning Automation:**
    *   Created `scripts/seed-demo-users.sh`: Automated registration of student accounts (`project1`, `project2`, `project3`), users (`user1`–`user4`), QoS grants, and Linux extrausers entries.
    *   Updated `storage/common/etc/group`: Synchronized group mappings for student UIDs.

### 💡 Why This Design?
*   **Syntax Reliability:** Slurm's `sacctmgr` treats un-suffixed integer values for memory as megabytes in some contexts or rejects them outright; standardizing on explicit unit identifiers (`G`) guarantees correct limit enforcement.
*   **Reproducible Staging:** Having a single idempotent script (`seed-demo-users.sh`) ensures rapid setup of consistent multi-tenant test states.

### 🛠️ Verification Steps
1.  **Verify QoS Limits:** Ran `sacctmgr show qos format=Name,Priority,MaxTRESPerJob%-40` and confirmed `interactive_qos` shows `cpu=4,mem=16G`.
2.  **Negative Fencing Test:** Submitted an 8-CPU job to `interactive` partition; confirmed Slurm placed it in `PENDING` state with `(QOSMaxCpuPerJobLimit)`.

---

## [Increment 23] - 2026-08-17: Slurm Managed-Node Tolerations & Partition Policy Hardening

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Ensure cluster infrastructure services are tolerant of Slinky managed-node taints and solidify partition resource fencing in CRD and Helm values.

### 📝 Key Changes & Files Modified

1.  **Toleration for Dedicated Compute Nodes:**
    *   Updated `k8s/mariadb.yaml`, `k8s/portal-deployment.yaml`, `k8s/slurm-bridge-values.yaml`, and `k8s/values.yaml`: Added `slinky.slurm.net/managed-node:NoExecute` tolerations across all controller, REST API, MariaDB, Portal, and Slurm-Bridge components.
2.  **Partition Fencing Declarations:**
    *   Updated `k8s/slurm-cluster.yaml` and `k8s/values.yaml`: Standardized `PriorityTier` and `MaxTRESPerJob` constraints for `interactive`, `batch-cpu`, `batch-gpu`, and `inference` partitions.

### 💡 Why This Design?
*   **Node Stability:** Compute nodes labeled/tainted as Slinky managed nodes will evict pods lacking tolerations; adding explicit tolerations to core infrastructure prevents cluster service disruption during node labeling.

### 🛠️ Verification Steps
1.  **Cluster Health:** Ran `kubectl get pods -n slurm` and verified MariaDB, controller, and portal pods remain Ready on tainted worker nodes.

---

## [Increment 22] - 2026-07-14: WP3-1-5 Scheduling Policies and Resource Fencing

*   **Author:** Jules (Async)
*   **Goal:** Configure scheduling policies including fair-share algorithm, accounting backend with MariaDB StatefulSet and slurmdbd Deployment, and the four student partitions with strict resource fencing limits.

### 📝 Key Changes & Files Modified

1.  **Slurm Database Backend Deployment:**
    *   Created `helm/slurm/templates/mariadb-statefulset.yaml`: Defined MariaDB StatefulSet, Service, and secret definitions, dynamically integrated with the accounting storage configuration.
    *   Created `helm/slurm/templates/slurmdbd-deployment.yaml`: Defined slurmdbd Deployment, Service, and ConfigMap definitions to communicate with MariaDB and slurmctld.
2.  **Slurm Fair-Share and Partition Configuration:**
    *   Created `helm/slurm/config/slurm.conf`: Configured `PriorityType=priority/multifactor`, `PriorityWeightFairshare=10000`, `AccountingStorageType=accounting_storage/slurmdbd`, and defined the four partitions (`interactive`, `batch-cpu`, `batch-gpu`, `inference`) with `PreemptMode=OFF` and resource fencing (`MaxTRESPerJob`) matching exact Capacity Planning constraints.
    *   Modified `helm/slurm/values.yaml`: Enabled the `accounting` block, configured fair-share under `controller.extraConf`, and defined the four partitions with respective PriorityTiers and `MaxTRESPerJob` constraints.
3.  **Documentation Tracking:**
    *   Updated `docs/WORK_PACKAGES.md`: Marked WP3-1-5 as completed (🟢 Done) and added comprehensive references to Capacity Planning and the Increment Log.

### 💡 Why This Design?
*   **Fair Sharing:** Native Multifactor Fair-Share scheduling ensures equitable resource distribution among students.
*   **Volatile Memory Protection:** Disabling preemption across partitions prevents sudden termination of active student notebooks (avoiding state loss in Jupyter/VS Code), while strict resource fencing limits (`MaxTRESPerJob`) guarantee constant interactive GPU headroom.
*   **Operator Coexistence:** Seamlessly packages MariaDB and slurmdbd into Slinky's Helm templates to ensure clean manifest compilation and linter validation out of the box.

### 🛠️ Verification Steps
1.  **Syntactic Validation:**
    *   Ran `helm lint helm/slurm` to verify chart syntax (0 failures).
    *   Ran `helm template helm/slurm` to successfully render all manifests.

## [Increment 21] - 2026-07-12: Core slurm-operator and NodeSet Deployment

*   **Author:** Jules (Async)
*   **Goal:** Separate the Slurm system state from student storage by provisioning slurm-state-pv/pvc, and define the SlurmCluster custom resource with slurmd-cpu and slurmd-gpu NodeSets to support local partition routing tests.

### 📝 Key Changes & Files Modified

1.  **Storage Orchestration Layout:**
    *   Updated `k8s/pv-pvc.yaml`: Appended `slurm-state-pv` (5Gi hostPath mapped to `/mnt/slurm-state`) and the matching `slurm-state-pvc` (5Gi manual storage claim) to explicitly isolate Slurm state saving from student storage (`slinky-storage-pvc`).
2.  **Slinky SlurmCluster Definition:**
    *   Created `k8s/slurm-cluster.yaml`: Defined `SlurmCluster` custom resource under the `slurm` namespace with two mock NodeSets (`slurmd-cpu` and `slurmd-gpu`) to support local partition routing tests. Mounts `slurm-state-pvc` to the `slurmctld` pod specification for its state persistence.

### 💡 Why This Design?
*   **Storage Isolation:** Separating the Slurm controller system state (`slurm-state-pvc`) from the student storage (`slinky-storage-pvc`) prevents user quota exhaustion or workspace instability from crashing the cluster scheduler or controller.
*   **Routing Fidelity:** Provisioning two distinct NodeSets (`slurmd-cpu` and `slurmd-gpu`) under `nodeSets` in `SlurmCluster` allows testing of partition routing policies locally.

### 🛠️ Verification Steps
1.  **YAML Syntax Validation:**
    *   Verified `k8s/slurm-cluster.yaml` and `k8s/pv-pvc.yaml` parse successfully using standard Python YAML libraries.
2.  **Restricted File Audit:**
    *   Audited files modified and confirmed that `k8s/values.yaml`, `k8s/slurm-bridge-values.yaml`, and `k8s/kind-config.yaml` remain unmodified.
## [Increment 21] - 2026-07-11: Update Slinky Deployment and Verification Scripts

*   **Author:** Jules (Async)
*   **Goal:** Transition Slinky deployment to a fully declarative model using the new `SlurmCluster` CRD, and update the verification suite to dynamically target NodeSet worker pods.

### 📝 Key Changes & Files Modified

1.  **Deployment Orchestration:**
    *   Updated `scripts/start-slinky.sh`:
        *   Removed legacy `helm install slurm` command.
        *   Added explicit wait for `slurm-operator-controller-manager` deployment to be available before applying the CRD.
        *   Applied declarative `k8s/slurm-cluster.yaml` manifest.
        *   Updated wait condition for slurmctld to use operator-managed label selectors (`-l app.kubernetes.io/name=slurmctld`).
2.  **Infrastructure Verification:**
    *   Updated `scripts/verify-infrastructure.sh`:
        *   Modified Test 6 (Multi-User Storage Isolation) to dynamically query NodeSet slurmd worker pod names via `kubectl` rather than using hardcoded `slurm-worker-slinky-0` or `slurm-worker-slinky-1` names.
        *   Fixed syntax issues in Test 7.

### 💡 Why This Design?
*   **Declarative Standard:** By using `kubectl apply -f k8s/slurm-cluster.yaml` instead of Helm, we align with the production Kubernetes-native resource orchestration paradigm.
*   **Robust Worker Discovery:** Querying pod names dynamically via labels makes the verification script resilient to changes in cluster topology, naming schemas, or node scaling.

### 🛠️ Verification Steps
1.  Check shell scripts for valid syntax using `bash -n`.
2.  Verify correct CRD application and label selector updates in scripts.

---

## [Increment 20] - 2026-07-10: Tutorial Placement Research - Use Cases & Trade-offs

*   **Author:** Jules (Async)
*   **Goal:** Expand the tutorial feasibility research with user-centric scenarios and a simplified trade-off analysis to guide placement decisions.

### 📝 Key Changes & Files Modified

1.  **Research Documentation:**
    *   Updated `docs/interactive_tutorial_feasibility.md`: Added "👥 Use Case Scenarios" and "⚖️ Trade-off Analysis (Simple Terms)" sections.

### 💡 Why This Design?
*   **User-Centric Perspective:** Moves beyond technical feasibility to consider the student experience, balancing the need for low-friction onboarding (Central Portal) with the requirement for full cluster access (Localized Sandbox).
*   **Accessible Language:** Uses simple wording to ensure the trade-offs are understandable by stakeholders who may not be deeply technical.

### 🛠️ Verification Steps
1.  Verify `docs/interactive_tutorial_feasibility.md` renders correctly and contains the new sections.

---

## [Increment 19] - 2026-07-08: Telemetry and Observability Research Extension

*   **Author:** Jules (Async)
*   **Goal:** Extend the telemetry research to evaluate native Slurm REST API vs. Prometheus exporters and design a Kubernetes-native observability stack for the AI Sandbox.

### 📝 Key Changes & Files Modified

1.  **Observability Research:**
    *   Updated [docs/slurm_info_exchange_research.md](docs/slurm_info_exchange_research.md):
        *   Added a researched comparison between the Slurm REST API and the Prometheus `slurm_exporter`.
        *   Recommended a transition to the native Slurm OpenMetrics plugin (via `slurmrestd`) to reduce architectural complexity.
        *   Designed a standard observability stack using Prometheus, Grafana, and Alertmanager with a focus on GPU utilization and node health.
        *   Proposed a Portal integration strategy for student-facing metrics using Prometheus queries.
        *   Added a consolidated reference list with 5+ citations.

### 💡 Why This Design?
*   **Minimalist Architecture:** Leveraging the Slurm REST API's native metrics capabilities avoids the need for maintaining a separate exporter daemon, aligning with the "Edit Source, Not Artifacts" and "Reduced Dependencies" principles.
*   **Unified Security:** Sharing the same JWT-based authentication for both the portal and the metrics stack simplifies credential management within the cluster.
*   **Student Empowerment:** Providing real-time resource usage and quota tracking directly in the portal improves transparency and helps students manage their compute budgets effectively.

### 🛠️ Verification Steps
1.  **Document Verification:**
    *   Confirmed all new sections exist in `docs/slurm_info_exchange_research.md`.
    *   Validated the Mermaid diagram syntax.
    *   Verified that original research content was preserved.
## [Increment 18] - 2026-07-06: Job Definition Catalog & Capacity Research

*   **Author:** Jules (Async)
*   **Goal:** Provide detailed functional and resource justifications for the profiled workloads to bridge the gap between platform capabilities and capacity planning numbers.

### 📝 Key Changes & Files Modified

1.  **Capacity Planning Extension:**
    *   Updated `docs/CAPACITY_PLANNING.md`:
        *   Added "🔧 Job Definition Catalog" section defining 7 core job types (LLM Inference, Vector DB, Interactive Prototyping, Fine-Tuning, Distributed Training, Data Pipeline, RAG Stack).
        *   Researched and documented concrete resource requirements (CPU, RAM, VRAM, Storage) for each job type, specifically detailing quantized model sizes for Llama 3.1, Phi-3, and Mistral.
        *   Added a "Job Definition Ref" column to the "Workload Profile Catalog" table to cross-reference detailed definitions.

### 💡 Why This Design?
*   **Capability-Driven Planning:** Linking resource numbers to specific user actions (e.g., "fine-tuning a 7B model via QLoRA") provides better context for administrators than raw numbers alone.
*   **Evidence-Based Limits:** Backing resource allocations with researched benchmarks (e.g., Ollama model tags and Qdrant sizing guides) ensures the platform is sized correctly for the intended academic workloads.

### 🛠️ Verification Steps
1.  Verify documents render properly as markdown.
2.  Ensure anchor links in the workload table correctly navigate to job definitions.
3.  Run `./scripts/verify-isolation.sh` to ensure repository integrity.

---

## [Increment 17] - 2026-07-06: Extended Environment Assessment & Slinky Justification

*   **Author:** Jules (Async)
*   **Goal:** Provide a researched justification for the Slinky architecture and map platform workload modes to specific Slinky/K8s components.

### 📝 Key Changes & Files Modified

1.  **Environment Assessment Update:**
    *   Updated [ENVIRONMENT_ASSESSMENT.md](./ENVIRONMENT_ASSESSMENT.md):
        *   Added "🏗️ Why Slinky for a University AI Sandbox" section with researched justification across four pillars: University Sandbox Problem Space, Why Slurm, Why Kubernetes, and Why Slinky specifically.
        *   Added "⚙️ Slinky Component Mapping — How Each Workload Type Runs" section describing the job lifecycle and component interaction for Batch, Interactive, and Central Service workloads.
        *   Implemented a Mermaid sequence diagram illustrating the "LLM Inference Service Lifecycle".
        *   Added "📚 Architecture Decision References" with 17 consolidated citations from SchedMD, AWS, PEARC, CNCF, and internal project docs.

### 💡 Why This Design?
*   **Evidence-Based Architecture:** By citing industry standards (TOP500, CNCF) and official documentation (SchedMD, AWS), we establish the AI Sandbox as a production-ready design aligned with university HPC challenges.
*   **Operational Clarity:** Mapping Slurm concepts (partitions, GRES) to Kubernetes primitives (NodeSets, OCI images) helps bridge the knowledge gap for both traditional HPC admins and cloud-native developers.
*   **Service-Oriented HPC:** Explicitly documenting the lifecycle of LLM inference as a Slurm-managed service prepares the platform for the high demand for shared AI models.

### 🛠️ Verification Steps
1.  Verify documents render properly as markdown.
2.  Confirm Mermaid diagrams are syntactically correct.
3.  Ensure all cross-references to internal docs (CAPACITY_PLANNING, INCREMENT_LOG) are correct.
## [Increment 16] - 2026-07-06: Deploy slurm-bridge for Unified Pod Queueing

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

## [Increment 15] - 2026-07-05: Adopt slurm-client Library in Go Portal

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

## [Increment 14] - 2026-07-05: Environment Assessment & Capacity Planning Specs

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Document target environments, hardware matrices, network topologies, workload profile catalogs, partition designs, and autoscaling policies to define the foundation layer requirements.

### 📝 Key Changes & Files Modified

1.  **Environment Assessment:**
    *   Created [ENVIRONMENT_ASSESSMENT.md](file:///home/khemi/workspace/ai_sandbox/docs/ENVIRONMENT_ASSESSMENT.md): Documented hardware requirements, network diagrams, and a local Kind to production HPC gap analysis.
2.  **Capacity Planning:**
    *   Created [CAPACITY_PLANNING.md](file:///home/khemi/workspace/ai_sandbox/docs/CAPACITY_PLANNING.md): Cataloged workload profiles, partition architecture, and NodeSet replica limits.
3.  **Project Progress:**
    *   Updated [WORK_PACKAGES.md](file:///home/khemi/workspace/ai_sandbox/docs/WORK_PACKAGES.md): Marked WP3-1-1 and WP3-1-2 as completed (🟢 Done).

### 💡 Why This Design?
*   **Structured Foundation:** Defining concrete hardware bounds and workload resource footprints ensures that future scheduling configurations (partitions, QoS, fair-share rules) have a clear baseline.
*   **Clear Scaling Limits:** Setting bounds on minimum and maximum replicas prevents unexpected cloud/HPC cost overruns.

### 🛠️ Verification Steps
1.  Verify documents render properly as markdown.
2.  Confirm that target constraints map to the requirements of university students and typical Deep Learning tasks.

## [Increment 13] - 2026-07-02: Curated OCI Images for Interactive Workloads

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
## [Increment 12] - 2026-06-30: Manifest Schema Migration (type + OCI image fields)

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

## [Increment 11] - 2026-06-28: Deploy Go Portal with Traefik Sidecar in Kind Cluster

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


## [Increment 9] - 2026-06-24: Dynamic User Resolution via libnss-extrausers

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


## [Increment 8] - 2026-06-21: Storage Layout and Permissions Script

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

## [Increment 7] - 2026-06-21: Unix Permissions Isolation Verification Suite

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

## [Increment 5] - 2026-06-21: Web Portal Enhancements

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

## [Increment 3] - 2026-06-13: Kubernetes-Native Storage Isolation

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

## [Increment 1] - 2026-06-13: Detailed Automation Docs & Central Branch Integration

*   **Author:** Antigravity (Interactive) & Khem
*   **Goal:** Document the 5-part verification suite under the automation workflow and push the complete codebase to the central `development` branch for Jules integration.

### 📝 Key Changes & Files Modified

1.  **Workflow Documentation:**
    *   Updated [DEVELOPMENT_WORKFLOW.md](file:///home/khemi/workspace/ai_sandbox/DEVELOPMENT_WORKFLOW.md): Listed and detailed the 5 core test cases (Clean Cluster Spawn, Standard Queueing, Parallel Node Execution, Persistent Shared Storage, and Disaster Recovery) under Task A (Stability Check).
2.  **Central Branch Integration:**
    *   Merged the `feature/k8s-native-isolation` branch into `development` and successfully pushed it to remote `origin/development`. This enables Jules to locate and run [scripts/verify-infrastructure.sh](file:///home/khemi/workspace/ai_sandbox/scripts/verify-infrastructure.sh).

---

