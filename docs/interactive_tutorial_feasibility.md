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
