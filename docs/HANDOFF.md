# Handoff: AI Sandbox on Proxmox VMs (k3s), state as of 2026-09-20

**Goal:** run the repo `khemingkapat/ai_sandbox` (branch `development`, Slinky/Slurm-on-Kubernetes) on two university Proxmox VMs instead of the local Kind cluster it was developed against.

**Where things stand:** the infrastructure is ready and a bare 2-node k3s cluster is running. **Nothing from the repo has been deployed yet.** The next job is adapting the repo's Kind-specific pieces to this cluster.

**How to read this:** Sections 1-3 are things that were done and observed (mostly from console screenshots). Section 4 (the comparison) was written by an assistant that had **not** read the repo's scripts or manifests. It only saw the README and the text of PR #78 / issue #73. Treat section 4 as hypotheses to verify against the real files.

---

## 1. Environment

| Item | Value |
|---|---|
| Hypervisor | Shared university Proxmox cluster; VMs are on node `sandbox01` (other host: `sandbox02`). Other groups' VMs (`de-core`, `de-tenant`, `cb-linux`) share the cluster and the VLAN. |
| Admin confirmations | Free to create VMs on either host. GPU nodes are not provisioned yet. |
| Network | Both VMs on the same bridge, VLAN tag `123`, subnet `10.35.123.x`. Other groups' VMs are on the same LAN. |
| Storage network | `FAS8060-NFS` sits on an isolated storage network and cannot be mounted from the VMs. Workaround (per admin): a NAS-backed virtual disk attached to `ai-control`. |
| Access | **Proxmox web console only.** It has no copy-paste. SSH (port 22) is open, so SSH from a laptop is possible if it can reach the VLAN. |

## 2. What is built and verified

### VMs

| | `ai-control` (VM 103) | `ai-worker1` (VM 104) |
|---|---|---|
| IP | `10.35.123.50` | `10.35.123.51` |
| Resources | 4 cores / 16 GB RAM | 8 cores / 32 GB RAM |
| Boot disk | 32 GB (LV 30 GB, ~26 GB free) | **Grown to 64 GB** (LV 61 GB, ~56 GB free) |
| OS | Ubuntu Server 24.04.5, QEMU guest agent, swap disabled | Cloned from `ai-control`'s `ai-base` snapshot, then given a new hostname, machine-id, SSH host keys and static IP (cloud-init network management disabled) |
| Extra disk | 200 GB qcow2 (`vda`, ext4, discard on) | none |
| User | `admin_ai` (same UID on both) | `admin_ai` |

### Shared storage (verified working, files visible from both VMs)

- `ai-control`: 200 GB disk mounted at `/srv/shared-storage`, persisted in `/etc/fstab`, verified across a reboot. It is exported by `nfs-kernel-server`, restricted to the two VM IPs (not the whole subnet).
- `ai-control`: `/srv/shared-storage` is **bind-mounted onto `/mnt/storage`**. The fstab entry uses `x-systemd.requires-mounts-for=/srv/shared-storage` so the bind mount doesn't come up before the disk.
- `ai-worker1`: NFS client mount at `/mnt/storage`, persisted in fstab. Only TCP 2049 is open between the VMs and it works, so the mount should be NFSv4.
- Result: **`/mnt/storage` exists with identical content on both nodes.** This is the same path the repo's `hostPath` PV uses.
- Leftover test files on the share: `bind-test`, `from-worker.txt`, `test-after-ufw`. These can be deleted.

### Firewall (ufw, active on both, configured from the VM console)

- `ai-control`: allow 22/tcp from anywhere; allow 6443/tcp, 10250/tcp, 8472/udp and 2049/tcp from `10.35.123.51`; allow any from `10.42.0.0/16` and `10.43.0.0/16` (the k3s pod and service CIDRs).
- `ai-worker1`: allow 22/tcp from anywhere; allow 10250/tcp and 8472/udp from `10.35.123.50`; allow any from `10.42.0.0/16` and `10.43.0.0/16`.
- Defaults were set to deny incoming and allow outgoing. The `ufw status verbose` output was not captured. The routed default was left alone.
- **Ports 80/443 are not open** (the repo enables Traefik HTTPS on 443).
- The Proxmox-level firewall was not configured. Whether the admin has it enabled on the VLAN 123 NICs is unconfirmed, but node-to-node traffic on 6443/10250/8472 works, since the worker joined.

### Kubernetes: k3s v1.36.4+k3s1, both nodes `Ready`

