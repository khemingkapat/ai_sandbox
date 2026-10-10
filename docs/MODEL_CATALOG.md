# AI Sandbox: Open-Source Model Catalog & Hardware Sizing Guide

**Specification ID:** WP3-1-10-CATALOG  
**Milestone:** M3-1-3 Open-Source Model Deployment Report  
**Target Hardware:** Dedicated GPU Worker (`ai-sandbox-gpu-vm`) — NVIDIA L40 (46,068 MiB VRAM)  
**Shared Storage Root:** `/mnt/storage/models`  
**HuggingFace Cache:** `/mnt/storage/models/huggingface/hub` (`$HF_HUB_CACHE`)  
**Status:** ACTIVE  

---

## 1. Executive Summary & Purpose

The **AI Sandbox Model Catalog** provides a centrally managed, pre-warmed repository of state-of-the-art open-weights foundation models for students, researchers, and automated workloads.

### The Problem This Solves
In an educational cluster hosting 100+ concurrent students:
1. **Zero Bandwidth Waste:** Without centralized caching, multiple students downloading the same 20GB checkpoint exhausts campus WAN capacity and triggers HuggingFace IP rate limits. Central caching eliminates redundant network egress.
2. **Deterministic Offline Execution:** Student interactive notebooks and Slurm batch jobs resolve weights directly from local NFS storage using `local_files_only=True`. Workloads run completely offline without depending on external web availability.
3. **Hard VRAM Safety & OOM Prevention:** Every model in this catalog is benchmarked and profiled against our physical **NVIDIA L40 (48GB)** hardware. Explicit VRAM ceilings ensure students select architectures that fit within their assigned Slurm partition slices without crashing adjacent tenant jobs.
4. **Strict Permission Hardening:** All shared checkpoints are owned by `root:root` with directory permissions `0755` and file permissions `0644`. Students cannot modify, delete, or overwrite shared weights.

---

## 2. Hardware Architecture & Memory Allocation

The Sandbox GPU worker operates under a **dual-tenancy time-sliced architecture**:

```
+-------------------------------------------------------------------------------+
|                      PHYSICAL ACCELERATOR: NVIDIA L40                         |
|                     Total VRAM: 46,068 MiB (~45.0 GiB)                        |
+-------------------------------------------------------------------------------+
|   Virtual Slice 1: Central Inference (vLLM)   |   Virtual Slice 2: Slurm Jobs |
|   ----------------------------------------    |   --------------------------- |
|   Target Model: Qwen 3.5 MoE / Gemma 4        |   Student LoRA / Fine-tuning  |
|   Memory Utilization: 0.60 - 0.65 (~28 GiB)   |   Max Available: ~16 - 18 GiB |
|   Weights + Activation: ~18 - 20 GiB          |   Partitions: batch-gpu       |
|   Paged KV Cache: ~8 - 10 GiB                 |               interactive     |
+-------------------------------------------------------------------------------+
```

### Key Architectural Advantage: 3:1 Hybrid DeltaNet Attention
Models in the **Qwen 3.5** family utilize a **3:1 hybrid attention stack** (three Gated DeltaNet linear attention layers for every standard attention layer). Linear attention exhibits constant $O(1)$ memory scaling with sequence length, drastically reducing KV-cache VRAM consumption compared to traditional quadratic transformers. This allows the sandbox to support substantially higher student request concurrency within our fixed 8GB KV cache allocation.

---

## 3. Curated Model Matrix

| Track | Model Identifier | Architecture | Precision | Disk Size | Weights VRAM | Peak VRAM | Slurm Sizing |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| **Flagship Central LLM** | `Qwen/Qwen3.5-35B-A3B` | Hybrid DeltaNet MoE (3B active) | BF16 | 35.0 GB | 22.0 GB | 28.0 GB | `inference` / vLLM |
| **Dense Coding & Reasoning** | `Qwen/Qwen3.5-9B` | Hybrid DeltaNet Dense | BF16 | 18.0 GB | 14.5 GB | 18.0 GB | `batch-gpu` (1 GPU) |
| **Interactive Multimodal** | `google/gemma-4-E4B-it` | Dense Multimodal | BF16 | 8.5 GB | 7.0 GB | 9.5 GB | `interactive` (8 GB slice) |
| **High-Context Multimodal** | `google/gemma-4-12b-it` | Unified Multimodal (256K) | BF16 | 24.0 GB | 19.0 GB | 24.0 GB | `batch-gpu` (1 GPU) |
| **Multimodal Embeddings** | `google/embeddinggemma-2` | Gemma2 Embedding (740M) | FP16 | 1.5 GB | 1.2 GB | 1.8 GB | `batch-cpu` / GPU |
| **Multilingual RAG Retrieval** | `BAAI/bge-m3` | XLM-RoBERTa (560M) | FP16 | 2.2 GB | 1.1 GB | 1.8 GB | `batch-cpu` / GPU |

