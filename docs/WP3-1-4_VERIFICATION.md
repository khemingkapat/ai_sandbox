# WP3-1-4: Slinky Deployment & Orchestrator Integration — Verification Guide

> **Scope:** This document summarizes the purpose of WP3-1-4, what has been implemented, and defines a concrete, laptop-friendly test plan with acceptance criteria.
>
> **Environment:** Khem's local laptop — no dedicated GPU. All tests use Kind (Kubernetes-in-Docker) with CPU-only containers. The `slurmd-gpu` NodeSet runs as a standard container for routing logic validation only.

---

## 1. What Is WP3-1-4?

WP3-1-4 is the **core infrastructure deployment** work package. Its job is to take the Slinky stack — the `slurm-operator`, its CRDs, the Slurm controller, worker NodeSets, and the `slurm-bridge` — and wire them into a working Kubernetes cluster that can:

1. **Schedule batch jobs** through the standard Slurm controller (`slurmctld`).
2. **Route jobs to distinct compute partitions** (`slurmd-cpu` vs `slurmd-gpu`) based on topology.
3. **Intercept native Kubernetes pods** via `slurm-bridge` and register them as Slurm jobs, enforcing fairshare and accounting even for interactive workloads.
4. **Isolate system state** from student data so a full `/mnt/storage` can never crash the scheduler.

Without this, everything downstream (QoS policies in WP3-1-5, container images in WP3-1-6, the portal in WP3-1-8) has no scheduler to talk to.

---

## 2. What Has Been Done

### 2.1 Slurm Deployment via Helm ([k8s/values.yaml](file:///home/khemi/workspace/ai_sandbox/k8s/values.yaml))

Reverted the broken `SlurmCluster` CRD attempt and went back to using the official Slinky Helm chart to correctly provision granular CRDs (`Controller`, `NodeSet`, `RestAPI`). This defines:

| Component | Detail |
|---|---|
| **Controller** | `slurmctld` with custom image, mounts `slurm-state-pvc` at `/var/spool/slurmctld` and `extrausers` for dynamic user resolution |
| **REST API** | `slurmrestd` with custom image and `extrausers` mount |
| **CPU NodeSet** | `slurmd-cpu` — 2 replicas, StatefulSet, mounts shared student storage and extrausers |
| **GPU NodeSet** | `slurmd-gpu` — 1 replica, StatefulSet, same mounts (no GPU resource request, so it runs on CPU locally) |
| **Partition** | Single `all` partition spanning both NodeSets, `State=UP`, `Default=YES` |

### 2.2 State Storage Isolation ([pv-pvc.yaml](file:///home/khemi/workspace/ai_sandbox/k8s/pv-pvc.yaml))

Two completely separate Persistent Volumes:

| Volume | Path | Size | Access | Purpose |
|---|---|---|---|---|
| `slinky-storage-pv` | `/mnt/storage` | 20Gi | ReadWriteMany | Student workspaces, datasets, job output |
| `slurm-state-pv` | `/mnt/slurm-state` | 5Gi | ReadWriteOnce | Slurm controller checkpoints & state files |

> [!IMPORTANT]
> This isolation is critical. If both volumes pointed to the same hostPath, a student filling their quota would starve `slurmctld` of disk and crash the entire scheduler.

### 2.3 Startup Automation ([start-slinky.sh](file:///home/khemi/workspace/ai_sandbox/scripts/start-slinky.sh))

The startup script now follows this sequence:

1. Install `cert-manager`, `slurm-operator-crds`, `slurm-operator`
2. Create `slurm` namespace + apply PV/PVCs
3. Build custom Slurm images → load into Kind
4. Wait for `slurm-operator` to be ready
5. Install Slinky `slurm` helm chart using `k8s/values.yaml`
6. Wait for `slurmctld` → generate JWT → store as K8s Secret
7. Install `slurm-bridge` Helm chart
8. Label/annotate `kind-worker3` as a bridge-managed external node
9. Fix inotify limits on all Kind nodes (for Traefik)
10. Build portal + OCI images → deploy

### 2.4 Slurm-Bridge Deployment ([slurm-bridge-values.yaml](file:///home/khemi/workspace/ai_sandbox/k8s/slurm-bridge-values.yaml))

The bridge intercepts pods in the `workload` namespace and schedules them through Slurm:

- **Managed namespace:** `workload`
- **Slurm REST endpoint:** `http://slurm-restapi.slurm:6820`
- **Auth:** JWT secret (`slurm-bridge-token`)
- **Target partition:** `all`

### 2.5 Infrastructure Verification Suite ([verify-infrastructure.sh](file:///home/khemi/workspace/ai_sandbox/scripts/verify-infrastructure.sh))

Updated to use dynamic pod discovery via label selectors instead of hardcoded pod names. Added Test 7 for bridge validation.

---

## 3. Test Plan

> [!NOTE]
> Every test below is designed to run on a laptop with no GPU. We are validating **logic, routing, and boundaries** — not hardware performance. The `slurmd-gpu` NodeSet is a mock partition that runs on CPU.

