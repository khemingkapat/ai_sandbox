#!/bin/bash
# scripts/seed-models.sh
# Admin tool to pre-populate and curate shared AI model weights in /mnt/storage/models.
# Implements the WP3-1-7 specification from docs/CENTRAL_STORAGE.md.

set -e

STORAGE_ROOT="${STORAGE_ROOT:-/mnt/storage}"
if [ ! -d "$STORAGE_ROOT" ] && [ -d "$(pwd)/storage" ]; then
    STORAGE_ROOT="$(pwd)/storage"
fi

MODELS_DIR="$STORAGE_ROOT/models"
HF_HUB_DIR="$MODELS_DIR/huggingface/hub"
TORCH_DIR="$MODELS_DIR/torch/checkpoints"
OLLAMA_DIR="$MODELS_DIR/ollama"

TEST_MODE=0
for arg in "$@"; do
    case $arg in
        --test-mode)
            TEST_MODE=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--test-mode]"
            echo "  --test-mode: Seeds lightweight mock/CPU-friendly models for local dev/testing"
            exit 0
            ;;
    esac
done

echo "🤖 Seeding Model Repository at $MODELS_DIR (Test Mode: $TEST_MODE)..."

mkdir -p "$HF_HUB_DIR" "$TORCH_DIR" "$OLLAMA_DIR"

if [ "$TEST_MODE" -eq 1 ]; then
    echo "📦 [Test Mode] Generating lightweight CPU model fixtures..."
    
    # 1. HuggingFace fixture: models--BAAI--bge-small-en-v1.5
    BGE_DIR="$HF_HUB_DIR/models--BAAI--bge-small-en-v1.5/snapshots/main"
    mkdir -p "$BGE_DIR"
    cat <<'EOF' > "$BGE_DIR/config.json"
{
  "architectures": ["BertModel"],
  "attention_probs_dropout_prob": 0.1,
  "hidden_size": 384,
  "model_type": "bert",
  "num_attention_heads": 12,
  "num_hidden_layers": 12,
  "vocab_size": 30522
}
EOF
    cat <<'EOF' > "$BGE_DIR/tokenizer.json"
{"version": "1.0", "model": {"type": "WordPiece", "unk_token": "[UNK]"}}
EOF
    echo "dummy-safetensors-weight-fixture" > "$BGE_DIR/model.safetensors"

    # 2. HuggingFace fixture: models--Qwen--Qwen2.5-0.5B-Instruct
    QWEN_DIR="$HF_HUB_DIR/models--Qwen--Qwen2.5-0.5B-Instruct/snapshots/main"
    mkdir -p "$QWEN_DIR"
    cat <<'EOF' > "$QWEN_DIR/config.json"
{
  "architectures": ["Qwen2ForCausalLM"],
  "hidden_size": 896,
  "model_type": "qwen2",
  "num_attention_heads": 14,
  "num_hidden_layers": 24,
  "vocab_size": 151936
}
EOF
    cat <<'EOF' > "$QWEN_DIR/tokenizer.json"
{"version": "1.0", "model": {"type": "BPE"}}
EOF
    echo "dummy-qwen-safetensors-weight-fixture" > "$QWEN_DIR/model.safetensors"

    # 3. PyTorch Hub fixture: resnet18
    echo "dummy-resnet18-pytorch-weights" > "$TORCH_DIR/resnet18-f37072fd.pth"

    # 4. Ollama manifest fixture
    mkdir -p "$OLLAMA_DIR/manifests"
    echo '{"schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.v2+json"}' > "$OLLAMA_DIR/manifests/qwen2.5-0.5b.json"

else
    echo "📥 Pre-downloading curated production models via Python/huggingface_hub..."
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import os
try:
    from huggingface_hub import snapshot_download
    os.environ['HF_HUB_CACHE'] = '$HF_HUB_DIR'
    print('Downloading BAAI/bge-small-en-v1.5...')
    snapshot_download(repo_id='BAAI/bge-small-en-v1.5', cache_dir='$HF_HUB_DIR')
except Exception as e:
    print('Warning: Python huggingface_hub download skipped or failed:', e)
" || true
    fi
fi

# Hardening permissions to read-only for students
echo "🔐 Locking model permissions to root:root 755 (dirs) and 644 (files)..."
chown -R 0:0 "$MODELS_DIR"
find "$MODELS_DIR" -type d -exec chmod 755 {} +
find "$MODELS_DIR" -type f -exec chmod 644 {} +

echo "✅ Central Model Repository successfully seeded at $MODELS_DIR."
