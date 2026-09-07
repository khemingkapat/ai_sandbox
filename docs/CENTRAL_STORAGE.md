# Central Storage, Datasets & Model Repository Architecture (WP3-1-7)

## 1. Executive Summary

This document records the architectural specification and design decisions for the **Central Shared Storage (`/mnt/storage`)**, curated datasets, and AI model weight caching across the AI Sandbox platform.

The architecture balances **multi-tenant security, concurrency safety, and storage efficiency** across shared Kubernetes nodes and Slurm compute daemons, ensuring students can seamlessly run AI engineering workloads without cross-tenant interference or storage exhaustion.

---

## 2. Directory Layout & Permission Boundaries

All persistent and shared cluster data is mounted under the unified root path `/mnt/storage` (provisioned via `slinky-storage-pvc`).

```
/mnt/storage/
├── common/                     # [root:root 755/644] Read-only cluster-wide utilities
│   ├── etc/                    # Dynamic passwd/group files for libnss-extrausers
│   └── software/               # Curated Apptainer SIF images (python.sif, etc.)
├── models/                     # [root:root 755] Curated, read-only pre-trained model weights
│   ├── huggingface/            # Shared Hugging Face cache (HF_HUB_CACHE)
│   ├── torch/                  # Shared PyTorch model hub (TORCH_HOME)
│   └── ollama/                 # Shared Ollama/vLLM backend weights
├── datasets/                   # [root:root 755] Curated starter and benchmark datasets
│   ├── kaggle/                 # Central pre-downloaded Kaggle competitions & datasets
│   ├── vision/                 # e.g., MNIST, CIFAR-10
│   └── nlp/                    # e.g., SQuAD, IMDb, WikiText
├── projects/                   # [UID:UID 700] Isolated private student project workspaces
│   ├── project1/               # Owned by UID 1001:1001
│   │   ├── .cache/             # Private student HuggingFace/Kaggle caches
│   │   └── .kaggle/            # Private student kaggle.json token
│   ├── project2/               # Owned by UID 1002:1002
│   └── project3/               # Owned by UID 1004:1004
├── scratch/                    # [root:root 1777] Ephemeral scratch space with sticky bit
│   ├── project1/
│   ├── project2/
│   └── ...
└── registry/                   # [root:root 755] Local in-cluster OCI distribution registry
```

### Standard Permission Matrix

| Path | Owner:Group | Permissions | Access Intent |
| :--- | :--- | :--- | :--- |
| `/mnt/storage/projects/<project>` | `<uid>:<uid>` | `700` (`drwx------`) | Private student workspaces, custom scripts, user-downloaded weights, checkpoints. |
| `/mnt/storage/common/` | `0:0` (root) | `755` (`drwxr-xr-x`) | Global extrausers DB (`/etc/passwd`, `/etc/group`), shared `.sif` batch images. |
| `/mnt/storage/models/` | `0:0` (root) | `755` (`drwxr-xr-x`) | Centrally pre-loaded foundation models. Read-only for student sessions. |
| `/mnt/storage/datasets/` | `0:0` (root) | `755` (`drwxr-xr-x`) | Curated course and benchmark datasets. Read-only for student sessions. |
| `/mnt/storage/scratch/` | `0:0` (root) | `1777` (`drwxrwxrwt`) | Ephemeral high-throughput temp workspace with POSIX sticky bit (similar to `/tmp`). |
| `/mnt/storage/registry/` | `0:0` (root) | `755` (`drwxr-xr-x`) | Storage backend for the in-cluster OCI registry (`registry:2`). |

---

## 3. Decision Record: Shared Model Hub Architecture

### Context & Problem
Deep learning foundation models (e.g., Llama 3 8B, Mistral 7B, Gemma 2, BGE embeddings) range from 5GB to 30GB+ per model. If 30 students in a lab simultaneously run `AutoModel.from_pretrained("meta-llama/...")`:
1. The cluster network gateway experiences an immediate bandwidth storm (30 × 15GB = 450GB).
2. Private student storage volumes rapidly exhaust available capacity with duplicate weights.
3. Hugging Face's default file-locking mechanism (`filelock`) causes deadlocks or corrupted partial downloads over shared NFS.

### Evaluation of Options

| Criterion | Option A: Admin-Curated Read-Only Hub (Adopted) | Option B: Shared Read-Write Cache |
| :--- | :--- | :--- |
| **Locking & Concurrency** | 🟢 **Zero write corruption.** Files cannot be corrupted or locked during concurrent jobs. | 🔴 **High risk of deadlocks.** Concurrent downloads trigger NFS `flock` race conditions. |
| **Tampering & Security** | 🟢 **Tampering immune.** Students cannot alter weights or inject malicious pickle checkpoints. | 🔴 **Severe vulnerability.** Any student can delete files (`rm -rf`) or poison shared models. |
| **Disk Efficiency** | 🟢 **Deterministic storage.** Baseline models stored exactly once. | 🟡 Auto-deduplicated, but unconstrained growth risks disk exhaustion. |
| **Student UX** | 🟢 **Instant load for class models.** Unlisted models download to private workspace. | 🟡 Automatic sharing until umask/permission drift causes `PermissionError`. |
| **Admin Maintenance** | 🟡 Proactive pre-loading at semester/module start. | 🔴 Reactive firefighting of corrupted lockfiles and broken permissions. |

