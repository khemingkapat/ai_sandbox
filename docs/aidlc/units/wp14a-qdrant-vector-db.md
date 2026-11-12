# Unit: WP14-A — Central Qdrant Vector Database & Network Isolation

Status: in-progress (Phase 1 — Gate A+B)
Parent GitHub WP: #14
Exploratory? no

## Intent
Deploy **Qdrant** (`qdrant/qdrant:v1.12.6`) as the final Tier 2 central shared microservice in the `services` namespace on CPU worker node `ai-worker1`, backed by persistent WAL/snapshot storage (`qdrant-data-pvc`, 20Gi) and protected by surgical CNI `NetworkPolicy` rules (`allow-qdrant-egress`) and Traefik reverse proxy routing (`/qdrant`). This completes the server-side RAG infrastructure baseline without touching GPU #1 VRAM or exposing internal control-plane databases.

## Scope & Non-goals
- **In scope:**
  - **Persistent Storage (`k8s/qdrant/01-storage.yaml`):**
    - `PersistentVolume` (`qdrant-data-pv`) and `PersistentVolumeClaim` (`qdrant-data-pvc`) in `services` namespace (`storageClassName: manual`, `ReadWriteOnce`, `20Gi`, `hostPath: /mnt/storage/qdrant`).
  - **Qdrant StatefulSet & Service (`k8s/qdrant/02-statefulset.yaml`):**
    - Single-replica `StatefulSet` (`qdrant`) in `services` namespace pinned via `nodeSelector` to `ai-worker1` with Slinky managed-node toleration (`slinky.slurm.net/managed-node: NoExecute`).
    - Container image `qdrant/qdrant:v1.12.6` (`imagePullPolicy: IfNotPresent`), exposing ports `6333` (HTTP REST / Web UI) and `6334` (gRPC).
    - Resource bounds: `requests: { cpu: 250m, memory: 1Gi }`, `limits: { cpu: "2", memory: 4Gi }` — strictly zero `nvidia.com/gpu` requests.
    - HTTP readiness and liveness probes targeting `/readyz` and `/healthz` on port `6333`.
    - `ClusterIP` Service (`qdrant.services.svc.cluster.local`) exposing ports `6333` (`http`) and `6334` (`grpc`).
  - **Network Boundary Pinholes (`k8s/network-policies/allow-qdrant-egress.yaml`):**
    - `NetworkPolicy` in `workload` namespace permitting student pods to egress strictly to pods labeled `app.kubernetes.io/name: qdrant` in the `services` namespace on TCP ports `6333` and `6334`.
    - Preserves `default-deny-workload` isolation against PostgreSQL (`5432`) and MariaDB (`3306`).
  - **Traefik Gateway Routing (`k8s/traefik-security-configmap.yaml`):**
    - Add `qdrant` router (`PathPrefix('/qdrant')` with `qdrant-stripprefix` middleware and `PathPrefix('/dashboard')`) routing to `http://qdrant.services.svc.cluster.local:6333` for browser dashboard and external REST inspection (mirroring the MLflow gateway pattern).
  - **Automated Verification Suite (`scripts/verify-qdrant.sh`):**
    - End-to-end cluster verification script with zero-leak `trap cleanup EXIT` checking: StatefulSet readiness on `ai-worker1`, internal DNS `/healthz`, Traefik gateway `/qdrant/healthz` & `/qdrant/dashboard`, CNI egress isolation (port 6333 allowed while port 5432 remains blocked), collection creation, 4-dimensional vector upsert, cosine similarity search accuracy, and on-disk WAL/collection persistence on `/mnt/storage/qdrant`.
- **Non-goals:**
  - Rebuilding client container images (`images/jupyterlab/Dockerfile`) or authoring the 5 starter `.ipynb` notebooks (scoped separately to Unit `WP14-B`).
  - Allocating GPU resources to Qdrant (all HNSW vector indexing executes in CPU RAM).

## Constraints and decisions to respect
- [ADR 0002: Storage and UID/GID Isolation Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)
- [ADR 0003: Single L40 GPU Sharing and QoS](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md)
- [ADR 0004: Central AI Services Architecture & Namespace Decoupling](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0004-central-services-architecture.md)
- **Resolved Strategic Decisions (Khem):**
  1. **Gateway Exposure:** Expose Qdrant internally at `qdrant.services.svc.cluster.local:6333` (`6334` gRPC) and externally via Traefik `/qdrant` (matching the MLflow pattern).
  2. **Classroom Multi-Tenancy:** Run shared classroom service protected by cluster NetworkPolicy without static API keys inside the cluster (`QDRANT_URL=http://qdrant.services.svc.cluster.local:6333`).
  3. **Resource Sizing:** Pin to `ai-worker1` with `4Gi` RAM limit (`1Gi` request) and `20Gi` PVC at `/mnt/storage/qdrant`.

