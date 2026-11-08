# Unit: CI01 — Dual-Path CI/CD Pipeline & In-Cluster Runner

Status: done (Gate D)
Parent GitHub WP: CI01
Exploratory? no

## Intent
Establish a hardened dual-path continuous integration pipeline: Stage 1 delivers fast cloud-hosted linting, unit testing, schema validation, and lightweight Markdown/Mermaid syntax verification on GitHub PRs; Stage 2 provides serial, hardware-aware in-cluster verification executed by a dedicated, isolated on-premise runner on the Proxmox cluster network.

## Scope & Non-goals
- **In scope:**
  - GitHub Actions Stage 1 Cloud Workflow (`.github/workflows/stage1-cloud-ci.yaml`):
    - Path filtering for `portal/`, `scripts/`, `k8s/`, and `docs/`.
    - Go unit testing (`go test -race ./...`) and linting (`golangci-lint run`, `go vet ./...`).
    - Shell script syntax checking (`bash -n scripts/*.sh`, `shellcheck`).
    - Kubernetes manifest schema validation (`kubeconform -ignore-missing-schemas -schema-location default`, explicitly excluding `*values*.yaml` and `kind-config.yaml`).
    - Documentation formatting (`markdownlint-cli2`) and lightweight Mermaid syntax validation (pure parser without headless Chromium/Puppeteer).
  - GitHub Actions Stage 2 Cluster Workflow (`.github/workflows/stage2-cluster-ci.yaml`):
    - Dedicated isolated runner on Proxmox private network (`10.35.123.x`).
    - Concurrency lock (`concurrency: { group: cluster-verification, cancel-in-progress: false }`) with cleanup exit traps.
    - Explicit maintenance flag handling (`CLUSTER_GPU_MAINTENANCE: "true"|"false"`): fails if GPUs disappear unexpectedly; skips GPU suites with warning only when maintenance mode is explicitly declared.
    - Full Golden Path integration test (`scripts/test-student-golden-path.sh`) on `main` or manual `ci:run-e2e` label.
  - Hardened Proxmox runner setup documentation (`docs/ci/RUNNER_SETUP.md`).
- **Non-goals:**
  - Running self-hosted runner directly on developer's host workstation OS with personal SSH keys.
  - Installing heavy Actions Runner Controller (ARC) operator on K3s.
  - Automatic continuous deployment (verification pipeline only).

## Constraints and decisions to respect
- [ADR 0005: Dual-Path CI/CD and In-Cluster Runner Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0005-dual-path-ci-and-runner-architecture.md)
- [ADR 0003: Single L40 GPU Sharing and QoS](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md)
- Zero-leak cleanup: all Stage 2 scripts must implement `trap cleanup EXIT INT TERM`.

## Implementation Plan (Bundled for Gate A+B)
- **Approach:**
  1. **Stage 1 Cloud Pipeline:**
     - Configure `.github/workflows/stage1-cloud-ci.yaml` on `ubuntu-latest`.
     - Go job runs `go test -race ./...` and `golangci-lint run` (filtered to `portal/**`).
     - Shell job runs `bash -n scripts/*.sh` and `shellcheck` (filtered to `scripts/**`).
     - K8s job runs `kubeconform` ignoring missing CRD schemas and skipping Helm values.
     - Docs job runs `markdownlint-cli2` and a lightweight Node-based Mermaid AST syntax checker (zero browser downloads, executes in <10s).
  2. **Stage 2 In-Cluster Pipeline:**
     - Configure `.github/workflows/stage2-cluster-ci.yaml` targeting `runs-on: [self-hosted, local-cluster]`.
     - Read repository variable `CLUSTER_GPU_MAINTENANCE`. If `"false"` and `nvidia.com/gpu == 0`, fail immediately as an infrastructure regression. If `"true"`, run CPU baseline and skip GPU suites with explicit warning.
     - Ensure verification scripts reset modified Slurm partitions or test pods via exit trap handlers.
  3. **Documentation:**
     - Provide standalone setup instructions for provisioning an unprivileged Debian 12 LXC container on Proxmox for the runner.
