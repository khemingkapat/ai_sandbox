# 0005 — Dual-Path CI/CD and In-Cluster Runner Architecture

Date: 2026-11-08
Status: accepted

## Context
The AI Sandbox combines standard software artifacts (the Go Web Portal, shell scripts, Helm/K8s manifests, documentation) with specialized on-premise hardware infrastructure (a multi-node K3s cluster on Proxmox, Slinky Slurm operator, shared storage, and physical GPU nodes).

Cloud-hosted runners (GitHub `ubuntu-latest`) have no route to private subnet `10.35.123.0/24`. Conversely, executing hardware tests on every commit creates queue congestion, GPU VRAM contention, and delays developer feedback. Documentation heavily utilizes Mermaid diagrams, which historically experienced unverified syntax breakages.

An adversarial architectural audit revealed critical security hazards in running self-hosted runners directly on developer workstations (exposing developer SSH keys, local browser sessions, and unconstrained cluster-admin tokens to arbitrary PR execution), as well as the risk of "regression cloaking" if a missing GPU is silently skipped.

## Decision

1. **Dual-Path Pipeline Division:**
   - **Stage 1 (GitHub Cloud Runners — `ubuntu-latest`):** Executes on every push and pull request. Stateless, zero local cluster access required.
     - **Path-filtered matrix:**
       - `portal/**` -> `go test -race ./...`, `go vet ./...`, `golangci-lint run`.
       - `scripts/**` -> `shellcheck`, `bash -n scripts/*.sh`.
       - `k8s/**`, `helm/**` -> `kubeconform -ignore-missing-schemas -schema-location default` (filtering out `*values*.yaml`).
       - `docs/**/*.md`, `*.md` -> `markdownlint-cli2` and lightweight Mermaid AST parser (zero headless Chromium/Puppeteer overhead).
   - **Stage 2 (In-Cluster Runner on Dedicated Proxmox LXC/VM):**
     - Runs strictly inside an isolated Proxmox container on `10.35.123.x` as an unprivileged service user (`github-runner`).
     - Uses a scoped Kubernetes ServiceAccount with RBAC restricted to testing namespaces.
     - **Path-filtered targeted verification:** Changes to specific components trigger matching verification scripts (`verify-storage.sh`, `verify-security.sh`).
     - **Full Golden Path (`test-student-golden-path.sh`):** Reserved for merges to `main` or explicitly authorized PRs (`ci:run-e2e` label / `workflow_dispatch`).
     - **Strict Concurrency & Cleanup:** `concurrency: { group: cluster-hw-verification, cancel-in-progress: false }` combined with `trap cleanup EXIT INT TERM` in all test scripts.

2. **Hardware Gating & Anti-Regression Policy:**
   - CI must **never** silently auto-skip GPU tests upon detecting `0 nvidia.com/gpu`. Doing so cloaks driver/plugin regressions.
   - Hardware status is managed via an explicit GitHub repository variable: `CLUSTER_GPU_MAINTENANCE: "true"|"false"`.
   - When `"false"`, missing GPUs fail the build immediately.
   - When `"true"`, CI logs an explicit maintenance warning banner, skips GPU assertions, and verifies CPU/storage baselines.

3. **Elimination of Host Workstation Runner:**
   - Running self-hosted runners directly on developer workstations is prohibited due to the severe RCE and credential theft blast radius. Runners must live in isolated VMs/LXCs.

## Alternatives Considered

- **Workstation-hosted runner over SSH tunnel (`ptunnel`):** Rejected during architectural audit due to critical security risks (remote shell execution with developer credentials) and high flakiness (laptop sleep, tunnel drops).
- **Headless Chromium (`@mermaid-js/mermaid-cli`) for diagram linting:** Rejected due to Puppeteer bloat (170MB+ browser binary, 60s install time). Replaced with lightweight JS AST syntax validation.
- **Actions Runner Controller (ARC) on K3s:** Rejected as extreme over-engineering for a single-GPU testbed.

## Consequences

- **What this makes easier:** Rapid PR checks (<30s) without downloading heavy browser binaries. Safe, isolated execution of in-cluster hardware tests without endangering developer machines or cluster stability.
- **What this makes harder:** Requires provisioning a lightweight 2GB Debian LXC container on Proxmox once.
- **Revisit trigger:** Arrival of dedicated second GPU from sysadmin (enabling separation of Slurm batch and vLLM without time-slicing).
