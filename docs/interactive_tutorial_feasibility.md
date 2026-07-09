# Where to Put Interactive Tutorials: A Research Guide

This document looks at whether we should put interactive tutorials on the main central portal or keep them inside the local AI Sandbox.

---

## Research: Interactive Tutorial Placement and Feasibility

### Summary
Putting a fully interactive terminal on the main portal is possible, but it is complicated, slow, and risky for security. We recommend keeping the hands-on interactive parts inside the AI Sandbox instead. The main portal can just have simple text guides. This makes everything more secure, faster, and much easier to build.

### Key Findings
| Question / Criterion | Finding & Feasibility |
|---|---|
| **Can we host it on the Central Portal?** | **Hard to build.** We would have to connect the portal directly to the Sandbox using complex web tools to make the terminal work across different websites. |
| **Is it safe on the Central Portal?** | **High Risk.** Connecting different websites like this means we have to lower our security walls. If the main portal gets hacked, the whole cluster is at risk of being taken over. |
| **Can we host it inside the AI Sandbox?** | **Easy to build.** The tutorial lives right where the action happens, so it already has safe access to everything it needs without opening new security holes. |
| **The Hybrid Approach** | **Highly Recommended.** Users read the guides on the main portal, and when they are ready to type commands, they click a link that takes them directly into the AI Sandbox. |

### Pros of Localized Tutorial (Sandbox-side)
- **Safer:** We don't have to open up dangerous connections across the web.
- **Faster:** Typing and clicking happens instantly because you are directly in the Sandbox.
- **Easier to Update:** We can fix the tutorials without touching the main portal's code.

### Cons / Risks of Central Portal hosting
- **Security Nightmares:** We would have to write complex rules to stop hackers from tricking the system into running bad commands.
- **Login Problems:** Users would have to log into both systems at the exact same time without errors, which is hard to build smoothly.

### Integration Complexity
*   **If on AI Sandbox (Recommended):** Easy. We just show guides next to the terminal that is already there.
*   **If on Central Portal:** Hard. We have to open new network ports and build complex progress trackers to bridge the two systems.

### Sources
- [MDN Web Docs: window.postMessage](https://developer.mozilla.org/en-US/docs/Web/API/Window/postMessage) — Guidelines for secure cross-origin communication.
- [xterm.js Documentation](https://xtermjs.org/) — Reference on embedding web terminals securely.

---

## 👥 Use Case Scenarios

### Scenario 1: The Beginner on the Central Portal
This is the "low friction" use case. Imagine a student who is brand new to AI. They just want to see a simple script run and understand the basics. They don't want to be overwhelmed by technical concepts like "compute clusters," "partitions," or "storage mounts" right away.

*   **Why it fits:** A simple guide on the Central Portal is the best fit here. It feels like a regular website, making it easy to start and much less intimidating for someone on their first day.

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
1.  **Start on the Central Portal:** Provide a simple guide there to get their feet wet and build confidence.
2.  **Graduate to the Localized Sandbox:** Once they are ready for heavy workloads and real-world projects, move the tutorials into the Sandbox where they have full access to the cluster's power.

---

## Addendum: The Simple Demo Pod Idea

### Context
Our work has shown that the original idea of putting a full interactive terminal on the Central Portal isn't really needed—the AI Sandbox itself is already very easy to use. However, there is a smaller, better idea: a simple demo that lets people click a few buttons on the Central Portal to see something run on our cluster. This avoids the dangers of a full interactive terminal.

### Concept
We keep **one small, separate pod** running just for demos. The Central Portal will just have simple buttons like 'Check Status' or 'Run Demo Job'—not a raw terminal. Clicking a button sends a safe, pre-approved command to this pod and shows the text result. Because people can't type their own commands, it is much safer.

### Why This is Much Safer
| Original Worry (Full Terminal) | Why the Demo Pod is Better |
|---|---|
| Hackers running bad commands | We only allow a few safe, pre-approved button clicks. Nobody can type their own commands. |
| Complex login problems | A simple, hidden connection securely runs the safe command behind the scenes. |
| Taking over the whole cluster | The demo pod is locked away in its own tiny box with no access to real data or the main system. |
| Needing to log in twice | Anyone can click the demo buttons without even logging in. |

### Suggested Architecture
1.  **Demo Pod:** A tiny, isolated space just big enough to run the demo jobs. It is completely separated from real user data.
2.  **Backend API:** A safe middleman that makes sure the button clicks are allowed before running them.
3.  **Frontend (Central Portal):** Simple text and buttons on the main portal. No complicated terminal windows to manage.
4.  **Job submission demo:** The "run" button just submits a safe, pre-written job so people can see how it works instantly.
5.  **Automatic Cleanup:** The system automatically cleans up old demo runs so the history doesn't get messy.

### Pros
- **Very easy to build** compared to a full terminal.
- **Very safe** because we only allow specific buttons, completely removing the original security risks.
- **Looks great to visitors** because they can click and see real results instantly, without making an account.
- **Keeps real user data totally safe** since the demo is completely separate.

### Cons / Considerations
- **Shared space:** Everyone using the demo might see each other's jobs, which could be confusing.
- **Not the full experience:** It is just a quick, shiny demo. It doesn't replace the real Sandbox for actual work.
- **Spam prevention:** We need a limit so someone doesn't click the button a thousand times a second and slow things down.

### Updated Recommendation
This idea improves our plan. Beginners can play with the safe demo buttons on the Central Portal to learn the basics, while advanced users will still graduate to the real AI Sandbox for their heavy work. This gives us the best of both worlds safely.
