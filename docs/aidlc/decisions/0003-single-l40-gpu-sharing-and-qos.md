# 0003 — Single NVIDIA L40 GPU Sharing, Time-Slicing & QoS

Date: 2026-10-20  
Status: accepted  
Supersedes: Static GPU partitioning / Unconstrained shared VRAM

## Context
The cluster contains a single physical **NVIDIA L40 (46GB VRAM)** GPU on `ai-worker1`. It must support two competing demands:
1. Continuous, low-latency LLM inference server (vLLM serving 0.8B to 32B models for student portal queries).
2. Occasional student GPU batch jobs (model fine-tuning, training scripts submitted via Slurm `batch-gpu`).

NVIDIA MPS (Multi-Process Service) was evaluated and explicitly rejected because MPS shares a single CUDA context; a student out-of-memory error (OOM) or segfault in one job fatally crashes all concurrent processes, including the central vLLM inference server. Static physical partitioning (MIG) is unsupported on the NVIDIA L40 architecture.

## Decision
1. **Kubernetes Device Plugin Time-Slicing:** Configure the NVIDIA K8s device plugin with `replicas: 4` time-slicing. Time-slicing provides complete hardware-isolated memory contexts: a crash or `SIGKILL` in Pod A leaves Pod B's CUDA state completely unaffected.
2. **vLLM VRAM Cap (`0.65`):** Pinned vLLM (`vllm/vllm-openai:v0.31.0`) with `--gpu-memory-utilization 0.65`, strictly allocating ~28 GB for model weights and KV cache, leaving ~16 GB free headroom for concurrent GPU tasks.
3. **Temporal Batch Yield Operator:** For heavy batch jobs requiring the full 46 GB GPU, an automated swap/yield operator (`scripts/swap-model.sh` / Slurm epilog/prolog) temporarily scales down vLLM (`replicas: 0`), unlocks the full Slurm `batch-gpu` partition, runs the batch job, and automatically restores vLLM upon completion.
4. **Traffic Fencing & API Protection:** Traefik ingress protects vLLM via ForwardAuth middleware (`/auth/verify`) and rate-limiting (`vllm-ratelimit` at 10 req/s, burst 20; `vllm-inflight` capped at 15 concurrent connections).
5. **Offline Airgap Lockdown:** Enforce `HF_HUB_OFFLINE=1` and `local_files_only=True` to guarantee zero runtime egress to Hugging Face during model serving.

## Consequences
- **Positive:** Multi-tenant fault isolation (zero MPS blast radius); high GPU utilization without purchasing redundant enterprise hardware; protected inference SLAs.
- **Negative:** Context switching latency overhead during heavy concurrent GPU utilization; temporal batch yield temporarily pauses central chat inference.
- **Trigger for Revisiting:** Addition of a second physical GPU node, which would allow dedicating one GPU exclusively to inference and the second to batch workloads.
