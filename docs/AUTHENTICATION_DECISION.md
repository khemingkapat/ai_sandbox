# Authentication and User Management Decision

This document outlines the current state of user authentication and identity management within the HPC cluster, the scaling limitations of this approach, and the long-term architectural goal for production.

## 1. Current State: Flat-File extrausers (`libnss-extrausers`)

To avoid baking user accounts directly into immutable container images, the cluster currently relies on the `libnss-extrausers` package.

### How it Works
- Slurm worker nodes (containers) are configured via `/etc/nsswitch.conf` to append `extrausers` to their authentication lookups.
- This forces the OS to read from dynamically mounted flat files on a shared network drive:
  - `/mnt/storage/common/etc/passwd`
  - `/mnt/storage/common/etc/shadow`
  - `/mnt/storage/common/etc/group`
- When Slurm executes a batch job (e.g., `su user1`), Linux successfully authenticates the substitute user command by reading these shared files.

## 2. The Setup Nightmare (Why this won't scale)

While flat files are perfect for a sandbox or small team, they become a severe bottleneck and an administrative nightmare when scaling to 1,000+ users.

### The Gaps
1. **Manual File Management:** Every new user requires manual (or heavily scripted) appending to POSIX text files. A single formatting error in the `passwd` or `shadow` file can break authentication cluster-wide.
2. **UID/GID Synchronization:** POSIX permissions require strict UID and GID mapping. Ensuring there are no UID collisions across a large organization is tedious without a centralized database.
3. **No Automatic Provisioning:** Just adding a user to a text file doesn't create their home directory or set ownership. An administrator still has to run `mkdir` and `chown` for every user.
4. **Security & Auditing:** Flat files lack granular access control. Passwords (even disabled ones in the `shadow` file) and group memberships are not easily audited or integrated with standard enterprise security tools.

## 3. Future State: Slurm + OIDC (The "Userless" Approach)

For future production scale, we have decided to pursue **Approach 3: Slurm + OIDC (OpenID Connect)**. 

### The Concept
Instead of maintaining local POSIX users, the goal is to decouple execution from local Linux accounts entirely, relying on token-based authentication.
- **Identity Provider (IdP):** Users log in via a centralized IdP (e.g., Keycloak, Dex, or Auth0) which issues a JWT (JSON Web Token).
- **Token Passing:** The Web Portal passes this JWT directly to the Slurm REST API.
- **Slurm Integration:** Slurm uses `auth/jwt` to cryptographically verify the user's identity without ever checking local Linux files like `/etc/passwd`.
- **Dynamic Workspaces:** Instead of relying on static POSIX UIDs/GIDs for file permissions, the system would utilize containerized isolation (Apptainer/Docker namespaces) and dynamically mounted storage paths tied to the token's identity claims, effectively eliminating the need for strict Linux user management on the host nodes.

### Benefits
- Completely eliminates the need to manage `/etc/passwd` and `/etc/shadow`.
- Scales infinitely without administrative overhead.
- Native integration with modern cloud authentication flows.
