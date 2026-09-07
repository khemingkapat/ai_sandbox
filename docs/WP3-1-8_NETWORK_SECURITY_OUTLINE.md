# WP3-1-8: Network & Security Baseline Architecture & Roadmap

## 1. Executive Summary

This document establishes the architectural baseline, threat model, and implementation specifications for **WP3-1-8: Network & Security Baseline** within the AI Sandbox.

While **WP3-1-7** established filesystem isolation via strict POSIX permissions (`700` project directories, `root`-owned shared caches), **WP3-1-8** establishes compute, network, and control-plane isolation. It ensures that untrusted student code running inside interactive JupyterLab or Bash sessions cannot compromise the cluster control plane, tamper with databases, sniff neighboring student traffic, or escalate privileges.

---

## 2. Threat Model & Security Guarantees

In a multi-tenant AI training sandbox, student workloads execute arbitrary user-submitted Python and bash code. The security baseline addresses four core attack vectors:

| Attack Vector | Vulnerability Without WP3-1-8 | WP3-1-8 Architectural Countermeasure |
| :--- | :--- | :--- |
| **Control-Plane Compromise** | Untrusted pods mount default ServiceAccount tokens and connect to MariaDB (`3306`) or the Kubernetes API server (`443`). | Set `automountServiceAccountToken: false` on student pods. Apply default-deny Egress `NetworkPolicy` dropping RFC 1918 traffic (MariaDB, K8s API, Slurm RPCs). |
| **Lateral Movement (Peer Sniffing)** | Pods share a flat Kubernetes overlay network; student A can port-scan and query student B's active session. | Multi-tenant `NetworkPolicy` denies all inter-pod traffic within the `workload` namespace. Ingress to session port `8888` is whitelisted exclusively from Traefik. |
| **Credential Eavesdropping** | Traefik serves user sessions over unencrypted HTTP (port 80). Session tokens and code are visible in transit. | Terminate TLS on port 443 with modern ciphers. Enforce automatic HTTP (80) to HTTPS (443) redirection and inject defense-in-depth security headers (`nosniff`, `SAMEORIGIN`). |
| **Over-Privileged Orchestrator** | The Go portal ServiceAccount (`portal-sa`) possesses cluster-wide `ClusterRole` with write access to `secrets` and `nodes`. | Downgrade `portal-sa` to scoped `Role` and `RoleBinding` objects limited to `workload` (and read-only endpoints in `slurm`). Completely remove `nodes` and `secrets` verbs. |

---

## 3. Network Architecture & Traffic Matrix

```mermaid
flowchart TD
    subgraph Internet ["🌐 Public Internet / Campus Network"]
        Browser["🧑 Student Browser"]
    end

    subgraph Cluster ["☸️ Kubernetes Cluster"]
        subgraph IngressLayer ["🚪 Ingress & Control Plane (Namespace: slurm)"]
            Traefik["Traefik Reverse Proxy<br/>Ports: 80 (Redirect), 443 (TLS)"]
            Portal["Go / Echo HPC Portal<br/>Port: 8080"]
            SlurmCtrl["Slurm Controller & Bridge<br/>(slurmctld / slurm-bridge)"]
            MariaDB["MariaDB Accounting<br/>Port: 3306"]
            Registry["Local OCI Registry<br/>Port: 5000"]
        end

        subgraph WorkloadLayer ["🛡️ Isolated Sandbox (Namespace: workload)"]
            StudentA["Session Pod (User 1)<br/>Port: 8888<br/>automountToken: false"]
            StudentB["Session Pod (User 2)<br/>Port: 8888<br/>automountToken: false"]
        end

        subgraph KubeSystem ["⚙️ Kube-System"]
            CoreDNS["CoreDNS<br/>Port: 53 (UDP/TCP)"]
        end
    end

    Browser -->|HTTPS 443| Traefik
    Traefik -->|Proxy to :8888| StudentA
    Traefik -->|Proxy to :8888| StudentB
    Traefik <--> Portal

    StudentA -.->|❌ BLOCKED by NetworkPolicy| MariaDB
    StudentA -.->|❌ BLOCKED by NetworkPolicy| StudentB
    StudentA -.->|❌ BLOCKED by NetworkPolicy| SlurmCtrl

    StudentA -->|✅ ALLOWED Egress| CoreDNS
    StudentA -->|✅ ALLOWED Egress| Registry
    StudentA -->|✅ ALLOWED Egress (Public Only)| Internet
```

### Comprehensive Traffic Matrix

| Source | Destination | Protocol / Port | Policy | Architectural Purpose |
| :--- | :--- | :--- | :--- | :--- |
| External Browser | Traefik | TCP 80 | **Allow (Redirect)** | Redirects all plain HTTP requests to HTTPS (443). |
| External Browser | Traefik | TCP 443 | **Allow (TLS)** | Encrypted HTTPS access to portal and proxied interactive sessions. |
| Traefik (`slurm`) | Session Pod (`workload`) | TCP 8888 | **Allow (Ingress)** | Whitelisted reverse-proxy traffic to student workspaces. |
| Session Pod (`workload`) | CoreDNS (`kube-system`) | UDP/TCP 53 | **Allow (Egress)** | Internal service discovery and external DNS resolution. |
| Session Pod (`workload`) | Registry (`slurm`) | TCP 5000 | **Allow (Egress)** | In-cluster OCI registry access for base images. |
| Session Pod (`workload`) | Public Internet (`0.0.0.0/0`) | Any | **Allow (Egress)** | `pip install`, `git clone`, external API/model downloads. |
| Session Pod (`workload`) | RFC 1918 Private CIDRs | Any | **DROP (Blocked)** | Blocks probing internal cluster node IPs, VPC hosts, and LAN. |
| Session Pod (`workload`) | MariaDB (`slurm:3306`) | TCP 3306 | **DROP (Blocked)** | Protects Slurm accounting database from direct tampering. |
| Session Pod (`workload`) | Slurm Daemons (`slurm:6817-6818`)| TCP 6817, 6818 | **DROP (Blocked)** | Prevents unauthorized Slurm RPC injection. |
| Session Pod A (`workload`) | Session Pod B (`workload`)| Any | **DROP (Blocked)** | Prevents cross-tenant attacks between active student sessions. |