- Server on `ai-control`, installed with `--disable traefik --node-ip 10.35.123.50`.
- Agent on `ai-worker1`, installed with `--node-ip 10.35.123.51 --token-file /etc/rancher/k3s/token` (a local root-only copy of the join token).
- The control plane is **not tainted** (default k3s), so ordinary pods can land on `ai-control`.
- Running system pods: `coredns`, `local-path-provisioner`, `metrics-server`. There is no Traefik.
- k3s defaults still in effect: flannel (VXLAN) CNI with the embedded NetworkPolicy controller, `local-path` default StorageClass, `servicelb` (Klipper) enabled, containerd runtime, no Docker on the VMs.
- kubeconfig is at `~admin_ai/.kube/config` on `ai-control` (a copy of `/etc/rancher/k3s/k3s.yaml`). Run `export KUBECONFIG=~/.kube/config` (or `source ~/.bashrc` if it was added) before using `kubectl`.
- `ai-worker1` carries the role label `worker`, and its `k3s-agent` service has a drop-in (`RequiresMountsFor=/mnt/storage`) so it starts after the NFS mount.
- `kubectl` comes from k3s. **Helm and git are confirmed not installed yet.**

### Snapshots (Proxmox)

- Both VMs: `pre-k8s` (2026-09-20, no RAM). It was taken after the firewall and bind mount were done and after the worker disk growth, and before k3s. The worker's was taken at 15:28 and `ai-control`'s at 15:30.
- `ai-control` also has `ai-base` (2026-09-15, with RAM), a clean Ubuntu install that predates the 200 GB disk and the NFS setup. `ai-worker1` has no `ai-base` because it is a clone.
- **A `k8s-ready` snapshot on both VMs was planned but is unconfirmed.** If it isn't there, take it before deploying anything from the repo.
- Snapshot rules: snapshot and roll back **both VMs together**. The `ai-control` snapshot includes the 200 GB disk, so a rollback also reverts everything on the shared storage.

## 3. Loose ends

**Done (confirmed by the user):**

- The join-token file was deleted from the shared storage (`/mnt/storage/k3s-token`).
- The worker's systemd drop-in is in place, so k3s waits for the NFS mount at boot. This only covers the worker booting. If `ai-control` reboots while the worker is running, the worker's `/mnt/storage` can still hang until the server is back.
- `ai-worker1` is labelled `node-role.kubernetes.io/worker=worker` and shows role `worker` in `kubectl get nodes`.

**Still open:**

1. **Helm and git are not installed** on `ai-control` (confirmed), and the repo has not been cloned. Suggested: `sudo snap install helm --classic`, `sudo apt install -y git`, then `git clone -b development https://github.com/khemingkapat/ai_sandbox.git`.
2. **The `k8s-ready` snapshots on both VMs are unconfirmed.** If they don't exist, take them before deploying anything from the repo. The worker goes first, then `ai-control`, with nothing writing to `/mnt/storage` and RAM off. The cluster now includes the label and the drop-in, so the snapshot should be taken after those.
3. The join token was shown on a console screenshot and pasted into a chat. This is low risk (6443 only accepts connections from the worker IP, and this is a test sandbox) but it should be rotated if the cluster becomes more than a test.

---

## 4. Repo local dev (Kind) vs this cluster

Source for the left column: the README on `development` plus the text of PR #78 and issue #73. Not read: `scripts/start-slinky.sh`, `kind-config.yaml`, `k8s/*`, `helm/slurm/*`, `values.yaml`, `portal/`, `traefik-dynamic/`, `images/`. Their contents are assumed from descriptions.

