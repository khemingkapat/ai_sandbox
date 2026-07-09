# Interactive Tutorial Placement and Feasibility Research

This document evaluates the feasibility and trade-offs of embedding interactive tutorials within the central portal versus hosting them directly inside the local AI Sandbox.

---

## Research: Interactive Tutorial Placement and Feasibility

### Summary
Exposing an interactive, terminal-based tutorial inside the central portal that runs commands directly in the AI Sandbox is technically feasible using cross-origin `iframe` communication (`postMessage`) or WebSockets, but it introduces significant architectural, security, and latency complexities. Placing the interactive components directly inside the AI Sandbox (with simple markdown/read-through documentation on the central portal) is the recommended path. This design dramatically simplifies security, guarantees low latency, and reduces development overhead.

### Key Findings
| Question / Criterion | Finding & Feasibility |
|---|---|
| **Feasibility of Central Portal hosting Interactive Tutorial** | **Low-to-Medium Feasibility.** To run commands directly in the AI Sandbox from a central portal page, we would need to embed the AI Sandbox UI (or its terminal via `xterm.js`) using an `iframe`, or establish a direct WebSocket connection from the user's browser in the central portal to a backend daemon in the AI Sandbox. |
| **Security Risks of Central Portal hosting** | **High Risk.** Embedding terminals across domains requires loosening security headers. If the central portal has direct shell execution privileges on the AI Sandbox via cross-origin messaging, a compromise of the central portal or DNS could expose the entire AI Sandbox compute cluster to arbitrary command execution. |
| **Feasibility of Sandbox-localized Interactive Tutorial** | **High Feasibility.** The tutorial runs directly in the AI Sandbox portal. It has direct local access to the containerized shells, local file system, and Slurm cluster nodes under the same origin. |
| **Hybrid Approach (Read-Through + Redirection)** | **Highly Recommended.** The central portal hosts static, read-through guides or links. When a user wants to execute the hands-on labs, a link redirects them to the AI Sandbox (passing session state/SSO), where they interact with the terminal natively. |

### Pros of Localized Tutorial (Sandbox-side)
- **Reduced Attack Surface:** No need to expose raw shell access or WebSockets across different domains/origins.
- **Superior Latency:** Terminal keypresses and UI updates happen directly between the user's browser and the sandbox node, avoiding multi-hop routing through the central portal.
- **Decoupled Deployment:** We can update, break, or patch the interactive sandbox tutorials without having to redeploy or coordinate with the central portal team.

### Cons / Risks of Central Portal hosting
- **Cross-Origin Security Concerns:** Requires managing complex CORS, iframe sandbox attributes (`sandbox="allow-scripts"`), and verifying origins via `window.postMessage` to prevent clickjacking and XSS.
- **SSO & Auth Hurdles:** If the iframe requires authentication, users must be seamlessly authenticated into both the central portal and the backend AI Sandbox, requiring robust single sign-on (SSO) integration.

### Integration Complexity
*   **If on AI Sandbox (Recommended):** Low complexity. We can render markdown guides inside our portal UI next to a containerized terminal (e.g., using `xterm.js` connecting to a local container tty).
*   **If on Central Portal:** High complexity. Requires exposing WebSocket ingress points on the AI Sandbox to the public network, managing authentication tokens over WebSockets, and building cross-origin progress-tracking hooks.

