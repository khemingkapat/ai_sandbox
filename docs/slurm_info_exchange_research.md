# Slurm Info Exchange and Resource Monitoring Research

This document outlines the findings and strategies for exchanging telemetry, user behavior, and resource utilization data between the local AI Sandbox Slurm cluster and the central portal.

---

## Research: Slurm Info Exchange and Resource Monitoring with a Central Portal

### Summary
To monitor our AI Sandbox's Slurm cluster from a central portal, we can expose cluster-level telemetry, job queues, and detailed compute node/GPU resource utilization. This integration captures overall system health and individual user workloads, sending structured metrics back to the central portal. The maturity level of these solutions is high, leveraging established Prometheus exporters or native Slurm metric APIs.

### Key Findings
| Question | Finding |
|---|---|
| **Can we track user behavior and job logs?** | Yes. Slurm's native accounting database (`slurmdbd`) logs every job submission, execution time, allocated cores/GPUs, user identity, and completion status. Additionally, job completion plugins or Prolog/Epilog scripts can push webhooks directly to the central portal when jobs start or end. |
| **How can we monitor real-time resource usage?** | We can collect CPU, memory, and GPU usage metrics. The industry standard is deploying a Prometheus `slurm_exporter` (such as [SckyzO/slurm_exporter](https://github.com/SckyzO/slurm_exporter)) or using Slurm 25.11's built-in `metrics/openmetrics` plugin. These endpoints expose real-time resource allocations, node states, and active queues. |
| **How does data flow to the central portal?** | The central portal can either pull metrics by querying a Prometheus server running in the sandbox (via its HTTP API) or our sandbox can push summary statistics to the central portal's API using automated cron jobs, Slurm Epilog scripts, or direct event hooks. |

### Pros
- **High Visibility:** The central portal gains real-time tracking of idle vs. active compute capacity across all sandboxes.
- **Granular Accounting:** Enables tracking resource consumption (e.g., GPU hours) per user or project for quota management.
- **Non-Intrusive:** Leveraging Prometheus metrics or webhook-based Epilog scripts does not interfere with running Slurm jobs.

### Cons / Risks
- **Network Overhead:** Real-time metrics streaming can add network traffic between the sandbox cluster and the central portal if not aggregated.
- **Security & Authorization:** Need to secure the REST APIs or Prometheus endpoints using token authentication or mutual TLS to prevent unauthorized access to sandbox internals.

### Integration Complexity
Integrating this into our Slinky-based Kubernetes stack is moderately straightforward:
1. **Prometheus Stack:** We can deploy the Prometheus operator or a lightweight `slurm_exporter` pod inside our existing `slurm` namespace.
2. **Metrics Endpoint:** Expose a read-only endpoint via our local Traefik ingress controller, configured with basic auth or API tokens, which the central portal can query.
3. **Prolog/Epilog Webhooks:** Write a simple shell script in our Slurm controller that triggers a `curl` POST to the central portal whenever a job completes, sending job duration and resource stats.

### Sources
- [SchedMD Slurm Documentation](https://slurm.schedmd.com/) — Official guide on Slurm metrics plugins and job accounting database.
- [GitHub: SckyzO/slurm_exporter](https://github.com/SckyzO/slurm_exporter) — Details on exporting Slurm cluster status and resource usage to Prometheus/Grafana.

### Unified Telemetry via K8s-Slurm Bridge
Rather than maintaining separate telemetry systems for Kubernetes interactive sessions (Jupyter) and Slurm batch jobs, we successfully implemented a **unified queue** using Slinky's `slurm-bridge`. 
- **Queue Unification**: The bridge intercepts interactive K8s pods and automatically schedules them as native Slurm jobs on dynamically registered external nodes (`State=External`). 
- **Resource Sharing**: By configuring `OverSubscribe="YES"`, Slurm natively handles fractional resource allocation (CPU/Memory) on the shared K8s worker nodes, preventing node-locking.
- **Unified Telemetry**: Because all interactive Jupyter sessions exist as Slurm jobs, they natively emit telemetry, usage stats, and job state updates to the `slurmdbd` accounting database. The central portal can thus query a single source of truth (Slurm) to monitor both batch and interactive workload behaviors across the sandbox.
