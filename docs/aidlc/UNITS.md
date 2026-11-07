# Units of Work

This table tracks completed baseline units and upcoming code-level bolts. High-level roadmap tracking lives on GitHub Projects (Project #6) and GitHub Issues.

| # | Unit | Parent GitHub WP | Capability it serves | Status | Verification & Notes / Historical Spec Pointers |
|---|------|------------------|----------------------|--------|--------------------------------------------------|
| WP01 | Environment Assessment | #1 | Platform Specs & Hardware Matrix | done | Verified in `docs/reports/M1_SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md` |
| WP02 | Capacity Planning | #2 | Quotas, Partitions & Sizing | done | Verified in `docs/reports/M1_SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md` |
| WP03 | Architecture & Tech Stack | #3 | Technology Selection (ADRs) | done | Consolidated into `docs/aidlc/decisions/0001..0004.md` |
| WP04 | Slinky Cluster Deployment | #4 | Slurm-on-K8s Orchestration | done | Verified by `scripts/verify-infrastructure.sh` |
| WP05 | Slurm Policy Configuration | #5 | Fairshare, Multi-node, Partitions | done | Verified in `values.yaml` and `slurm.conf` |
| WP06 | Container Environments | #6 | Interactive OCI & Apptainer Batch | done | Verified by `scripts/build-oci-images.sh` & Apptainer tests |
| WP07 | Shared Storage & Isolation | #7 | Central Storage & Datasets | done | Verified by `scripts/verify-storage.sh` |
| WP08 | Network & Security Baseline | #8 | NetworkPolicies, Traefik TLS | done | Verified by `scripts/verify-security.sh` & `verify-isolation.sh` |
| WP09 | LLM Inference Server | #9 | vLLM Deployment & Rate Limiting | done | Verified by `scripts/verify-llm.sh` (22/22 checks passing) |
| WP10 | Curated Model Catalog | #10 | Model Matrix & Deterministic Swap | done | Verified by `docs/MODEL_CATALOG.json` & `scripts/swap-model.sh` |
| WP11 | Experiment Tracking | #11 | Central MLflow & Proxied Artifacts | done | Verified by `scripts/verify-mlflow.sh` (9/9 checks passing) |
| WP17 | Integration Golden Path | #17 | End-to-End Student Smoke Test | done | Verified by `scripts/test-student-golden-path.sh` |
| WP12 | Web Portal Enhancements | #12 | Model Picker & Slurm Integration | planned | Core K8s/Slurm dispatch working in `portal/`; UI additions remaining |
| WP13 | Monitoring & Telemetry | #13 | Epilog Webhook & Ring Buffer | planned | Historical spec baseline: `git show pre-aidlc:docs/slurm_info_exchange_research.md` (§8) |
| WP14 | Qdrant Vector DB & Labs | #14 | Central Vector Search & Curricula | planned | Historical spec baseline: `git show pre-aidlc:docs/WP3-1-14_STARTER_LABS_AND_VECTOR_DB.md` |
| WP15 | Student Documentation | #15 | Onboarding & Usage Guides | planned | To be compiled from verified features |
| WP16 | Sysadmin Runbooks | #16 | Operations & Upgrades Runbook | planned | To be compiled from cluster procedures |
| WP18 | Early Adopter Pilot | #18 | Validation with Real Cohort | planned | Awaiting WP12–WP16 completion |

---

## Next up

The upcoming unit will be chosen and started tomorrow in direct partnership with Khem via **Phase 1: Inception & Plan (Gate A+B)**. Options:
- **Unit WP13 (Monitoring & Slurm Incident Telemetry)**
- **Unit CI01 (Dual-Path GitHub Actions & In-Cluster Runner)**