### Sources
- [MDN Web Docs: window.postMessage](https://developer.mozilla.org/en-US/docs/Web/API/Window/postMessage) — Guidelines for secure cross-origin communication.
- [xterm.js Documentation](https://xtermjs.org/) — Reference on embedding web terminals securely.

---

## 👥 Use Case Scenarios

### Scenario 1: The Beginner on the Central Portal
This is the "low friction" use case. Imagine a student who is brand new to AI. They just want to see a simple script run and understand the basics. They don't want to be overwhelmed by technical concepts like "compute clusters," "Slurm partitions," or "storage mounts" right away.

*   **Why it fits:** A tutorial hosted directly on the Central Portal is the best fit here. It feels like a regular website, making it easy to start and much less intimidating for someone on their first day.

### Scenario 2: The Advanced User on the Localized Sandbox
This is the "full potential" use case. Imagine a student who is moving on to heavy AI training jobs. They need direct access to everything the system offers—Slurm commands for scheduling, their own local folders for data, and full Jupyter sessions.

*   **Why it fits:** A tutorial hosted inside the Localized Sandbox is better for this user. It places them exactly where they need to be to do real work, giving them hands-on experience with the professional tools they'll use every day.

---

## ⚖️ Trade-off Analysis (Simple Terms)

| Placement | Pros (The Good) | Cons (The Bad) |
| :--- | :--- | :--- |
| **Central Portal Tutorials** | Very easy to start. Welcoming to newcomers. Zero setup required. | Limited power. Cannot easily touch advanced cluster features or local files without a lot of complex technical "bridges." |
| **Localized AI Sandbox Tutorials** | Full access to everything (GPUs, Slurm, local storage). Exactly mirrors how the system works in the real world. | Can feel a bit intimidating or complex for a student on their very first day. |

### Recommendation: The Learning Journey
We recommend a "graduation" path for students:
1.  **Start on the Central Portal:** Provide a simple, interactive guide there to get their feet wet and build confidence.
2.  **Graduate to the Localized Sandbox:** Once they are ready for heavy workloads and real-world projects, move the tutorials into the Sandbox where they have full access to the cluster's power.

---

## Addendum: Constrained Demo Pod Approach (PR-Oriented)

### Context
Team lead feedback noted that the original "full interactive tutorial on the Central Portal" use case was somewhat moot in practice — the AI Sandbox itself is already easy enough to use that replicating a full interactive experience on the portal doesn't add much real value. However, there is a distinct, narrower use case worth pursuing: a lightweight, PR-oriented demo that gives newcomers (and external visitors) a tangible "it's really running on our cluster" moment directly on the Central Portal, without rebuilding the full interactive bridge originally evaluated above.

### Concept
Maintain **one persistent, isolated pod**, scheduled via **Slinky** on the HPC cluster, dedicated solely to demo purposes. The Central Portal exposes a small set of **pre-defined, allowlisted actions** — not a raw terminal — such as buttons for `sinfo`, `squeue`, or submitting a canned `sbatch` demo job. Clicking a button triggers a backend call that executes the *fixed* command against the demo pod and streams the output back to the portal UI as read-only text.

This is fundamentally different from the original "embed a terminal cross-origin" proposal: there is no raw input channel, no arbitrary command execution, and no user-supplied shell strings. That distinction is what changes the risk profile relative to the Key Findings and Cons sections above.

### Why This Sidesteps the Original Security Concerns
| Original Concern (Full Interactive Bridge) | Demo Pod Approach |
|---|---|
| Arbitrary shell execution cross-origin | Only a fixed, backend-validated command set (allowlist, no free-text input) |
| Complex `postMessage`/WebSocket auth | Simple authenticated REST call → backend → `kubectl exec` or `srun` on the pod |
| Compromise exposes whole cluster | Demo pod is isolated (separate namespace, no mounts to real user data, tight resource quotas, no credentials to production Slurm partitions) |
| SSO bridging between portal and sandbox | Can be anonymous/low-privilege — no real user session needed, since it's not touching a user's actual environment |

### Suggested Architecture
1.  **Demo Pod:** Persistent, lightweight, scheduled via Slinky in its own namespace with strict CPU/mem/GPU quotas — enough to run `sinfo`/`squeue` against a demo partition and accept one simple pre-baked `sbatch` script.
2.  **Backend API:** A thin service (not exposed to the pod directly) that receives an action ID (`"sinfo"`, `"squeue"`, `"submit_demo_job"`) from the portal, validates it against a server-side allowlist, executes it against the pod, and returns captured stdout/stderr.
3.  **Frontend (Central Portal):** Static markdown/read-through content with embedded buttons wired to the backend action IDs. Output rendered in a simple read-only console-style widget — no keystroke-level terminal emulation needed.
4.  **Job submission demo:** The "sbatch" button submits an already-authored trivial script (e.g., sleep + echo hostname) so users see the queue → run → complete lifecycle without needing custom job authorship.
5.  **Reset/idempotency:** Since it's shared and persistent, consider periodic cleanup of demo job history (cron or TTL) so `squeue` output doesn't accumulate stale entries indefinitely.

### Pros
- **Very low engineering lift** compared to the original cross-origin terminal bridge — no `xterm.js`, no WebSocket ingress, no SSO federation.
- **Drastically reduced attack surface** — command allowlisting removes the core risk that made the original Central Portal option "high risk."
- **Strong PR value** — newcomers get a tangible, clickable "look, it's really running on our cluster" moment directly on the portal, without needing an account or sandbox provisioning.
- **Decoupled from real user sandboxes** — the demo pod is disposable/replaceable and never touches actual user data or credentials.

### Cons / Considerations
- **Shared state:** since it's one persistent pod for everyone, concurrent demo usage could show other users' demo job output in `squeue` — worth deciding whether that's a feature ("look, others are trying it too!") or something to namespace/filter per-session.
- **Not representative of full power:** this remains a curated, cosmetic demo — it doesn't replace the "graduate to the real Sandbox" recommendation above for actual hands-on training.
- **Abuse potential:** even with allowlisted actions, a public-facing submit button needs basic rate-limiting to prevent someone spamming `sbatch` submissions.

### Updated Recommendation
This does not replace the original hybrid recommendation — it **refines** it. The "Beginner on the Central Portal" scenario (Scenario 1) can now be made concretely interactive (not just static reading) via this constrained demo pod, closing the gap the team lead identified, while the "Advanced User on the Localized Sandbox" scenario (Scenario 2) and the graduation-path recommendation remain unchanged.
