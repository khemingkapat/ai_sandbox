# Incident Report: GPU Worker VM Architecture Blocker & LLM Inference Service Status

**Document ID:** INC-2026-10-04-GPU-VLLM-BLOCKER  
**Target Audience:** Project Supervisor, Infrastructure & Hypervisor Administrators, Senior Systems Architecture Team  
**Author:** AI Sandbox Engineering Team  
**Date:** October 7, 2026 (Updated)  
**Status:** RESOLVED (Verified Operational)

---

## Executive Summary

During the deployment of Phase 3 (**Central LLM Inference Service via vLLM** on the dedicated GPU node `ai-sandbox-gpu-vm`), container execution failed repeatedly with fatal segmentation faults during initialization.

Extensive systems diagnosis confirmed that:
1. **The physical GPU hardware is 100% operational:** The attached **NVIDIA L40 (46,068 MiB VRAM)** is recognized, passes all driver/NVML checks, and successfully runs CUDA kernels.
2. **Kubernetes GPU Time-Slicing is operational:** The node advertises `nvidia.com/gpu: 2` virtual slices to enable concurrent multi-tenancy (inference + Slurm jobs).
3. **The Root Blocker is at the Hypervisor CPU Layer:** The virtual machine was provisioned using a legacy virtual CPU model (`QEMU Virtual CPU 2.5+ / i440FX`) that **strips all modern x86_64 vector extensions (`avx`, `avx2`, `fma`)**.
4. **Impact:** High-performance AI runtimes (vLLM, NVIDIA UCX, PyTorch C++ extensions) require AVX/AVX2 instructions. Because the instruction set is masked by the hypervisor, low-level libraries abort immediately upon startup.

Resolution requires an administrative change on the hypervisor managing `ai-sandbox-gpu-vm` to enable **host CPU passthrough (`-cpu host`)**.

---

## Technical Failure Analysis

### 1. The Fatal Runtime Trace
Upon launching the vLLM pod (`vllm-7f9b789b85-bkgth`) on `ai-sandbox-gpu-vm`, the service identifies the model architecture and initiates communication/memory backends before crashing:

```text
(APIServer pid=1) INFO 10-04 08:58:40 [model.py:699] Resolved architecture: Qwen2ForCausalLM
(APIServer pid=1) INFO 10-04 08:58:40 [model.py:2109] Using max model len 16384
[vllm-7f9b789b85-bkgth:1] FATAL: UCX library was compiled with avx but CPU does not support it.
!!!!!!! Segfault encountered !!!!!!!
  File "<unknown>", line 0, in ucs_topo_cleanup
  File "<unknown>", line 0, in exit
  File "<unknown>", line 0, in ucs_init
```

The container restarts continuously, transitioning into `CrashLoopBackOff`.

---

### 2. Live CPU Audit on `ai-sandbox-gpu-vm`
Inspection of the virtual CPU topology via `/proc/cpuinfo` and `lscpu` reveals the underlying constraint:

```bash
$ lscpu
Architecture:          x86_64
Model name:            QEMU Virtual CPU version 2.5+
BIOS Model name:       pc-i440fx-11.0 CPU @ 2.0GHz
CPU family:            15
Model:                 107
Thread(s) per core:    1
Core(s) per socket:    16
Flags:                 fpu de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov
                       pat pse36 clflush mmx fxsr sse sse2 ht syscall nx lm
                       rep_good nopl xtopology cpuid extd_apicid tsc_known_freq
                       pni ssse3 cx16 sse4_1 sse4_2 x2apic popcnt aes hypervisor
                       lahf_lm cmp_legacy 3dnowprefetch vmmcall
```

```bash
$ grep -c 'avx' /proc/cpuinfo
0
```

#### Diagnostic Findings:
* **Missing Instructions:** `avx`, `avx2`, `fma`, `bmi1`, `bmi2` are completely missing.
* **CPU Model:** `cpu family: 15, model: 107` corresponds to a synthetic 2003-era AMD K8 QEMU CPU emulation profile.
* **Motherboard / Chipset:** `Standard PC (i440FX + PIIX, 1996)`.

Modern deep learning frameworks (PyTorch, Triton, vLLM, Intel MKL, and NVIDIA UCX) compile against the `x86-64-v3` architecture. When UCX performs initialization (`ucs_init`), it verifies CPU capabilities and terminates execution immediately if AVX instructions are absent.

---

### 3. GPU Hardware & Kubernetes Status (Verified Operational)

To ensure there were no secondary hardware or driver issues, diagnostics were executed directly against the GPU subsystem:

```bash
$ kubectl exec -n kube-system nvidia-device-plugin-daemonset-gpfb2 -- \
    nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader
NVIDIA L40, 595.91.07, 8.9, 46068 MiB
```

* **GPU Name:** NVIDIA L40 (Ada Lovelace, 48GB VRAM)
* **Driver Version:** `595.91.07`
* **Compute Capability:** `8.9`
* **Usable VRAM:** `46,068 MiB` (~45.0 GiB)
* **Kubernetes Time-Slicing:** Configured via `k8s/nvidia-device-plugin.yaml` to advertise `nvidia.com/gpu: 2` virtual slices.
* **Slurm Worker:** `slurm-worker-slurmd-gpu-0` is `2/2 Running` on the GPU node. Slurm job dispatching to the `batch-gpu` partition is functional.

---

## Action Plan & Remediation Request

Because `ai-sandbox-gpu-vm` is managed on a dedicated hypervisor outside the local tenant Proxmox cluster, the following remediation request must be completed by the infrastructure administrator:

### 1. Required Change: Host CPU Passthrough
Change the virtual CPU model from generic QEMU (`kvm64` / `qemu64`) to **`host`** (or `host-passthrough`).
* **Proxmox / KVM:** `Hardware` -> `Processor` -> `Type: host` (CLI: `qm set <VM_ID> -cpu host`).
* **libvirt / QEMU:** `<cpu mode='host-passthrough'/>`.
* **VMware ESXi:** Set VM Hardware Compatibility to latest version and ensure EVC does not mask AVX/AVX2 flags.

### 2. Recommended Change: Machine Type
Upgrade the virtual motherboard from legacy `i440fx` to **`q35`**.
* Modern PCIe bus topology is required for proper PCIe BAR allocation and DMA mapping on high-bandwidth datacenter accelerators (NVIDIA L40).

> **Important Operational Note:**  
> In QEMU/KVM hypervisors, hardware configuration changes (CPU Type and Machine Type) **do not take effect on a warm guest reboot (`sudo reboot`)**. A **cold power cycle** is strictly required:  
> `Shutdown (Power Off)` -> wait until stopped -> `Start (Power On)`.

---

## Post-Remediation Verification Procedure

Once the administrator completes the power cycle, verification can be conducted from within the VM or via Kubernetes:

```bash
# 1. Verify AVX instruction set visibility
lscpu | grep -iE 'avx|avx2'

# Expected output:
# Flags: ... avx avx2 fma ...
```

```bash
# 2. Check automatic recovery of vLLM pod
kubectl get pods -n slurm -l app=vllm

# Expected output:
# vllm-xxxx-xxxx   1/1   Running
```

---

## LLM Model Selection & Memory Architecture Assessment

In addition to the infrastructure blocker, an architectural analysis was conducted regarding candidate models for the dual-tenancy model (vLLM inference sharing VRAM with Slurm compute jobs):

| Candidate Model | Precision | Weight Footprint | vLLM Memory Cap | Slurm Leftover | Feasibility / Architecture Notes |
|:---|:---:|:---:|:---:|:---:|:---|
| **`Qwen/Qwen3.8-27B`** | BF16 | ~54 GB | N/A | 0 GB | **Physically Incompatible:** Exceeds physical L40 capacity (46GB). Immediate CUDA OOM on startup. |
| **`Qwen/Qwen3.8-27B-FP8`** | FP8 | ~27 GB | 0.75 (~34 GB) | ~11 GB | **Feasible but Tight:** Uses bleeding-edge `Qwen3_5ForConditionalGeneration` architecture (requires vLLM nightly/v0.32+). Leaves minimal VRAM for Slurm. |
| **`Qwen/Qwen2.5-32B-Instruct-AWQ`** *(Currently Staged)* | INT4 (AWQ) | ~18 GB | 0.65 (~29 GB) | **~16 GB** | **Optimal for Dual Tenancy:** Standard `Qwen2ForCausalLM` architecture with mature kernel support. Leaves a full standard 16GB VRAM partition for student Slurm jobs. |
| **`Qwen/Qwen2.5-14B-Instruct`** | FP16/FP8 | ~14–28 GB | 0.60 (~27 GB) | **~18 GB** | **High Throughput Alternative:** High token-per-second rate with substantial VRAM headroom for Slurm. |

---

## Summary of Completed Work Artifacts

1. [`k8s/nvidia-device-plugin.yaml`](file:///home/khemi/workspace/ai_sandbox/k8s/nvidia-device-plugin.yaml): 2-way GPU Time-Slicing with Slinky tolerations applied.
2. [`k8s/vllm-deployment.yaml`](file:///home/khemi/workspace/ai_sandbox/k8s/vllm-deployment.yaml): Production vLLM deployment manifest with memory utilization cap, shared NFS model cache mount (`/mnt/storage/models/huggingface`), `startupProbe` resilience, and Traefik `/v1` ingress.
3. [`docs/BACKEND_VERIFICATION_RUNBOOK.md`](file:///home/khemi/workspace/ai_sandbox/docs/BACKEND_VERIFICATION_RUNBOOK.md): Module 6 updated with live Slurm GRES GPU execution, vLLM API validation, and Flannel overlay checksum mitigation procedures.
4. [`scripts/verify-backend-complete.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/verify-backend-complete.sh): Automated Stage 7 expanded to 8 GPU and inference checks (all 32 cluster checks passing).

---

## 🏁 Resolution Post-Mortem (October 7, 2026)

1. **Hypervisor Host CPU Passthrough Applied:**
   * The underlying VM `ai-sandbox-gpu-vm` was updated with host CPU features (`avx`, `avx2`, `fma`).
   * The kernel was updated to `7.0.0-34-generic` with NVIDIA Driver `595.91.07` / CUDA `13.2`.
   * UCX and PyTorch C++ extension vector crashes ceased completely.

2. **Overlay Network Bug Identified & Mitigated:**
   * On Kernel 7.0 / VirtIO, generic TX checksumming (`tx-checksum-ip-generic`) on `flannel.1` corrupted encapsulated VXLAN UDP packets, dropping DNS and cross-node traffic.
   * Mitigated with `ethtool -K flannel.1 tx off` and persisted across reboots via `/etc/udev/rules.d/99-flannel-tx-checksum.rules`.

3. **vLLM StartupProbe Integration:**
   * Added `startupProbe` (up to 10-minute threshold) in `k8s/vllm-deployment.yaml` to accommodate cold-start NFS checkpoint loading and PyTorch AOT compilation without triggering premature kubelet liveness terminations.

4. **Verification Sign-Off:**
   * `vllm-8445ccb49-m64q9` is `1/1 Running` and actively serving `Qwen/Qwen2.5-32B-Instruct-AWQ`.
   * Verified live chat completion requests through `vllm-service.slurm:8000/v1/chat/completions`.
