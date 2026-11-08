# AI Sandbox Documentation Router

This repository separates documentation into three distinct functional areas:

## 1. Daily Development & Coding Agent Memory (`docs/aidlc/`)
**Target Audience:** Solo Developer (Khem) & Coding Agent (Antigravity)  
- [Project Context](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/PROJECT_CONTEXT.md) — 1-page current architecture, constraints, and test conventions.
- [Units of Work](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/UNITS.md) — Active and completed code-level units linked to parent GitHub Work Packages.
- [Working Agreement](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/WORKING_AGREEMENT.md) — Gate A+B, Gate C, Gate D, and 3-strike escalation rules.
- [Intent & Purpose](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/INTENT_AND_PURPOSE.md) — Core AI-DLC philosophy and operating principles.
- [Architecture Decisions](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/) — Concise 1-page records of architectural invariants.
- [Templates](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/TEMPLATES.md) & [Checklist](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/ADOPTION_CHECKLIST.md) — Standard formats for specs, ADRs, and health metrics.
- [Transformation Playbook (Temporary)](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/TRANSFORMATION_PLAYBOOK.md) — Legacy remediation protocol and `pre-aidlc` historical spec lookup (retire once legacy work is fully verified).

## 2. Academic Deliverables & Milestone Reports (`docs/reports/`)
**Target Audience:** University Supervisor & Academic Evaluators  
- [M1: System Assessment & Planning](file:///home/khemi/workspace/ai_sandbox/docs/reports/M1_SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md)
- [M2: Backend Deployment Report](file:///home/khemi/workspace/ai_sandbox/docs/reports/M2_BACKEND_DEPLOYMENT_REPORT.md)
- [M3: Central Services Closeout Report](file:///home/khemi/workspace/ai_sandbox/docs/reports/M3_CENTRAL_SERVICES_CLOSEOUT_REPORT.md)

## 3. Operational Runtime Catalogs (Root `docs/`)
**Target Audience:** Cluster automation scripts (`swap-model.sh`, `ingest-model.sh`, `verify-llm.sh`)  
- [MODEL_CATALOG.json](file:///home/khemi/workspace/ai_sandbox/docs/MODEL_CATALOG.json) — Active machine-readable serving and weight metadata.
- [MODEL_CATALOG.md](file:///home/khemi/workspace/ai_sandbox/docs/MODEL_CATALOG.md) — Human-readable serving catalog.
- [CANDIDATE_MODELS_BACKLOG.md](file:///home/khemi/workspace/ai_sandbox/docs/CANDIDATE_MODELS_BACKLOG.md) — Candidate models backlog for future evaluation.