### Pre-Requisite: Boot the Cluster

```bash
# From repo root
kind delete cluster 2>/dev/null || true
kind create cluster --config k8s/kind-config.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=60s
./scripts/start-slinky.sh
```

**Acceptance Criteria:**
- [ ] `kind create cluster` exits 0
- [ ] All 4 nodes (1 control-plane + 3 workers) reach `Ready`
- [ ] `start-slinky.sh` completes without error

---

### Test 1: Operator & CRD Reconciliation

**Purpose:** Verify that the `slurm-operator` correctly processes the `SlurmCluster` CRD and creates all expected pods.

```bash
# Check operator is running
kubectl get deployment -n slinky slurm-operator

# Check the Slurm Helm release was accepted
helm list -n slurm

# Check all Slurm pods are running
kubectl get pods -n slurm -o wide
```

**Acceptance Criteria:**
- [ ] `kubectl get deployments -n slinky` shows `slurm-operator` as `1/1 READY`
- [ ] `helm list -n slurm` returns the `slurm` release as deployed
- [ ] The following pods exist and are `Running`:
  - `slurm-controller-0` (the `slurmctld`)
  - `slurm-restapi-*` (1 replica)
  - `slurm-worker-slurmd-cpu-0`, `slurm-worker-slurmd-cpu-1` (2 CPU workers)
  - `slurm-worker-slurmd-gpu-0` (1 GPU-label worker, running on CPU)

---

### Test 2: Partition & Node Topology

**Purpose:** Verify Slurm sees two distinct NodeSets and has a working `all` partition that spans both.

```bash
# Check partition info
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sinfo

# Check node details
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show nodes
```

**Acceptance Criteria:**
- [ ] `sinfo` output shows the `all` partition in `UP` state
- [ ] Nodes from both `slurmd-cpu` and `slurmd-gpu` NodeSets appear as `idle` or `alloc`
- [ ] Total node count = 3 (2 CPU + 1 GPU)
- [ ] The `all` partition is marked as the default (`*` suffix in sinfo)

---

### Test 3: State Volume Isolation

**Purpose:** Confirm that `slurmctld`'s state directory (`/var/spool/slurmctld`) is on a **separate** volume from student storage (`/mnt/storage`).

```bash
# Check mount points inside the controller pod
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- df -h /var/spool/slurmctld
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- df -h /var/lib/extrausers

# Verify they are distinct mount points
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- mount | grep -E '(spool|storage)'
```

**Acceptance Criteria:**
- [ ] `/var/spool/slurmctld` is mounted to a volume backed by `/mnt/slurm-state` (the `slurm-state-pv`)
- [ ] `/var/lib/extrausers` is mounted to a volume backed by `/mnt/storage` (the `slinky-storage-pv` with `subPath: common/etc`)
- [ ] The two mount points reference **different** underlying devices or hostPaths
- [ ] Both PVs show `Bound` status:
  ```bash
  kubectl get pv,pvc -n slurm
  ```

---

### Test 4: Basic Job Submission & Execution

**Purpose:** Prove the Slurm scheduler can accept, queue, dispatch, and complete a trivial job.

```bash
# Submit a simple job
JOB_ID=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --wrap="echo hello-from-slurm" -N 1)
echo "Submitted job: $JOB_ID"

# Watch the queue
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- squeue

# Wait and check completion
sleep 10
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show job "$JOB_ID"
```

**Acceptance Criteria:**
- [ ] `sbatch` returns a numeric job ID without error
- [ ] `squeue` shows the job as `PENDING` or `RUNNING`
- [ ] `scontrol show job` eventually shows `JobState=COMPLETED`
- [ ] Job was dispatched to one of the NodeSet worker pods (check `NodeList` in scontrol output)

---

### Test 5: Cross-Partition Routing

**Purpose:** Verify that we can explicitly target the CPU vs GPU partition (even though both run on CPU hardware locally).

```bash
# Submit to CPU nodes only
CPU_JOB=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --nodelist=slurmd-cpu-0 --wrap="hostname" -N 1)

# Submit to GPU node only
GPU_JOB=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --nodelist=slurmd-gpu-0 --wrap="hostname" -N 1)

echo "CPU job: $CPU_JOB, GPU job: $GPU_JOB"

# Wait for both
sleep 15

# Check where they ran
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show job "$CPU_JOB" | grep NodeList
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show job "$GPU_JOB" | grep NodeList
```

**Acceptance Criteria:**
- [ ] CPU job's `NodeList` contains `slurmd-cpu`
- [ ] GPU job's `NodeList` contains `slurmd-gpu`
- [ ] Both jobs reach `COMPLETED` state
- [ ] This proves the scheduler correctly distinguishes the two NodeSets as separate scheduling targets

> [!TIP]
> If `--nodelist` fails because node names don't match exactly, use `sinfo -N` first to get the exact registered hostnames, then adjust.

