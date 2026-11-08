# AI Sandbox: Candidate Models Backlog & VRAM Sizing Guide

This document maintains curated candidate models profiled for future ingestion into the AI Sandbox shared cache (`/mnt/storage/models/huggingface/hub`) and central vLLM serving.

## Hardware Reference
* **Accelerator:** NVIDIA L40 (46,068 MiB / ~45.0 GiB physical VRAM)
* **Serving Ceiling:** `--gpu-memory-utilization 0.65` = **~29.2 GiB maximum VRAM budget**
* **Available for Weights + Activations + Paged KV-Cache:** ~29.2 GiB
* **Slurm Co-tenancy Reservation:** ~15.8 GiB reserved for student `batch-gpu` / `interactive` jobs

---

## 1. Candidate Matrix by Model Family

| Family & Model Identifier | Architecture & Parameters | Precision | Weights Disk / VRAM | Available KV Cache (at 0.65) | Sizing Verdict & Rationale |
| :--- | :--- | :---: | :---: | :---: | :--- |
| **Qwen 3.5 Family** | | | | | |
| `Qwen/Qwen3.5-35B-A3B-GPTQ-Int4` | 3:1 Hybrid DeltaNet MoE (35B total, **3B active**) | INT4 | ~18.5 GiB | ~8.5 GiB (~35k tokens) | **Top Pick for Central `/v1`**: MoE latency of a 3B model with 35B reasoning, native multimodal. |
| `Qwen/Qwen3.5-27B-GPTQ-Int4` | 3:1 Hybrid DeltaNet Dense (27B) | INT4 | ~15.0 GiB | ~12.0 GiB (~50k tokens) | **High-Reasoning Dense**: Excellent math/code, generous KV headroom. |
| `Qwen/Qwen3.5-9B` | 3:1 Hybrid DeltaNet Dense (9B) | BF16 | ~18.0 GiB | ~9.0 GiB (~36k tokens) | **Best Dual-Use**: Works for vLLM `/v1` AND unquantized student LoRA training in `batch-gpu`. |
| `Qwen/Qwen3.5-0.8B` *(Cached)* | 3:1 Hybrid DeltaNet Dense (0.8B) | BF16 | 1.74 GiB | ~25.5 GiB (huge) | **Fast Swap Smoke Test**: Instant load, verifies architecture compatibility. |
| **Mistral Family** | | | | | |
| `mistralai/Mistral-Small-Instruct-2409` | Dense Transformer (22B) | INT4-AWQ | ~12.5 GiB | ~14.5 GiB (~40k tokens) | Strong multilingual reasoning, enterprise function calling. |
| `mistralai/Mistral-NeMo-Instruct-2407` | Dense Transformer (12B, Tekken tokenizer) | BF16 / FP8 | ~13.0 GiB (FP8) | ~14.0 GiB (~45k tokens) | 128k native context, highly optimized for coding and structured JSON. |
| `mistralai/Mistral-7B-Instruct-v0.3` | Dense Transformer (7B) | BF16 | ~14.5 GiB | ~12.5 GiB (~38k tokens) | Battle-tested open-weights baseline with native tool calling support. |
| **Phi Family** | | | | | |
| `microsoft/phi-4` | Synthetic Reasoning Dense (14B) | FP8 / AWQ | ~9.5 GiB (FP8) | ~17.5 GiB (~60k tokens) | State-of-the-art synthetic STEM/math reasoning; FP8 recommended to fit inside 28GB ceiling. |
| `microsoft/Phi-3.5-mini-instruct` | Compact Reasoning Dense (3.8B) | BF16 | ~7.5 GiB | ~19.5 GiB (~75k tokens) | Ultra-long 128k context, extremely fast token generation, lightweight student baseline. |
| **Gemma Family** | | | | | |
| `google/gemma-2-9b-it` | Sliding Window Transformer (9B) | BF16 | ~18.2 GiB | ~8.8 GiB (~32k tokens) | High MMLU/eval scores; requires FlashAttention-2 or FlashInfer sliding window support. |
| `google/gemma-4-E4B-it` | Compact Multimodal Dense (4.2B) | BF16 | ~8.5 GiB | ~18.5 GiB (~65k tokens) | Native multimodal vision-language student prototyping model. |
| `google/gemma-2-2b-it` | Compact Dense (2.6B) | BF16 | ~5.2 GiB | ~21.8 GiB (~90k tokens) | Fast, reliable starter model for student prompt engineering tutorials. |
| **Smol Family (Hugging Face)** | | | | | |
| `HuggingFaceTB/SmolLM2-1.7B-Instruct` | Compact On-Device Transformer (1.7B) | BF16 | ~3.4 GiB | ~23.6 GiB (~100k+ tokens)| Ultra-low resource model, ideal for local student fine-tuning without GPU contention. |
| `HuggingFaceTB/SmolLM2-360M-Instruct`| Micro Transformer (360M) | BF16 | ~0.7 GiB | ~26.0 GiB | Testing and continuous integration fixture. |

---

## 2. Ingestion Commands Reference

To ingest any candidate model from this backlog onto `/mnt/storage/models/huggingface/hub`:

```bash
# Example: Ingest Qwen 3.5 9B
./scripts/ingest-model.sh --model Qwen/Qwen3.5-9B --modality text,image

# Example: Ingest Mistral NeMo
./scripts/ingest-model.sh --model mistralai/Mistral-NeMo-Instruct-2407 --modality text

# Example: Ingest Phi-3.5 Mini
./scripts/ingest-model.sh --model microsoft/Phi-3.5-mini-instruct --modality text

# Example: Ingest SmolLM2 1.7B
./scripts/ingest-model.sh --model HuggingFaceTB/SmolLM2-1.7B-Instruct --modality text
```