- **Files to touch:**
  - `.github/workflows/stage1-cloud-ci.yaml` (new)
  - `.github/workflows/stage2-cluster-ci.yaml` (new)
  - `scripts/lint-mermaid.mjs` (lightweight AST syntax checker without Puppeteer) (new)
  - `docs/ci/RUNNER_SETUP.md` (updated with hardened LXC blueprint)
  - `docs/aidlc/decisions/0005-dual-path-ci-and-runner-architecture.md` (updated)
  - `docs/aidlc/UNITS.md` (status update)

## Acceptance criteria
Concrete, testable examples:

1. **Happy Path (Stage 1 Cloud PR Checks):**
   - Given a PR with valid Go code, scripts, manifests, and documentation,
   - When Stage 1 runs on GitHub Cloud (`ubuntu-latest`),
   - Then all jobs pass in under 60 seconds with zero cluster access needed.

2. **Failure Case A (Malformed Mermaid Syntax Rejected):**
   - Given a markdown document containing an unclosed bracket or invalid transition in a ````mermaid block,
   - When the Docs validation job runs,
   - Then `scripts/lint-mermaid.mjs` fails, outputs the exact file and line number, and blocks the PR.

3. **Failure Case B (Regression Shield — Unexpected GPU Disappearance):**
   - Given `CLUSTER_GPU_MAINTENANCE == false` and the GPU worker node is offline or driver is broken,
   - When Stage 2 hardware verification runs,
   - Then the job **fails immediately** with an explicit error (`FATAL: Expected GPU online but detected 0 nvidia.com/gpu`), preventing silent regressions.

4. **Maintenance Case (Scheduled GPU Maintenance):**
   - Given `CLUSTER_GPU_MAINTENANCE == true` (current state while GPU is borrowed),
   - When Stage 2 hardware verification runs,
   - Then it executes the CPU baseline verification suites, marks GPU assertions as `SKIPPED (Maintenance Mode Active)`, and exits cleanly.

5. **Security Boundary Enforcement:**
   - The runner daemon runs strictly in an isolated container under an unprivileged user; it has no access to developer SSH keys or personal credentials.

## Open questions
- None (audited and reconciled).

## Test / Verification plan (Locked at Gate C)
- Stage 1 Local Verification:
  - Run `scripts/lint-mermaid.mjs` against valid docs (must exit 0).
  - Run against a test file with intentionally broken Mermaid syntax (must exit non-zero).
  - Run `kubeconform` command locally against `k8s/` manifests.
- Stage 2 Cluster Verification:
  - Validate pre-flight GPU maintenance check logic.

## Bolt log (Updated at Gate D)
- 2026-11-08: Built and verified dual-path CI/CD pipeline:
  - Created `.github/workflows/stage1-cloud-ci.yaml` (Go test -race, Go vet, ShellCheck, bash -n, K8s manifest validation, and Python Mermaid AST validation).
  - Created `.github/workflows/stage2-cluster-ci.yaml` (Self-hosted runner with hardware maintenance flag gating).
  - Created `scripts/lint-mermaid.py` (lightweight AST parser, verified on all 21 markdown files and caught intentional syntax tests).
  - Created `scripts/lint-k8s.sh` (validated 24 K8s manifests).
  - Fixed Slurm CPU worker crashloop: scoped `gres.conf` to `NodeName=slurmd-gpu-0` in `slurm-config-extra`, bringing `slurmd-cpu-[0-1]` to 2/2 Running and IDLE state in Slurm.
  - Aligned `scripts/verify-storage.sh` with ADR 0002 (`chmod 2770` collaborative project permissions).
  - Executed `scripts/verify-ci-hardware.sh` against live cluster: Node fleet (3/3 Ready), Core DBs (MariaDB, Postgres, Slurmctld Running), Storage (6/6 PASS), Security (7/7 PASS). Full baseline exit code 0.