### Architectural Decision: Option A (Admin-Curated Read-Only Model Hub)
*   **Central Model Hub:** Standard class models are downloaded once by administrators into `/mnt/storage/models/` and locked to `root:root 755`.
*   **Container Environment Contract:** Interactive sessions (JupyterLab, VS Code, Bash) and Slurm batch jobs automatically inject the following environment variables:
    ```bash
    export HF_HOME="/mnt/storage/projects/$SLURM_JOB_ACCOUNT/.cache/huggingface"
    export HF_HUB_CACHE="/mnt/storage/models/huggingface/hub"
    export TORCH_HOME="/mnt/storage/models/torch"
    export TRANSFORMERS_OFFLINE=0
    ```
*   **Dual-Tier Lookup Behavior:**
    1. **Pre-loaded Models:** Hugging Face checks `HF_HUB_CACHE` (`/mnt/storage/models/huggingface/hub`), finds the pre-loaded snapshot, and instantiates the model in seconds with zero network activity and zero extra disk usage.
    2. **Custom / Unapproved Models:** If a student requests a model not in the central library, Hugging Face writes the download into the student's private workspace cache (`/mnt/storage/projects/<project>/.cache/huggingface`). The central model library remains completely protected.

---

## 4. Dataset Repository & Kaggle Caching Architecture

### The Problem with Datasets over NFS
When 40 students run an assignment simultaneously:
*   Mass downloads from Kaggle or Hugging Face trigger **API rate limiting (HTTP 429)** and saturate the university connection.
*   Simultaneously extracting large `.zip` archives containing 100,000+ tiny files creates an **NFS metadata storm** (`getattr`, `lookup`), slowing disk I/O cluster-wide.

### The 2-Tier Dataset Strategy

#### Tier 1: Central Course & Competition Datasets (Read-Only)
*   **Location:** `/mnt/storage/datasets/` (subdivided into `/kaggle/competitions/`, `/kaggle/public/`, `/vision/`, `/nlp/`).
*   **Admin Seeding:** Instructors/admins run `scripts/seed-datasets.sh` or `scripts/seed-kaggle.sh` to download and unzip datasets **once**.
*   **Permission:** Owned by `root:root` with `755` (`drwxr-xr-x`).
*   **Student Usage:** Students load datasets directly with zero download latency:
    ```python
    import pandas as pd
    df = pd.read_csv("/mnt/storage/datasets/kaggle/competitions/titanic/train.csv")
    ```

#### Tier 2: Private Custom Datasets & Kaggle Tokens
*   **Container Environment Contract:** Interactive container pods inject environment variables to preserve student tokens and prevent loss on pod teardown:
    ```bash
    export KAGGLE_CONFIG_DIR="/mnt/storage/projects/$SLURM_JOB_ACCOUNT/.kaggle"
    export KAGGLEHUB_CACHE="/mnt/storage/projects/$SLURM_JOB_ACCOUNT/.cache/kagglehub"
    ```
*   **Student Privacy:** Students store their personal `kaggle.json` in their private `700` project directory without exposing keys to classmates.
*   **Custom Downloads:** Personal downloads write to the student's private project disk, isolating failures and preventing shared cache corruption.

---

## 5. Storage Quota & Pro-Rata Multi-User Governance

To prevent storage exhaustion and ensure equitable disk allocation across solo and team projects, the platform implements a **Pro-Rata (Shared-Cost) Quota Model** backed by **Slurm `sacctmgr` Account Associations**.

### The Pro-Rata Storage Formula

Every student account has a global storage allowance (e.g., $50\text{ GB}$). When students collaborate in a shared project workspace (`/mnt/storage/projects/<project>`), the project's allocated disk budget is divided equally among its active members:

$$\text{Total Student Storage Usage} = \sum_{p \in \text{Projects}(U)} \frac{\text{Budget}(p)}{N_{\text{members}}(p)} \le 50\text{ GB}$$

#### Example Allocation:
* **Solo Project (`project1`):** Budget = $20\text{ GB}$, $1$ member $\rightarrow 20\text{ GB}$ charged to User 1.
* **Team Project (`project2`):** Budget = $50\text{ GB}$, $4$ members (Users 1, 2, 3, 4) $\rightarrow 12.5\text{ GB}$ charged to each member.
* **User 1 Total Balance:** $20\text{ GB} + 12.5\text{ GB} = 32.5\text{ GB} / 50\text{ GB}$ ($65\%$ utilized).

---

### Project Membership Tracking via Slurm `sacctmgr`

Rather than maintaining a separate user-to-project database, the platform relies natively on **Slurm's accounting backend (`slurmdbd` / `sacctmgr`)** as the definitive single source of truth for project membership:

```
Slurm Account ("project2") in sacctmgr
├── User 1 (user1)  ──┐
├── User 2 (user2)    │──> sacctmgr show associations account=project2
├── User 3 (user3)    │    (N = 4 active members)
└── User 4 (user4)  ──┘
```

