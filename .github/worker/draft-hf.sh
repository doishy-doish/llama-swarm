#!/bin/bash
# HF safetensors brain: download FRIDGE-ICED 0.5B -> convert -> Q4_K_M -> infer. Fail-loud.
set -euo pipefail
[ -n "${TASK:-}" ] || { echo "FAIL: empty task"; exit 1; }
mkdir -p "${MODEL_DIR:-fridge}" llama-bin hf-src
CLI="llama-bin/llama-cli"
TAG=$(curl -sSL "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30" | jq -r "[.[].tag_name | select(startswith(\"b\"))][0]")
ASSET="llama-${TAG}-bin-ubuntu-x64.tar.gz"
FOUND=$(find /tmp/lp -name llama-cli -type f | head -1)
Q="llama-bin/llama-quantize"
GGUF="${MODEL_DIR:-fridge}/fridge-iced-0.5b-q4_k_m.gguf"
BASE="https://huggingface.co/loaiabdalslam/SLM-FRIDGE-ICED-0.5B-32BQWEN/resolve/main"
SZ=$(stat -c%s hf-src/model.safetensors 2>/dev/null || echo 0)
python3 llama.cpp/convert_hf_to_gguf.py hf-src --outfile "${MODEL_DIR:-fridge}/model-f16.gguf" --outtype f16
"$Q" "${MODEL_DIR:-fridge}/model-f16.gguf" "$GGUF" Q4_K_M
"$CLI" -m "$GGUF" -p "$PROMPT" -n 2048 -t 4 --temp "${TEMP:-0.7}" > draft-raw.txt 2> draft-stderr.txt || { echo "FAIL: infer rc=$?"; tail -c 800 draft-stderr.txt; exit 1; }
echo "DRAFT OK ($(wc -c < draft-output.md) bytes)"