## Files Allowed to Touch
| Allowed File Path | Purpose |
| :--- | :--- |
| `docs/aidlc/units/wp14a-qdrant-vector-db.md` | Unit specification and Bolt Log |
| `docs/aidlc/UNITS.md` | Flip WP14-A status |
| `docs/aidlc/PROJECT_CONTEXT.md` | Update Qdrant central service status |
| `k8s/qdrant/01-storage.yaml` | PV and PVC (`qdrant-data-pv`, `qdrant-data-pvc`, 20Gi) |
| `k8s/qdrant/02-statefulset.yaml` | Qdrant StatefulSet (`v1.12.6`) and ClusterIP Service (`6333`/`6334`) |
| `k8s/network-policies/allow-qdrant-egress.yaml` | CNI egress policy from `workload` to `qdrant` in `services` |
| `k8s/traefik-security-configmap.yaml` | Traefik router, `qdrant-stripprefix` middleware, and backend service |
| `scripts/verify-qdrant.sh` | Gate C locked verification probe for Qdrant stack |
| `.pi/extensions/aidlc-harness.ts` | Encode feature-branch & model-tiering reminders into AI-DLC harness |
| `docs/aidlc/decisions/0006-two-tier-llm-routing-and-token-quota.md` | Record proposed ADR 0006 (deferred to WP09-B pending GPU arrival) |

## Implementation Plan (Bundled for Gate A+B)
1. **Storage & StatefulSet Manifests (`k8s/qdrant/`):**
   - Author `k8s/qdrant/01-storage.yaml` provisioning `qdrant-data-pv` and `qdrant-data-pvc` (`20Gi`, `ReadWriteOnce`, `/mnt/storage/qdrant`).
   - Author `k8s/qdrant/02-statefulset.yaml` deploying `qdrant/qdrant:v1.12.6` on `ai-worker1` with `4Gi` memory limit, `/qdrant/storage` volume mount, `/readyz` & `/healthz` probes, and `qdrant` ClusterIP service on ports `6333` and `6334`.
2. **NetworkPolicy & Traefik Gateway (`k8s/network-policies/allow-qdrant-egress.yaml`, `k8s/traefik-security-configmap.yaml`):**
   - Author `allow-qdrant-egress.yaml` allowing `workload` pods to reach `app.kubernetes.io/name: qdrant` in `services` on TCP `6333` and `6334`.
   - Add `qdrant` router (`PathPrefix('/qdrant')` with `qdrant-stripprefix` and `PathPrefix('/dashboard')`) and `qdrant-backend` (`http://qdrant.services.svc.cluster.local:6333`) to `k8s/traefik-security-configmap.yaml`.
3. **Verification Probe (`scripts/verify-qdrant.sh`):**
   - Validate all manifests with `kubeconform` and `bash -n` (Stage 1) and live cluster execution (Stage 2).

## Acceptance criteria
1. **Happy Path (Service Readiness, Vector Upsert & Cosine Search from `workload`):**
   - Given the `qdrant` StatefulSet running in `services` on `ai-worker1` and `allow-qdrant-egress` applied in `workload`,
   - When an ephemeral student pod in `workload` creates a collection (`size: 4, distance: Cosine`), upserts test vectors, and queries `POST /collections/{name}/points/search`,
   - Then Qdrant returns `HTTP 200 OK` with `"status": "ok"`, matches the nearest neighbor vector (`id: 1`) as top-1 result, and persists collection data under `/mnt/storage/qdrant/collections/`.
2. **Failure/Boundary Rejection (Database & Arbitrary Port Isolation Preserved):**
   - Given a student pod running in the `workload` namespace with `allow-qdrant-egress` active,
   - When the pod attempts to connect to `mlflow-postgres.services.svc.cluster.local:5432` or an unexposed port on `qdrant.services.svc.cluster.local` (e.g., port `9090`),
   - Then the CNI NetworkPolicy drops the TCP SYN packets (`nc -z -w 3` exits non-zero), proving zero lateral leakage to backend RDBMS or unexposed ports.
3. **Integration Contract (Traefik Reverse Proxy & Zero GPU Footprint):**
   - Given `k8s/traefik-security-configmap.yaml` updated with the `qdrant` router and `qdrant-stripprefix` middleware,
   - When a client requests `https://127.0.0.1:443/qdrant/healthz` and `https://127.0.0.1:443/qdrant/dashboard` via the Traefik gateway,
   - Then Traefik returns `HTTP 200` with `healthz check passed` and the Qdrant Web UI HTML, and the `qdrant-0` pod spec requests `0` `nvidia.com/gpu` resources.

## Open questions
- All 3 strategic decisions resolved by Khem during Phase 1 Inception:
  1. Expose internally (`:6333`/`:6334`) and via Traefik `/qdrant` + `/dashboard`.
  2. Shared classroom access governed by CNI NetworkPolicy (no static API key).
  3. 4Gi RAM limit / 20Gi PVC pinned to `ai-worker1`.

## Test / Verification plan (Locked at Gate C)
- **Stage 1 (Fast Static & Schema Checks):**
  - `bash -n scripts/verify-qdrant.sh`
  - `kubeconform -ignore-missing-schemas -schema-location default k8s/qdrant/01-storage.yaml k8s/qdrant/02-statefulset.yaml k8s/network-policies/allow-qdrant-egress.yaml k8s/traefik-security-configmap.yaml`
- **Stage 2 (In-Cluster Verification Probe):**
  - `bash scripts/verify-qdrant.sh` (9 automated assertions covering StatefulSet readiness, network isolation negative proof, internal REST `/healthz`, Traefik `/qdrant/healthz` & `/qdrant/dashboard`, vector collection creation, point upsert, similarity query, and storage persistence).

## Bolt log
- 2026-11-12: Phase 1 Inception (`analyze-gap`) completed; 3 strategic decisions confirmed by Khem. Switched to `feat/wp14a-qdrant-vector-db`, drafted unit spec `docs/aidlc/units/wp14a-qdrant-vector-db.md`, and completed Red-Team `audit-spec` review.