---

## 4. Sub-Package Roadmap & Deliverables

WP3-1-8 is broken down into four modular sub-work-packages to enable staged development, testing, and asynchronous execution with Jules.

### Phase 1: Foundation (Completed)

#### ✅ WP3-1-8-1: Namespace Isolation & RBAC Hardening
* **GitHub Issue:** [#70](https://github.com/khemingkapat/ai_sandbox/issues/70)
* **PR:** [#74](https://github.com/khemingkapat/ai_sandbox/pull/74) (Merged into `feat/net_sec`)
* **Deliverables:**
  1. `k8s/namespaces.yaml`: Declarative namespace definitions with standard metadata labels (`sandbox.zone: control-plane` and `sandbox.zone: workload`).
  2. `k8s/portal-rbac.yaml`: Replaces cluster-wide `ClusterRole` with scoped `Role` / `RoleBinding` manifests in `slurm` and `workload`. Strips all permissions for `nodes` and `secrets`.
  3. `portal/session_manager.go`: Sets `AutomountServiceAccountToken: &falseVal` on session pod specs and adds standard zone/component labels.
  4. `scripts/start-slinky.sh`: Integrates declarative namespace and hardened RBAC bootstrap.

---

### Phase 2: Isolation & Hardening (Completed)

#### ✅ WP3-1-8-2: Kubernetes NetworkPolicies for Workload Isolation
* **GitHub Issue:** [#71](https://github.com/khemingkapat/ai_sandbox/issues/71)
* **PR:** [#76](https://github.com/khemingkapat/ai_sandbox/pull/76) (Merged into `feat/net_sec`)
* **Deliverables:**
  1. `k8s/network-policies/default-deny-workload.yaml`: Zero-trust drop for all Ingress/Egress in `workload`.
  2. `k8s/network-policies/allow-dns-egress.yaml`: Egress to CoreDNS on port 53.
  3. `k8s/network-policies/allow-traefik-ingress.yaml`: Ingress to port 8888 strictly from `app: hpc-portal` in namespace `slurm`.
  4. `k8s/network-policies/allow-registry-egress.yaml`: Egress to local registry on port 5000.
  5. `k8s/network-policies/allow-internet-egress.yaml`: Egress to `0.0.0.0/0` with RFC 1918 exceptions (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
  6. `scripts/start-slinky.sh`: Applies `k8s/network-policies/` on cluster initialization.

#### ✅ WP3-1-8-3: Traefik Ingress TLS & Security Headers
* **GitHub Issue:** [#72](https://github.com/khemingkapat/ai_sandbox/issues/72)
* **PR:** [#75](https://github.com/khemingkapat/ai_sandbox/pull/75) (Merged into `feat/net_sec`)
* **Deliverables:**
  1. `scripts/generate-certs.sh`: Script generating multi-SAN self-signed certificates for `localhost`, `127.0.0.1`, and `*.sandbox.local`, saved to Secret `traefik-tls-cert`.
  2. `k8s/traefik-security-configmap.yaml`: Declarative Traefik dynamic configuration with default TLS store and security headers middleware (`nosniff`, `SAMEORIGIN`, `browserXssFilter`).
  3. `k8s/portal-deployment.yaml`: Exposes port 443 on Traefik and Service `portal`, mounts TLS certs and security config, configures HTTP-to-HTTPS redirect.
  4. `scripts/start-slinky.sh`: Executes certificate generator and applies security config.

---

### Phase 3: Automated Verification (Completed)

#### ✅ WP3-1-8-4: Network & Security Verification Test Suite
* **GitHub Issue:** [#73](https://github.com/khemingkapat/ai_sandbox/issues/73)
* **Status:** Verified (7/7 tests passed)
* **Branch Target:** `feat/net_sec`
* **Deliverables:**
  1. `scripts/verify-security.sh`: Automated bash test suite that validates:
     - `portal-sa` cannot read nodes or secrets.
     - Workload pods have no mounted ServiceAccount tokens.
     - TCP connections from `workload` to MariaDB (`3306`) time out.
     - Inter-pod TCP connections within `workload` time out.
     - Traefik port 80 redirects to 443, and port 443 serves valid TLS with security headers.
     - Automatic trap cleanup of all ephemeral test pods on completion.

---

## 5. Development & Branching Strategy

To prevent merge conflicts and contract drift between asynchronous Jules tasks:

1. **Integration Branch:** All work occurs on `feat/net_sec` (branched from `development`).
2. **Pipelined Execution:**
   - **Step 1:** Jules implements **#70 (WP3-1-8-1)**. Antigravity and Khem review the PR and merge to `feat/net_sec`.
   - **Step 2:** Antigravity activates **#71 (WP3-1-8-2)** and **#72 (WP3-1-8-3)** concurrently via `gh issue edit --add-label jules`. Because they modify mutually exclusive files (`network-policies/` vs `portal-deployment.yaml`), Jules can execute both in parallel without conflict.
   - **Step 3:** Antigravity triggers or executes **#73 (WP3-1-8-4)** locally against Kind to verify packet drops and TLS handshakes.
   - **Step 4:** Merge `feat/net_sec` into `development`.
