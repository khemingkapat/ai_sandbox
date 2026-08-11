# WP3-1-5: Slurm Policy & Resource Configuration — Verification Guide

> **Scope:** This document defines the verification steps for WP3-1-5. It validates the integration of the MariaDB + `slurmdbd` accounting stack, the enabling of Fair-Share scheduling, and the enforcement of Partition fencing logic.
>
> **Environment:** Khem's local laptop — no dedicated GPU required. The focus is on validating the controller's logic (rejecting jobs that violate limits, registering the cluster to the accounting DB), not physical performance.

---

## 1. What Are We Testing?

WP3-1-5 introduces accounting and strict policies. We need to verify:
1. **Accounting DB:** `slurmdbd` correctly spins up and connects to `mariadb`.
2. **Fair-Share Integration:** `slurmctld` communicates with `slurmdbd` to calculate priorities.
3. **Partition Fencing:** Jobs requesting resources beyond `MaxTRESPerJob` bounds are blocked.

---

## 2. Test Plan

### Pre-Requisite: Boot the Cluster

```bash
# Clean up and boot (assuming WP3-1-4 baseline)
kind delete cluster 2>/dev/null || true
kind create cluster --config k8s/kind-config.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=60s
./scripts/start-slinky.sh
```

**Acceptance Criteria:**
- [ ] Cluster boots successfully.

---

### Test 1: Accounting Infrastructure Verification

**Purpose:** Ensure MariaDB and `slurmdbd` are running and the cluster is registered.

```bash
# Check if the new pods are running
kubectl get pods -n slurm -l app.kubernetes.io/name=slurmdbd
kubectl get pods -n slurm -l app.kubernetes.io/name=mariadb

# Verify slurmdbd successfully connected to DB and registered the cluster
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sacctmgr show cluster
```

**Acceptance Criteria:**
- [ ] Both MariaDB and `slurmdbd` pods are `Running`.
- [ ] `sacctmgr show cluster` lists `slurm_slurm` (or the configured cluster name) without hanging or timing out.

---

### Test 2: Fair-Share Scheduling Validation

**Purpose:** Verify that the Multifactor plugin is loaded and Fair-Share weights are active.

```bash
# Check the active Slurm configuration
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show config | grep Priority

# Test adding a user to the accounting DB and check Fair-Share value
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sacctmgr add account test_acct -i
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sacctmgr add user test_user account=test_acct -i
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sshare -u test_user
```

**Acceptance Criteria:**
- [ ] `PriorityType` is exactly `priority/multifactor`.
- [ ] `PriorityWeightFairshare` is set to `10000`.
- [ ] `sshare` returns a valid fair-share tree showing `test_user` with a normalized share.

---

### Test 3: Partition Limits & Fencing (Negative Testing)

**Purpose:** Prove that the rigid `MaxTRESPerJob` limits (from Capacity Planning) are enforced. The `interactive` partition is limited to `cpu=4,mem=16G,gres/gpu=1`. We will try to request 8 CPUs.

```bash
# Check partition limits
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show partition

# Attempt to submit a job that VIOLATES the interactive limit
# (Requesting 8 CPUs, limit is 4)
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --partition=interactive -c 8 --wrap="echo This should fail"

# Verify the job is blocked from running
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- squeue
```

**Acceptance Criteria:**
- [ ] The four partitions (`interactive`, `batch-cpu`, `batch-gpu`, `inference`) all show `PreemptMode=OFF`.
- [ ] The job remains in a `PENDING` state with the reason `QOSMaxCpuPerJobLimit`, demonstrating that the controller successfully enforces the partition boundary.
- [ ] No pod/job is spawned for the violating request.

---

### Test 4: Successful Resource Request (Positive Testing)

**Purpose:** Prove that a job within the defined fencing limits is accepted.

```bash
# Attempt to submit a job that is WITHIN limits
# (Requesting 2 CPUs, limit is 4)
JOB_ID=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --partition=interactive -c 2 --wrap="echo I am allowed")
  
echo "Submitted valid job: $JOB_ID"
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- squeue
```

**Acceptance Criteria:**
- [ ] The `sbatch` command succeeds and returns a Job ID.
- [ ] The job appears in the queue as `PENDING` or `RUNNING`.
