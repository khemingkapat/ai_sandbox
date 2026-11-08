# 0004 — Central AI Services Architecture & Namespace Decoupling

Date: 2026-10-20  
Status: accepted  
Supersedes: Colocating AI tools in default/slurm namespace

## Context
Central AI services (vLLM inference server, MLflow experiment tracking, in-cluster OCI image registry, and planned Qdrant vector database) require continuous uptime, dedicated storage volumes, and network access for student pods across the cluster.

Initially, deploying services directly into the `slurm` namespace created tight coupling: upgrades to the Slurm controller or MariaDB database risked disrupting MLflow and inference workloads. Furthermore, exposing raw database ports or internal endpoints to student pods violated tenant isolation.

## Decision
1. **Three-Tier Namespace Isolation:**
   - `slurm`: Contains core HPC control plane components (`slurm-operator`, `slurmctld`, `slurmd` compute NodeSets, `slurmdbd`, and MariaDB StatefulSet).
   - `services`: Contains central shared tooling (`vllm`, `mlflow`, `registry`, and future `qdrant`).
   - `workload`: Contains dynamic, untrusted student interactive pods.
2. **Dedicated Storage & Proxied Artifact Streaming:**
   - MLflow uses a dedicated PostgreSQL 16 StatefulSet (`mlflow-postgres-pvc`, 10Gi) isolated completely from MariaDB.
   - MLflow artifact tracking uses server-side proxied artifact streaming (`--serve-artifacts`) writing directly to `/mnt/storage/mlflow/artifacts` (50Gi PVC). Student pods never mount or communicate with the raw artifact filesystem; all tracking and artifact uploads flow via HTTP/REST on port 5000.
3. **In-Cluster Registry:** An in-cluster OCI registry (`registry:2`) is hosted in `services` backed by `registry-pvc`, mirrored by containerd on all nodes at `localhost:5000` to allow fast layer caching of student workspace images without external network roundtrips.
4. **NetworkPolicy Fencing:** Student pods in `workload` can reach port 5000 (MLflow HTTP), port 8000/Traefik (vLLM), and port 6333 (Qdrant), but are strictly blocked by CNI policies from reaching database ports 5432 (Postgres) or 3306 (MariaDB).

## Consequences
- **Positive:** Zero fate-sharing between Slurm HPC infrastructure and AI service tooling; airtight network and storage security boundaries; high performance local image caching.
- **Negative:** Requires explicit CNI NetworkPolicy egress manifests when onboarding a new central service.
- **Trigger for Revisiting:** If moving to a managed cloud Kubernetes provider where managed databases (RDS/Cloud SQL) replace in-cluster stateful sets.
