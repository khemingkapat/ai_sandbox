## Spec: WP3-1-5 Configure Scheduling Policies

### Decision
Deploy `slurmdbd` backed by a `MariaDB` StatefulSet to enable native Fair-Share scheduling for students, dropping explicit QoS tiers (power-user, admin), and strictly enforce Slurm partition fencing rules for the L40 GPUs as defined in the Capacity Planning document, disabling preemption across the board.

### Scope
This spec covers the deployment of the Slurm accounting database (`slurmdbd` and `MariaDB`), configuring Slurm's fair-share algorithm in `slurm.conf`, and defining the four primary partitions (`interactive`, `batch-cpu`, `batch-gpu`, `inference`) with their respective resource fencing limits (`MaxTRESPerJob`). It does *not* cover Kubernetes NVIDIA device plugin configurations or Traefik API routing.

### Files to Create
| File | Purpose |
|---|---|
| `docs/WP3-1-5_SCHEDULING_SPEC.md` | This specification file. |
| `helm/slurm/templates/mariadb-statefulset.yaml` | Kubernetes StatefulSet and Service definition for the MariaDB backend required by `slurmdbd`. |
| `helm/slurm/templates/slurmdbd-deployment.yaml` | Kubernetes Deployment for `slurmdbd` to communicate with MariaDB and `slurmctld`. |

### Files to Modify
| File | Changes |
|---|---|
| `helm/slurm/values.yaml` | Add configurations to enable `slurmdbd` and define the four partitions (`interactive`, `batch-cpu`, `batch-gpu`, `inference`) with `PriorityTier` and `MaxTRESPerJob` constraints as per CAPACITY_PLANNING.md. |
| `helm/slurm/config/slurm.conf` | Enable `PriorityType=priority/multifactor`, `PriorityWeightFairshare`, and `AccountingStorageType=accounting_storage/slurmdbd`. Define the partitions with `PreemptMode=OFF`. |
| `docs/WORK_PACKAGES.md` | Update WP3-1-5 to point to this spec. |

### Files NOT to Touch
| File | Reason |
|---|---|
| `kind-config.yaml` | Local topology remains unchanged. |
| `portal/` source code | No changes to the portal are required for backend Slurm scheduling logic. |

### Acceptance Criteria
- [ ] `helm template` outputs valid Kubernetes manifests for MariaDB and `slurmdbd`.
- [ ] `slurm.conf` correctly reflects `PriorityType=priority/multifactor` and partition definitions for `interactive`, `batch-cpu`, `batch-gpu`, and `inference` matching the exact limits from Capacity Planning.
- [ ] `helm lint` passes for the slurm chart, validating the template syntax for the new MariaDB and slurmdbd resources without requiring a live cluster.
- [ ] No changes to files in "Files NOT to Touch".
- [ ] `INCREMENT_LOG.md` has a new entry for WP3-1-5 Scheduling Policies.

### Design Rationale
Dropping manual QoS tiers in favor of native Fair-Share scheduling simplifies cluster management and automatically penalizes resource hogs, which is ideal for a student sandbox. To enable Fair-Share, a persistent accounting database (`slurmdbd` + `MariaDB`) is mandatory. We disable preemption entirely to protect volatile student notebook states, relying instead on strict `MaxTRESPerJob` GPU fencing to ensure batch jobs never starve the interactive or inference queues.

### Open Questions
- Should the MariaDB storage utilize a dedicated persistent volume claim (PVC) with an external storage class, or is local host path sufficient for the local Kind development environment?
