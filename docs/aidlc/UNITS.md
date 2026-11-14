# Units of Work

This table tracks completed baseline capabilities and upcoming work packages. High-level roadmap tracking lives on GitHub Projects (Project #6) and GitHub Issues; individual code bolts live in `docs/aidlc/units/` when active.

*(Note: When remediating pre-AI-DLC components or retrieving historical research drafts for planned units, see [`TRANSFORMATION_PLAYBOOK.md`](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/TRANSFORMATION_PLAYBOOK.md)).*

| # | Unit | Parent GitHub WP | Capability it serves | Status | Verification & Notes |
|---|------|------------------|----------------------|--------|----------------------|
| WP01 | Environment Assessment | #1 | Platform Specs & Hardware Matrix | done | Documented in `docs/reports/M1_SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md` |
| WP02 | Capacity Planning | #2 | Quotas, Partitions & Sizing | done | Documented in `docs/reports/M1_SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md` |
| WP03 | Architecture & Tech Stack | #3 | Technology Selection (ADRs) | done | Recorded in `docs/aidlc/decisions/0001..0004.md` |
| WP04 | Slinky Cluster Deployment | #4 | Slurm-on-K8s Orchestration | done | Verified by `scripts/verify-infrastructure.sh` |
| WP05 | Slurm Policy Configuration | #5 | Fairshare, Multi-node, Partitions | done | Verified in `k8s/values.yaml` and `scripts/verify-multi-user-jobs.sh` |
| WP05-B | Self-Service Identity & Project Sync | #5 | Dynamic Student UID/GID & Slurm Sync | planned | Implements ADR 0007; JWT login, Postgres state, `extrausers` + `slurmrestd` reconciler |
| WP06 | Container Environments | #6 | Interactive OCI & Apptainer Batch | done | Verified by `scripts/build-oci-images.sh` & Apptainer batch tests |
| WP07 | Shared Storage & Isolation | #7 | Central Storage & Datasets | done | Verified by `scripts/verify-storage.sh` |
| WP08 | Network & Security Baseline | #8 | NetworkPolicies, Traefik TLS | done | Verified by `scripts/verify-security.sh` & `scripts/verify-isolation.sh` |
| WP09 | LLM Inference Server | #9 | vLLM Deployment & Rate Limiting | done | Verified by `scripts/verify-llm.sh` (22/22 checks) |
| WP09-B | Two-Tier LiteLLM Gateway | #9 | Token Quotas & Student Key Pooling | planned | Implements ADR 0006; dual-model serving & LiteLLM proxy |
| WP10 | Curated Model Catalog | #10 | Model Matrix & Deterministic Swap | done | Verified by `docs/MODEL_CATALOG.json` & `scripts/swap-model.sh` |
| WP11 | Experiment Tracking | #11 | Central MLflow & Proxied Artifacts | done | Verified by `scripts/verify-mlflow.sh` (9/9 checks) |
| WP17 | Integration Golden Path | #17 | End-to-End Student Smoke Test | done | Verified by `scripts/test-student-golden-path.sh` |
| CI01 | Dual-Path CI/CD Pipeline | #0 | Cloud Linter + In-Cluster Runner | done | Verified locally & live cluster probe in `docs/aidlc/units/ci01-dual-path-pipeline.md` |
| WP12 | Web Portal Enhancements | #12 | Model Picker & Slurm Integration | planned | Core K8s/Slurm dispatch active in `portal/`; UI additions remaining |
| WP13-A | Health Telemetry & Swagger UI | #13 / #0 | Cluster Telemetry & OpenAPI | done | Verified by `portal/telemetry_test.go` with `-race` (8/8 checks) in `docs/aidlc/units/wp13-health-telemetry-swagger.md` |
| WP13 | Monitoring & Telemetry | #13 | Epilog Webhook & Ring Buffer | done | Verified by `portal/telemetry_test.go` with `-race` (15/15 checks) and `scripts/slurm_epilog_webhook.sh` in `docs/aidlc/units/wp13-slurm-epilog-webhook.md` |
| WP14-A | Central Qdrant Vector DB | #14 | Central Vector Search & Storage | done | Verified by `scripts/verify-qdrant.sh` (9/9 checks) in `docs/aidlc/units/wp14a-qdrant-vector-db.md` |
| WP14-B | Starter Labs & Tooling | #14 | Client SDKs & 5 Starter Curricula | done | Verified by `scripts/verify-starter-labs.sh` (10/10 checks) in `docs/aidlc/units/wp14b.md` |
| WP15 | Student Documentation | #15 | Onboarding & Usage Guides | planned | Student quickstart, tool catalog, and GPU usage guide |
| WP16 | Sysadmin Runbooks | #16 | Operations & Upgrades Runbook | planned | Cluster bootstrap, backup/restore, and incident playbook |
| WP18 | Early Adopter Pilot | #18 | Validation with Real Cohort | planned | Depends on WP12–WP16 completion |

---

## Next up

Candidate bolts for the next **Phase 1: Inception & Plan (Gate A+B)** cycle:
- **Unit WP13 (Monitoring & Slurm Incident Telemetry):** Epilog webhook (`scripts/slurm_epilog_webhook.sh`) and portal in-memory incident ring buffer.
- **Unit CI01 (Dual-Path CI/CD Pipeline):** Stage 1 GitHub Cloud static/unit checks + Stage 2 self-hosted in-cluster verification runner (`concurrency: 1`).
- **Unit WP09-B (Two-Tier LiteLLM Gateway & Student Token Quotas):** LiteLLM proxy in `services` namespace, per-student virtual keys/quotas, dual-model serving on GPU #1, and stateless project router documentation (see `docs/aidlc/decisions/0006-two-tier-llm-routing-and-token-quota.md`).
- **Unit WP00 (Interactive API & Cluster Documentation Tooling):** Portal OpenAPI/Swagger UI (`swaggo`) + Traefik dashboard & K8s topology tooling.