* **Membership Query:** The Go portal and audit scripts query account associations dynamically via the Slurm REST API (`/slurm/v0.0.42/associations` or `slurmClient` / `sacctmgr`):
  ```bash
  sacctmgr show association where account=project2 format=Account,User -n -P
  ```
* **Member Changes:** Adding or removing a student from a course project is an atomic `sacctmgr` operation (`sacctmgr add/remove user <name> account=<project>`), which automatically updates the member count $N$ and re-calculates the pro-rata quota share across team members.
* **Directory Boundary Enforcement:** The physical directory `/mnt/storage/projects/<project>` is enforced against the project's aggregate budget ($\text{Budget}(p)$).

---

### Disk Bloat Prevention & Deduplication (3-Layer Defense)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Pro-Rata Disk Quotas (The Hard Ceiling)                                  │
│    • Individual allowances ($50\text{ GB}$) bound total cluster storage to:  │
│      $N_{\text{students}} \times 50\text{ GB}$.                              │
│    • Prevents any student or group from monopolizing shared NFS capacity.   │
├─────────────────────────────────────────────────────────────────────────────┤
│ 2. Portal Discovery Catalog (Look Before You Download)                      │
│    • Web portal exposes an "Available Datasets & Models" page.              │
│    • Students discover pre-loaded models/datasets before initiating pulls.   │
├─────────────────────────────────────────────────────────────────────────────┤
│ 3. Storage Audit & Promotion Workflow (scripts/audit-storage.sh)             │
│    • Admin periodic audit detects identical large folders in student spaces.│
│    • Admin promotes popular datasets/models to Central Storage.             │
│    • Students delete local copies to reclaim their private quota.           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Ephemeral Scratch Space & Cleanup Policy

1.  **Scratch Path:** `/mnt/storage/scratch/` configured with `1777` permissions (world-writable with sticky bit, ensuring students can only delete their own temporary files).
2.  **Environment Redirection:** Workload containers set:
    ```bash
    export TMPDIR="/mnt/storage/scratch/$USER"
    ```
3.  **Auto-Cleanup Policy:** A cron-based cleanup rule purges scratch files older than 7 days (`find /mnt/storage/scratch/ -type f -mtime +7 -delete`), preventing runaway logs and checkpoint accumulation.

---

## 7. Local Kind Prototype vs. Production HPC Mapping

| Storage Dimension | Local Development (Kind) | Production HPC Cluster |
| :--- | :--- | :--- |
| **Backend Storage** | Local directory (`./storage`) mounted into Kind nodes via `hostPath`. | Enterprise-grade NFS v4.2 / CephFS / Lustre storage appliance. |
| **Kubernetes PV/PVC** | Manual `hostPath` PersistentVolume with `ReadWriteMany`. | Dynamic StorageClass backed by `nfs-csi` or `cephfs-csi`. |
| **Quota Enforcement** | Monitored via Web Portal & Slurm metrics; soft alerts. | Hard XFS project quotas / CephFS quotas enforced per student directory. |
| **State Decoupling** | `slurm-state-pv` (5Gi) separated from `slinky-storage-pv` (20Gi). | Dedicated controller block volume separated from shared user NFS share. |
| **Deduplication** | Manual admin promotion (`scripts/audit-storage.sh`). | Hardware block-level inline deduplication (ZFS / NetApp / Ceph). |

---

## 8. Implementation Tasks & Deliverables for WP3-1-7

1.  **Update Storage Layout & Permissions ([`scripts/init-storage.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/init-storage.sh)):**
    *   Create `/mnt/storage/models/{huggingface,torch,ollama}` (`root:root 755`).
    *   Create `/mnt/storage/datasets/{kaggle,vision,nlp}` (`root:root 755`).
    *   Create `/mnt/storage/scratch` (`root:root 1777`).
2.  **Create Seeding Tooling:**
    *   `scripts/seed-models.sh`: Pre-populates baseline CPU-friendly test models (`BAAI/bge-small-en-v1.5`, `Qwen/Qwen2.5-0.5B-Instruct`).
    *   `scripts/seed-datasets.sh`: Pre-populates starter benchmark datasets (MNIST, CIFAR-10, IMDb).
    *   `scripts/seed-kaggle.sh`: Admin helper to download and unpack course Kaggle competitions/datasets into `/mnt/storage/datasets/kaggle/`.
3.  **Storage Audit & Scratch Cleanup Automation:**
    *   `scripts/audit-storage.sh`: Audits disk consumption and identifies duplicate datasets across student project folders.
    *   `scripts/clean-scratch.sh`: Purges temporary scratch files older than 7 days.
4.  **Inject Container Environment Contracts:**
    *   Update interactive pod builder ([`portal/session_manager.go`](file:///home/khemi/workspace/ai_sandbox/portal/session_manager.go)) and batch script templates to inject `HF_HUB_CACHE`, `TORCH_HOME`, `KAGGLE_CONFIG_DIR`, `KAGGLEHUB_CACHE`, and `TMPDIR`.