---

## 4. Detailed Model Cards

### 4.1 Flagship MoE: `Qwen/Qwen3.5-35B-A3B`
* **Architecture:** Mixture-of-Experts with 35B total parameters and **3B active parameters** per forward pass.
* **Attention Mechanism:** 3:1 Hybrid Gated DeltaNet + Gated Full Attention.
* **Modalities:** Interleaved Text, Image, and Video.
* **Context Window:** Up to 131,072 tokens.
* **Intended Use:** High-throughput central inference serving, deep reasoning, agentic tool workflows, multimodal queries.
* **Hardware Fit:** Served centrally via vLLM on `ai-sandbox-gpu-vm`. Consumes ~22 GB for weights, leaving ~7 GB for KV cache under 0.65 utilization.

### 4.2 Dense Workhorse: `Qwen/Qwen3.5-9B`
* **Architecture:** Fully dense transformer with DeltaNet linear attention layers.
* **Modalities:** Interleaved Text, Image, and Video.
* **Context Window:** Up to 131,072 tokens.
* **Intended Use:** Full-model parameter exploration, coding, math evaluation, and student batch training.
* **Hardware Fit:** Fits directly onto a dedicated 1-GPU Slurm job (`--gres=gpu:1`). Weights occupy 14.5 GB VRAM in BF16, leaving 1.5 GB for activations during evaluation.

### 4.3 Interactive Multimodal: `google/gemma-4-E4B-it`
* **Architecture:** Compact 4.2B parameter multimodal dense model with native structured thinking.
* **Modalities:** Text and Image input, Text output.
* **Context Window:** Up to 131,072 tokens.
* **Intended Use:** Student JupyterLab interactive sessions, rapid prototyping, vision-language coursework.
* **Hardware Fit:** Tailored for 8GB time-sliced GPU allocations. Weights consume ~7 GB, fitting comfortably within student interactive sessions.

### 4.4 Long-Context Engine: `google/gemma-4-12b-it`
* **Architecture:** 12B parameter multimodal model with unified cross-attention.
* **Modalities:** Text, High-Resolution Image, Document Analysis.
* **Context Window:** Native **262,144 tokens (256K)**.
* **Intended Use:** Long document ingestion, multi-page PDF reasoning, video frame analysis.
* **Hardware Fit:** Requires full 24 GB VRAM allocation in `batch-gpu`. For LoRA fine-tuning, 4-bit QLoRA is required to remain within 16 GB.

### 4.5 Multimodal Vector Embedding: `google/embeddinggemma-2`
* **Architecture:** 740M parameter bidirectional vision-text embedding model.
* **Modalities:** Text queries, Images, Multi-modal RAG chunks.
* **Output Embedding Dimension:** 2048 (MRL truncatable to 512/256).
* **Context Window:** 8,192 tokens.
* **Intended Use:** RAG vector search, multimodal image search, document classification.
* **Hardware Fit:** Operates efficiently on both CPU (`batch-cpu`) and GPU. Model weights consume only 1.5 GB RAM.

### 4.6 Multilingual Hybrid Retrieval: `BAAI/bge-m3`
* **Architecture:** 560M parameter XLM-RoBERTa bidirectional encoder.
* **Features:** Unifies **dense vector embeddings**, **lexical sparse weights** (BM25 equivalent), and **multi-vector ColBERT tokens** into a single forward pass.
* **Output Dimension:** 1024.
* **Language Support:** 100+ languages with cross-lingual retrieval.
* **Intended Use:** Enterprise semantic search, multi-stage RAG reranking, document retrieval.
* **Hardware Fit:** Extremely lightweight (~1.1 GB VRAM). Can run on CPU worker nodes without GPU contention.

---

## 5. Student Developer Runbook

### 5.1 Querying the Central vLLM Service (OpenAI-Compatible API)
Students can access the centrally served flagship model without loading weights into their private session:

