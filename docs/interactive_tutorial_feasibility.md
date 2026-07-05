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