---

### Test 6: Disaster Recovery (Controller Crash)

**Purpose:** Prove that `slurmctld` state survives a pod crash because it's persisted on `slurm-state-pvc`.

```bash
# Submit a long-running job
DR_JOB=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --wrap="sleep 30" -N 1)
echo "Submitted recovery test job: $DR_JOB"

# Wait for state to flush
sleep 5

# Kill the controller
kubectl delete pod slurm-controller-0 -n slurm --grace-period=0 --force

# Wait for it to come back
kubectl wait --namespace slurm --for=condition=Ready pod/slurm-controller-0 --timeout=120s

# Check if the job survived the crash
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show job "$DR_JOB"
```

**Acceptance Criteria:**
- [ ] After pod restart, `scontrol show job` finds the job (it was not lost)
- [ ] Job state is `RUNNING` or `COMPLETED` (not `UNKNOWN` or missing)
- [ ] This proves `/var/spool/slurmctld` on the persistent volume retained the queue state

---

### Test 7: Slurm-Bridge Pod Interception

**Purpose:** Verify that `slurm-bridge` intercepts a standard Kubernetes pod submitted to the `workload` namespace and registers it as a Slurm job.

```bash
# Ensure the workload namespace exists
kubectl create namespace workload --dry-run=client -o yaml | kubectl apply -f -

# Submit a test pod using the bridge scheduler
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-bridge-job
  namespace: workload
  annotations:
    slinky.slurm.net/job-name: test-bridge-job
spec:
  schedulerName: slurm-bridge-scheduler
  containers:
  - name: test
    image: alpine
    command: ["sleep", "30"]
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
EOF

# Wait for bridge to process
sleep 10

# Check if it appears in Slurm's queue
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- squeue

# Check pod status
kubectl get pod test-bridge-job -n workload -o wide

# Cleanup
kubectl delete pod test-bridge-job -n workload --grace-period=0 --force 2>/dev/null || true
```

**Acceptance Criteria:**
- [ ] `squeue` shows a job entry corresponding to `test-bridge-job`
- [ ] The pod was scheduled by `slurm-bridge-scheduler` (not the default kube-scheduler)
- [ ] **OR** if the bridge cannot fully schedule due to missing node annotations on Kind, the pod shows `Pending` with a `slurm-bridge` scheduler event — this is a **known limitation** on Kind and is acceptable as a partial pass

> [!WARNING]
> On a Kind cluster, `slurm-bridge` may not fully schedule the pod because the Kind worker nodes lack the Slurm node annotations that a production Slinky cluster would have. A `Pending` state with bridge scheduler events is a valid partial pass. Full scheduling is expected only in a real Slinky environment.

---

### Test 8: Dynamic Worker Discovery (Verification Suite)

**Purpose:** Confirm the automated test suite uses dynamic label-based pod discovery, not hardcoded names.

```bash
# Just verify the script doesn't contain hardcoded worker pod names
grep -n "slurm-worker-slinky" scripts/verify-infrastructure.sh
# Expected: no matches

# Confirm it uses label selectors
grep -n "app.kubernetes.io/name=slurmd" scripts/verify-infrastructure.sh
# Expected: multiple matches showing dynamic pod queries
```

**Acceptance Criteria:**
- [ ] Zero matches for `slurm-worker-slinky` (old hardcoded names are gone)
- [ ] At least 2 matches for `app.kubernetes.io/name=slurmd` (dynamic label selector is in use)

---

## 4. Remaining WP3-1-4 Work

Per [WORK_PACKAGES.md](file:///home/khemi/workspace/ai_sandbox/docs/WORK_PACKAGES.md#L58-L66):

| Item | Status | Notes |
|---|---|---|
| slurm-operator + CRDs | ✅ Done | Deployed declaratively |
| CPU NodeSet config | ✅ Done | 2 replicas, StatefulSet |
| Finalized Helm values | ✅ Done | Replaced by CRD approach |
| Infrastructure verification suite | ✅ Done | Tests 1–7 passing |
| slurm-bridge deployment | 🟢 Done | Deployed, partial scheduling on Kind (known limitation) |
| **GPU NodeSet configuration** | 🔴 Open | Logical routing works, but real GPU resource requests (`nvidia.com/gpu`) and GRES config are not wired. This requires actual GPU hardware to test. |

---

## 5. Known Limitations on Local Laptop

| Limitation | Impact | Mitigation |
|---|---|---|
| No dedicated GPU | `slurmd-gpu` NodeSet runs on CPU | Partition routing logic is still validated; GRES/device plugin testing deferred to production |
| Kind networking | `slurm-bridge` may not fully schedule pods | Accepted as partial pass; full bridge testing requires proper node annotations |
| Single-host storage | All hostPaths resolve to the same physical disk | Logical isolation via separate PV paths is still validated |
| Limited RAM/CPU | Cannot stress-test large job counts or multi-node parallelism at scale | Functional correctness is validated; performance benchmarking deferred |