```python
import os
from openai import OpenAI

# Connect to internal sandbox gateway
client = OpenAI(
    base_url="https://portal.slurm.svc.cluster.local/v1",  # or https://localhost:8443/v1
    api_key="sandbox-key",
    verify=False  # Sandbox internal TLS
)

response = client.chat.completions.create(
    model="Qwen/Qwen3.5-35B-A3B",
    messages=[
        {"role": "system", "content": "You are an AI teaching assistant."},
        {"role": "user", "content": "Explain the difference between dense and sparse attention."}
    ],
    temperature=0.7,
    max_tokens=256
)

print(response.choices[0].message.content)
```

---

### 5.2 Zero-Download Offline Model Loading in Python
To load a curated model into a JupyterLab notebook or PyTorch script without downloading:

```python
import os
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

# The portal automatically injects HF_HUB_CACHE=/mnt/storage/models/huggingface/hub
model_id = "google/gemma-4-E4B-it"

tokenizer = AutoTokenizer.from_pretrained(
    model_id,
    local_files_only=True  # Strictly loads from shared NFS cache
)

model = AutoModelForCausalLM.from_pretrained(
    model_id,
    torch_dtype=torch.bfloat16,
    device_map="auto",
    local_files_only=True  # Guarantees zero network download
)

inputs = tokenizer("Define time-slicing in GPU computing:", return_tensors="pt").to(model.device)
outputs = model.generate(**inputs, max_new_tokens=64)
print(tokenizer.decode(outputs[0], skip_special_tokens=True))
```

---

### 5.3 Batch LoRA Fine-Tuning Job Script (`submit_lora.sh`)
Standard Slurm submission template for fine-tuning within the 16GB `batch-gpu` slice:

```bash
#!/bin/bash
#SBATCH --job-name=qwen35-lora
#SBATCH --partition=batch-gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=lora_%j.log

set -e

# Verify environment contract
export HF_HUB_CACHE="/mnt/storage/models/huggingface/hub"
export TRANSFORMERS_OFFLINE=1

echo "🚀 Starting PEFT/LoRA training on $(hostname) with GPU allocation:"
nvidia-smi

python3 -c "
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model

model_id = 'Qwen/Qwen3.5-9B'
print('Loading base model from NFS cache...')
model = AutoModelForCausalLM.from_pretrained(
    model_id,
    torch_dtype=torch.bfloat16,
    device_map='auto',
    local_files_only=True
)

lora_config = LoraConfig(
    r=16,
    lora_alpha=32,
    target_modules=['q_proj', 'v_proj'],
    lora_dropout=0.05,
    bias='none',
    task_type='CAUSAL_LM'
)

peft_model = get_peft_model(model, lora_config)
peft_model.print_trainable_parameters()
print('Ready for fine-tuning loop!')
"
```

---

## 6. Administration & Model Ingestion Governance

### 6.1 Storage Quota & Capacity Budget
* **Shared Storage Root:** `/mnt/storage/models`
* **Volume Capacity:** 196 GB Total / 157 GB Free
* **Current Catalog Footprint:** ~89.2 GB
* **Safety Margin:** Minimum 40 GB headroom maintained for temporary download artifacts and scratch caching.

### 6.2 Permission Security Standard
All catalog assets must adhere to strict POSIX permission constraints:
```bash
# Directories
find /mnt/storage/models -type d -exec chmod 755 {} +
# Files
find /mnt/storage/models -type f -exec chmod 644 {} +
# Ownership
chown -R 0:0 /mnt/storage/models
```

### 6.3 Automated Model Ingestion CLI
To add, verify, and benchmark a new model into the catalog:
```bash
# Ingest new model
./scripts/ingest-model.sh --model google/gemma-4-E4B-it --modality text,image --slurm-profile

# Dry-run / test mode (creates fixtures for CI)
./scripts/ingest-model.sh --test-mode
```
The ingestion tool automates:
1. **Pre-flight Check:** Validates available disk space and verifies format is `.safetensors`.
2. **Download:** Downloads checkpoint via `huggingface_hub.snapshot_download` into `/mnt/storage/models/huggingface/hub`.
3. **Hardening:** Locks permissions to `0755`/`0644` under `root:root`.
4. **Hardware Profiling:** Dispatches a non-interactive benchmark job to `batch-gpu` to measure peak VRAM and generation speed on the NVIDIA L40.
5. **Catalog Sync:** Appends metadata to `docs/MODEL_CATALOG.json` and updates `docs/MODEL_CATALOG.md`.
