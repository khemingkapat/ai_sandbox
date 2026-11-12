# 0006 — Two-Tier LLM Architecture: Central Token-Capped Gateway and Stateless Project Routers

Date: 2026-11-12
Status: proposed

## Context
Unit WP09 established an initial central LLM inference capability using a single vLLM deployment behind Traefik Ingress with ForwardAuth verification. While functional for single-model smoke tests, scaling to real student workloads—particularly autonomous coding agent harnesses (such as Pi, Aider, Cursor, and OpenCode)—reveals three core architectural gaps:

1. **Quota Gaming via Project Pools:** Allowing project-based token pools managed at the central server creates an unpoliced Sybil exploit: students can create arbitrary dummy projects to multiply their free token grants.
2. **Homogeneous Serving vs. Agent Workflows:** Coding agents thrive on a tiered model strategy (a fast, low-latency model for routine edits/linting/planning, paired with a high-capability model for complex architecture, deep debugging, and hard reasoning). A single model cannot satisfy both latency and reasoning demands within our compute envelope.
3. **Hardware Boundaries (Single L40 48GB VRAM):** The cluster dedicates GPU #1 (NVIDIA L40, 48GB VRAM) to central inference. Serving two models simultaneously without multi-instance GPU (MIG) hardware partitioning requires precise VRAM allocation and strict request concurrency gating to prevent Out-Of-Memory (OOM) crashes and KV-cache starvation.

## Decision

We adopt a **Two-Tier LLM Architecture** that strictly decouples central identity/token accounting from project-level routing and resource pooling.

### 1. Tier 1: Central Cluster LLM Service (Identity, Token Bank & Dual Serving)
- **Deployment:** A central LiteLLM Proxy backed by a lightweight PostgreSQL instance deployed in the `services` namespace, exposed through Traefik Ingress.
- **Two-Level Ingress Defense:**
  - **Level 1 (Traefik Ingress):** Wire-level defense. Enforces strict IP-based burst rate limits and maximum concurrent inflight connections (`vllm-inflight`, `vllm-ratelimit`) to drop runaway client loops (e.g., buggy `while True:` agent scripts) in microseconds before hitting Python/Postgres processes.
  - **Level 2 (LiteLLM Proxy):** Identity and token accounting. Validates incoming Bearer keys (`sk-...`) against PostgreSQL, checks user budget ceilings, tracks token usage metrics emitted by vLLM, and enforces model RBAC.
- **Strict Student-Centric Quotas (No Central Project Pools):**
  - Quotas are pinned solely to authenticated Student IDs (`user_id`), modeled after our POSIX home directory and Slurm fairshare isolation.
  - Each student is granted an individual monthly/weekly token budget (e.g., 2,000,000 tokens).
  - Students can generate multiple virtual API keys (`sk-student-xxx`) for different tools (Pi, Cursor, CLI), but all keys spend against that single student's balance.
  - Central LiteLLM maintains zero knowledge of student group rosters, eliminating central project administration overhead and quota-minting exploits.
- **Dual-Model Inference Allocation on GPU #1 (48GB L40):**
  - **Fast Tier (e.g., Qwen-2.5-Coder-7B-Instruct):** ~14GB FP16 weights + 4GB KV Cache = **~18GB VRAM**.
  - **Smart Tier (e.g., Qwen-2.5-Coder-32B-Instruct AWQ/INT4):** ~18GB weights + 8GB KV Cache = **~26GB VRAM**.
  - **Combined Footprint:** ~44GB / 48GB.
  - **Concurrency Gating:** LiteLLM enforces `max_parallel_requests` and strict `max_model_len` (16k/32k tokens) to ensure dual KV-cache stability on physical hardware.

### 2. Tier 2: Project-Level Client Router (Student Key Pooling & BYOK Fallback)
- **Deployment:** A stateless LiteLLM CLI process (`litellm --config team-router.yaml`) executing directly within the student team's environment (local workstation, dev container, or interactive project workspace).
- **Stateless Operation:** Operates entirely from a local 15-line YAML file with zero database, zero Redis, and zero web UI overhead (~60MB RAM footprint).
- **Quota Pooling & Failover:**
  - Student project teams combine their individual university API keys into a single upstream model pool:
    ```yaml
    model_list:
      - model_name: team-smart
        litellm_params:
          model: openai/cluster-smart
          api_base: https://llm.cluster.uni.edu/v1
          api_key: os.environ/ALICE_KEY
      - model_name: team-smart
        litellm_params:
          model: openai/cluster-smart
          api_base: https://llm.cluster.uni.edu/v1
          api_key: os.environ/BOB_KEY
    ```
  - The project router load-balances across active team members.
  - When a student's quota exhausts (HTTP 429), the router automatically fails over to the next teammate's key without crashing the agent.
- **Bring-Your-Own-Key (BYOK) External Fallback:**
  - If all teammates exhaust their institutional quota, the project router transparently diverts to an external cloud key (e.g., Google Gemini 2.0 Flash) configured by the team, maintaining uninterrupted agent workflows.

## Alternatives Considered

- **Centralized Project Pools in Central LiteLLM:** Rejected. Enables quota gaming through dummy project creation and requires continuous manual administrator intervention to adjust group memberships.
- **Allowing Student Dynamic Routing inside Central LiteLLM:** Rejected. LiteLLM lacks sandboxed multi-tenant configuration; granting students permission to define routes requires Admin privileges, exposing cluster secrets and global model endpoints.
- **Traditional Reverse Proxies (Nginx / OpenResty / Traefik) for Project Tier:** Rejected. Nginx cannot rotate `Authorization: Bearer` credentials on HTTP 429 retry without complex custom Lua scripting. Furthermore, traditional proxies cannot translate OpenAI request schemas to native Gemini/Claude schemas for external BYOK fallbacks.
- **Single Monolithic Model Serving (e.g., 70B):** Rejected. Exceeds the 48GB VRAM capacity of a single L40 without aggressive quantization or offloading, and fails to provide the sub-second latency needed for agentic linting and planning cycles.

## Consequences

- **What this makes easier:**
  - **Airtight Quota Governance:** Sybil-proof accounting tied directly to student identity.
  - **Pedagogical Value:** Students actively learn distributed systems concepts: token economics, upstream load balancing, failover chains, and proxy configuration.
  - **Universal Tool Compatibility:** Any standard OpenAI-compatible tool (Pi agent, Cursor, Aider, LangChain, raw curl) functions seamlessly against both the central and project tiers.
  - **Operational Resilience:** Traefik shields the Python/PostgreSQL stack from client socket exhaustion and burst floods.
- **What this makes harder:**
  - Introduces a stateful PostgreSQL dependency in the `services` namespace for LiteLLM key storage.
  - Tight VRAM margins on GPU #1 require disciplined KV-cache tuning and concurrency caps.
- **Revisit Trigger:**
  - Provisioning of a second dedicated inference GPU, allowing independent allocation for Fast and Smart models without VRAM time-slicing.