| Area | Repo local dev (Kind) | This cluster | What to check or change |
|---|---|---|---|
| Bootstrap | `kup` creates a Kind cluster from `kind-config.yaml`, then runs `scripts/start-slinky.sh`. Tools come from a Nix flake (`kind`, `kubectl`, `helm`). | k3s is already installed on 2 VMs. There is no Docker and no Nix. | `kup` won't work. Run only the "install onto an existing cluster" parts of `start-slinky.sh`. Strip anything Kind-specific (grep for `kind`, `docker`, `kind load`, hard-coded contexts such as `kind-*`, `extraPortMappings`). |
| Nodes | Kind nodes as Docker containers on one host. README diagram: 2 worker pods (`slurm-worker-0/1`), 1 controller. | 1 control-plane VM (untainted) and 1 worker VM (8c/32 GB). | Set NodeSet replicas and resource requests to fit one 8c/32 GB worker. Use nodeSelector/affinity to keep Slurm workers off `ai-control`. `srun -N2` in the README implies 2 worker pods on one node, so check that anti-affinity isn't required. |
| Shared storage | `extraMounts` of `./storage` onto `/mnt/storage` on every Kind node. `hostPath` PV `slinky-storage-pv` at `/mnt/storage`, RWX PVC `slinky-storage-pvc` in namespace `slurm`, and the pods mount it at `/mnt/storage`. | `/mnt/storage` already exists on both VMs with the same content (bind mount on control, NFS client on worker). | The PV should work **unchanged**. Set `hostPath.type: Directory`, not `DirectoryOrCreate`. If the NFS mount is ever missing at pod start, `DirectoryOrCreate` silently writes to the local disk instead of the share. Seed the repo's `storage/` contents (`projects/project1`, `common`) into `/srv/shared-storage`, and check file ownership/UIDs because of NFS squashing. |
| Default StorageClass | Kind's default (`standard`, local-path provisioner). | k3s `local-path` (default). | Grep the values and manifests for a hard-coded `storageClassName: standard` and change it to `local-path` (or remove it). local-path volumes live on the node's local disk under `/var/lib/rancher/k3s/storage` and are tied to the node where they were first scheduled. This matters for the controller state and MariaDB PVCs. |
| NetworkPolicy | PR #78 applies NetworkPolicies from `start-slinky.sh`. `scripts/verify-security.sh` (7 phases) starts probe pods in `workload` and expects, for example, that connecting to `mariadb.slurm.svc.cluster.local:3306` times out. It also checks `kubectl auth can-i` for `portal-sa`. | k3s enforces NetworkPolicy (ingress and egress) through flannel plus its embedded controller. | Check whether the script installs its own CNI or policy engine for Kind (for example Calico). If it does, **skip that** on k3s to avoid a conflict. Run `verify-security.sh` from `ai-control` against the k3s kubeconfig. |
| Ingress / Traefik | `traefik-dynamic/` exists. PR #78 mounts a Traefik security ConfigMap into the "dynamic provider directory" with a default portal router, and enables HTTPS on 443 with TLS and security headers. How Traefik is deployed (Helm, manifest, or a container next to Kind) is unknown. | Traefik is **disabled** on k3s (`--disable traefik`). `servicelb` is enabled. Ports 80/443 are not open in ufw. | Find out how the repo deploys Traefik and deploy it the same way. Decide how it is exposed (servicelb, NodePort or hostPort). Open 443 (and maybe 80) in ufw only for the networks that should reach the portal. The VLAN is shared with other groups, so don't expose it wider than needed. |
| Images | Probably loaded with `kind load docker-image` for the portal and any custom Slurm images (the repo has `portal/` and `images/`). This is inferred, not verified. | No Docker. k3s uses containerd, and each node pulls its own images. | Use a registry (GHCR, or a local one on `ai-control`) or `k3s ctr images import` on each node, and update the image references. `docker.io` works from the VMs (k3s pulled its system images). `ghcr.io` and the Slinky OCI chart registry have **not been tested**. |
| Slinky stack | Namespaces: `slinky` (operator), `slurm` (controller `slurm-controller-0`, workers, MariaDB, `portal-sa`), and `workload` (interactive session pods created by the Go portal). PR #78 also applies `k8s/namespaces.yaml`, namespace-scoped RBAC and pod labels. | Only the default k3s namespaces exist. | The script presumably installs cert-manager, the operator and the chart, since a bare Kind cluster has none of them. Verify that, and check that the installs work through the university network. |
| Slurm node registration | PR #78 mentions registering all compute workers as external Slurm nodes and adding an `interactive_qos` grant in `setup-accounting`. | Only one worker VM. | Check what "external nodes" means here and whether it needs changes for a single worker node. |
| Exposure and security | Everything is on localhost. | Anything exposed is reachable from other groups' VMs on VLAN 123. | Keep the ufw rules narrow. Portal authentication matters more here than on a laptop. |
| GPU | None. | None (not provisioned by the admin yet). | Nothing to do now. Later, the GPU nodes will need their own drivers and device plugin. |

## 5. Suggested order of work

1. Close the open items in section 3, especially: confirm (or take) a `k8s-ready` snapshot on both VMs **before** anything from the repo is deployed.
2. Install Helm and git on `ai-control` (not done yet), clone `development`, and seed `storage/` into `/srv/shared-storage`.
3. Audit `scripts/start-slinky.sh`, `kind-config.yaml`, `k8s/pv-pvc.yaml`, the Helm values and the portal/Traefik deployment for the Kind-specific items in section 4.
4. Adapt and deploy step by step (namespaces, RBAC, PV/PVC, cert-manager, operator, Slurm chart, MariaDB/accounting, portal, Traefik). Check the pods after each step.
5. Run `scripts/verify-security.sh`, then the README job checks (`sinfo`, `srun -N2 hostname`, `ls /mnt/storage` from a `slurmd` container).
6. Snapshot both VMs again once it works.

## 6. Constraints and gotchas

- The person doing this works in the Proxmox web console, which **has no copy-paste**. Prefer short typed commands, or move files and long text through `/mnt/storage`. SSH from a laptop, if it can reach the VLAN, would fix this.
- Don't run ufw or other changes on the Proxmox host. Everything is configured inside the VMs.
- Don't roll back only one VM. Roll back both together, and remount and check `/mnt/storage` on the worker afterward.
- `ai-control` is the NFS server, the k3s control plane and the shared-disk holder all at once. If it reboots, the worker's `/mnt/storage` can hang until it comes back. The worker's `RequiresMountsFor` drop-in only helps when the worker itself boots.
- The 200 GB disk is included in `ai-control` snapshots. Don't keep the only copy of anything important on it.
- Ask before doing anything destructive or anything that needs the admin (Proxmox settings, the datacenter firewall, GPU nodes).
