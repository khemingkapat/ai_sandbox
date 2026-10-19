# AI Sandbox: Student & Developer Guide for MLflow Experiment Tracking

**Document Status:** Operational Runbook & User Guide (WP3-1-11)  
**Target Audience:** Students, Teaching Assistants, AI Sandbox Administrators  

---

## 1. Overview & Architectural Design

The AI Sandbox provides an always-on, centralized **MLflow Tracking Server** hosted in the `services` namespace on compute worker nodes (`ai-worker1`). It allows students and researchers to track hyperparameters, compare training metrics (loss curves, accuracy), and log model artifacts with zero manual cluster configuration.

### Key Architectural Guarantees:
* **Decoupled Failure Domain:** MLflow uses a dedicated PostgreSQL 16 database. It does **not** share the Slurm accounting MariaDB on `ai-control`. Heavy student logging loops will never destabilize the Slurm job scheduler.
* **No SQLite / NFS Lockups:** Concurrency bottlenecks and database corruption are eliminated by PostgreSQL connection pooling.
* **Proxied Artifact Storage:** All model weights, checkpoints, and plot artifacts are streamed over HTTP port 5000 directly to the tracking server (`--serve-artifacts`), which writes them to the underlying storage volume (`/mnt/storage/mlflow/artifacts`) with consistent service permissions. Student pods do not need direct POSIX write permissions to the artifact store.
* **100% Opt-In:** The `mlflow` client is pre-installed in the base environment and points passively to `http://mlflow.services.svc.cluster.local:5000`. If you do not use MLflow (e.g., prompt engineering with vLLM or LangGraph), MLflow is completely dormant.

---

## 2. Accessing the MLflow Web Dashboard

* **Internal / In-Cluster URL:** `http://mlflow.services.svc.cluster.local:5000`
* **External Web Gateway:** `https://<sandbox-domain>/mlflow/`
  * Static UI bundles, AJAX queries, and artifacts are routed transparently through the Traefik ingress gateway with security headers.

---

## 3. Quickstart Examples

### Example A: Basic Metrics & Hyperparameter Logging

```python
import mlflow

# 1. Optionally name your experiment (isolates your runs on the dashboard)
mlflow.set_experiment("my-first-model")

# 2. Start a run
with mlflow.start_run(run_name="baseline-cnn"):
    # Log hyperparameters
    mlflow.log_param("learning_rate", 0.001)
    mlflow.log_param("batch_size", 32)
    mlflow.log_param("optimizer", "AdamW")

    # Log metrics over training steps
    for epoch in range(1, 4):
        loss = 0.5 / epoch
        acc = 0.8 + (0.05 * epoch)
        mlflow.log_metric("train_loss", loss, step=epoch)
        mlflow.log_metric("val_accuracy", acc, step=epoch)

    # Log an artifact (plot, JSON, or text)
    with open("notes.txt", "w") as f:
        f.write("Model converged with zero NaN loss spikes.")
    mlflow.log_artifact("notes.txt")

print("Run logged successfully! View it at: https://<sandbox-domain>/mlflow/")
```

---

### Example B: One-Line Autologging for PyTorch & Hugging Face

MLflow includes native autologging for PyTorch, Hugging Face `Trainer`, LightGBM, and Scikit-learn:

```python
import mlflow
from transformers import Trainer, TrainingArguments

# Opt-in to an experiment namespace
mlflow.set_experiment("qlora-finetuning")

# Enable automatic capture of loss, learning rate, GPU memory, and model configs
mlflow.autolog()

# ... Standard PyTorch or HuggingFace Training Loop ...
# trainer = Trainer(...)
# trainer.train()
```

---

## 4. Slurm Batch Job Integration (`sbatch`)

When submitting batch jobs to Slurm partitions (`batch-cpu` or `batch-gpu`), the internal cluster DNS resolves `mlflow.services.svc.cluster.local:5000` automatically:

```bash
#!/bin/bash
#SBATCH --job-name=train-bert
#SBATCH --partition=batch-gpu
#SBATCH --gres=gpu:1
#SBATCH --time=04:00:00

export MLFLOW_TRACKING_URI="http://mlflow.services.svc.cluster.local:5000"
export MLFLOW_EXPERIMENT_NAME="${USER}-bert-pretraining"

python train.py
```

---

## 5. Network Security & Policies

* **Egress Policy:** Workload pods in the `workload` namespace are permitted TCP egress to port `5000` in the `services` namespace via `k8s/network-policies/allow-mlflow-egress.yaml`.
* **Database Confinement:** Direct TCP connection to PostgreSQL port `5432` from the `workload` namespace is dropped by NetworkPolicy (`k8s/network-policies/allow-postgres-services-only.yaml`). All database interactions must pass through the MLflow application layer.

---

## 6. Verification & Health Checks

Administrators can verify the end-to-end operation of the MLflow stack at any time by running:

```bash
bash scripts/verify-mlflow.sh
```

**Expected Result:**
```
============================================================
🧪 AI Sandbox: WP3-1-11 MLflow Experiment Tracking Verification
============================================================
  ✅ [PASS] PostgreSQL 16 StatefulSet Ready (node=ai-worker1)
  ✅ [PASS] PostgreSQL Database Isolated (TCP 5432 from workload dropped by NetworkPolicy)
  ✅ [PASS] MLflow Server Deployment Ready (node=ai-worker1, gunicorn active)
  ✅ [PASS] MLflow Internal REST /health (http://mlflow.services:5000 -> OK)
  ✅ [PASS] Traefik Gateway /mlflow UI (HTTP 200 with <title>MLflow</title>)
  ✅ [PASS] Traefik Static Bundle Routing (main.js HTTP 200)
  ✅ [PASS] Traefik REST API /api/2.0 (Active experiment found: automated-test-suite)
  ✅ [PASS] Python SDK Autologging & Artifact Upload
  ✅ [PASS] Proxied Artifact Storage Verification
============================================================
Verification Summary: 9/9 PASSED
All MLflow Central Service and Experiment Tracking checks PASSED!
============================================================
```
