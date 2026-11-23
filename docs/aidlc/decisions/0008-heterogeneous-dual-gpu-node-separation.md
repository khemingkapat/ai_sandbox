# 0008 — Heterogeneous Dual-GPU Node Separation (L40 Inference vs. RTX 3060 Ti Compute)

Date: 2026-11-23
Status: accepted
Supersedes: Single-GPU time-slicing contention in ADR 0003 (temporal vLLM yield for Slurm batch-gpu)

## Context
Previously, the cluster relied on a single physical GPU (`ai-sandbox-gpu-vm` @ `10.35.123.40`, NVIDIA L40 48 GB) for both continuous central LLM inference (`vllm`) and Slurm `batch-gpu` workloads. This created a contention window requiring temporal scale-down of `vllm` for exclusive batch jobs, and left the cluster with zero GPU compute whenever the L40 was offline for maintenance.

An additional GPU VM, `ai-sandbox-gpu02` (`10.35.123.41`), was provisioned on VLAN 123 with heterogeneous hardware: **NVIDIA GeForce RTX 3060 Ti (8 GB VRAM, Ampere CC 8.6)**, 8 vCPU, 15 GiB RAM, and 79 GB root disk.

## Decision
1. **Strict Role Separation by Node Labels:**
   - `ai-sandbox-gpu-vm` (`10.35.123.40`): Labeled `accelerator=nvidia-gpu,gpu-model=l40,gpu-role=inference`. Dedicated **100%** to central LLM inference (`vllm` / LiteLLM) with zero student batch contention.
   - `ai-sandbox-gpu02` (`10.35.123.41`): Labeled `accelerator=nvidia-gpu,gpu-model=rtx3060ti,gpu-role=compute`. Dedicated to Slurm GPU compute (`slurmd-gpu-0`, `batch-gpu` partition).
2. **Disjoint Per-GPU-Model NVIDIA Device Plugin DaemonSets (`k8s/nvidia-device-plugin.yaml`):**
   - `nvidia-device-plugin-daemonset` selects `gpu-model: l40` (retaining L40 config).
   - `nvidia-device-plugin-compute` selects `gpu-model: rtx3060ti` with **exclusive `nvidia.com/gpu: 1`** (no `timeSlicing` block) to eliminate CUDA OOM collisions on 8 GB VRAM.
3. **Host RAM Protection on `ai-sandbox-gpu02`:**
   - Cap `slurmd-gpu` pod memory at `12Gi` (`requests: 4Gi`, `limits: 12Gi`) so Slurm jobs cannot starve `k3s-agent` on the 15 GiB host.
4. **No Double-Registration in Slurm:**
   - `slurmd-gpu-0` (Slinky NodeSet pod) is the sole Slurm GPU worker on `ai-sandbox-gpu02`; `scheduler.slinky.slurm.net/external-node=true` is intentionally omitted to prevent Slurm from double-counting the single physical GPU.

## Alternatives Considered
- **Global Time-Slicing (`replicas: 4`) Across Both Nodes:** Rejected. Slicing an 8 GB RTX 3060 Ti into 4 virtual GPUs (~2 GB soft share) causes immediate CUDA OOM crashes on PyTorch workloads.
- **Running Small vLLM Sidecar + Slurm Batch Together on `.41`:** Rejected. Recreates the exact multi-tenant VRAM contention problem we are escaping, on an even smaller 8 GB memory pool.

## Consequences
- **What this makes easier:** Zero vLLM inference downtime during Slurm GPU batch jobs; GPU batch compute stays operational even when the L40 is offline for maintenance; clear heterogeneous scheduling boundaries.
- **What this makes harder:** Two disjoint NVIDIA Device Plugin DaemonSets must be maintained in `k8s/nvidia-device-plugin.yaml`; `CLUSTER_GPU_MAINTENANCE` in Stage 2 CI must remain `"true"` while the L40 (`vllm`) is offline, even though `.41` advertises `nvidia.com/gpu: 1`.
- **Revisit trigger:** Provisioning of a third GPU node or enabling interactive GPU Jupyter pods in `portal/` targeting `gpu-role=compute`.
