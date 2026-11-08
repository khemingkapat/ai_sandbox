# 0002 — Storage Isolation, Identity & UID Security

Date: 2026-10-19  
Status: accepted  
Supersedes: OpenLDAP/SSSD centralized directory service proposal

## Context
Multi-tenant student environments require strict data isolation and permission boundaries across project teams. Traditional HPC systems bind every compute node to OpenLDAP/SSSD and Active Directory to synchronize UIDs and GIDs. In containerized Kubernetes and Kind/K3s nodes, maintaining LDAP client daemons, Kerberos tickets, and NSS caching across dynamic pods introduces high configuration drift, network failure modes, and operational fragility.

Furthermore, mounting root shared filesystems directly into student pods risks accidental data leakage or tampering with central service storage (e.g. MLflow artifacts, model registries).

## Decision
1. **Zero LDAP/SSSD:** Discard OpenLDAP/SSSD in favor of `libnss-extrausers`. User and group definitions are centralized in `/mnt/storage/common/etc/passwd` and `/group`, mounted read-only into `/var/lib/extrausers` inside container images.
2. **Scoped `subPath` VFS Mounts:** Student interactive pods **never** mount the root `/mnt/storage` volume. Instead, pods strictly mount 5 scoped `subPath` mappings:
   - `projects/<team-id>` (read/write workspace)
   - `scratch` (sticky-bit `1777` temporary scratch)
   - `datasets` (read-only `subPath` / `EROFS`)
   - `models` (read-only `subPath` / `EROFS`)
   - `common/etc` -> `/var/lib/extrausers` (read-only identity)
   Central infrastructure paths (such as `/mnt/storage/mlflow` and peer project directories) are completely hidden from the pod's mount namespace.
3. **Non-Root PodSecurityContext & Setgid Collaboration:**
   - Every pod dynamically injects `runAsUser: 1001`, `runAsGroup: 2001`, `fsGroup: 2001`, and `supplementalGroups`. This survives NFS `root_squash` safely.
   - Team directories enforce `chmod 2770` with `umask 0002`, ensuring all files created by team members inherit the project group ID for collaborative read/write while blocking unauthorized tenants.

## Consequences
- **Positive:** Zero runtime dependency on LDAP/SSSD services; predictable, deterministic POSIX security enforced at the Linux VFS layer; verified resistance to root escalation and tenant snooping.
- **Negative:** Adding a user requires appending to the central `passwd`/`group` file in storage rather than executing an LDAP API call.
- **Trigger for Revisiting:** If organization requirements mandate SAML/OIDC federated enterprise identity provisioning synchronized down to local Linux shell level.
