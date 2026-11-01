#!/bin/bash
# HF safetensors brain: download FRIDGE-ICED 0.5B -> convert -> Q4_K_M -> infer. Fail-loud.
# One task in, one artifact out. Additive: default draft path untouched.
set -euo pipefail
[ -n "${TASK:-}" ] || { echo "FAIL: empty task"; exit 1; }
mkdir -p "${MODEL_DIR:-fridge}" llama-bin hf-src
CLI="llama-bin/llama-cli"
if [ ! -x "$CLI" ]; then
  TAG=$(curl -sSL "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30" | jq -r "[.[].tag_name | select(startswith(\"b\"))][0]")
  echo "latest b-tag llama.cpp: $TAG"
  ASSET="llama-${TAG}-bin-ubuntu-x64.tar.gz"
  if curl -sSL -o /tmp/lp.tgz "https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${ASSET}" && file /tmp/lp.tgz | grep -q gzip; then
    mkdir -p /tmp/lp && tar xzf /tmp/lp.tgz -C /tmp/lp
    FOUND=$(find /tmp/lp -name llama-cli -type f | head -1)
    if [ -n "$FOUND" ]; then BINDIR=$(dirname "$FOUND"); cp "$BINDIR"/* llama-bin/; chmod +x llama-bin/llama-cli; export LD_LIBRARY_PATH="$PWD/llama-bin:${LD_LIBRARY_PATH:-}"; fi
export LD_LIBRARY_PATH="$GITHUB_WORKSPACE/llama-bin:${LD_LIBRARY_PATH:-}"
  else
    echo "WARN: release asset unusable, falling back to source build"
  fi
  if [ ! -x "$CLI" ]; then
    echo "release asset miss, building llama-cli from source..."
    sudo apt-get update -qq && sudo apt-get install -y -qq cmake g++ > /dev/null
    [ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp
    cmake -B llama.cpp/build -S llama.cpp -DCMAKE_BUILD_TYPE=Release > /dev/null
    cmake --build llama.cpp/build -j4 --target llama-cli llama-quantize
    cp llama.cpp/build/bin/llama-cli llama.cpp/build/bin/llama-quantize llama-bin/ 2>/dev/null || cp llama.cpp/build/bin/llama-cli llama-bin/
  fi
fi
[ -x "$CLI" ] || { echo "FAIL: no llama-cli"; exit 1; }
Q="llama-bin/llama-quantize"
if [ ! -x "$Q" ]; then
  echo "no llama-quantize in release, building..."
  sudo apt-get update -qq && sudo apt-get install -y -qq cmake g++ > /dev/null
  [ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp
  cmake -B llama.cpp/build -S llama.cpp -DCMAKE_BUILD_TYPE=Release > /dev/null
  cmake --build llama.cpp/build -j4 --target llama-quantize
  cp llama.cpp/build/bin/llama-quantize llama-bin/
fi
[ -x "$Q" ] || { echo "FAIL: no llama-quantize"; exit 1; }
GGUF="${MODEL_DIR:-fridge}/fridge-iced-0.5b-q4_k_m.gguf"
if [ ! -f "$GGUF" ]; then
  BASE="https://huggingface.co/loaiabdalslam/SLM-FRIDGE-ICED-0.5B-32BQWEN/resolve/main"
  for f in config.json tokenizer.json tokenizer_config.json vocab.json merges.txt special_tokens_map.json added_tokens.json generation_config.json chat_template.jinja; do
    [ -f "hf-src/$f" ] || curl -sSL -o "hf-src/$f" "$BASE/$f"
  done
  [ -f hf-src/model.safetensors ] || curl -sSL -o hf-src/model.safetensors "$BASE/model.safetensors"
  SZ=$(stat -c%s hf-src/model.safetensors 2>/dev/null || echo 0)
  [ "$SZ" -gt 500000000 ] || { echo "FAIL: weights too small (${SZ}B)"; head -c 200 hf-src/model.safetensors; echo; exit 1; }
  echo "weights bytes: $SZ"
  [ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp
  pip install -q torch --index-url https://download.pytorch.org/whl/cpu numpy transformers sentencepiece gguf 2>&1 | tail -2 || pip install -q torch numpy transformers sentencepiece gguf 2>&1 | tail -2
  python3 llama.cpp/convert_hf_to_gguf.py hf-src --outfile "${MODEL_DIR:-fridge}/model-f16.gguf" --outtype f16
  "$Q" "${MODEL_DIR:-fridge}/model-f16.gguf" "$GGUF" Q4_K_M
  rm -f "${MODEL_DIR:-fridge}/model-f16.gguf"
  rm -rf hf-src
fi
[ -f "$GGUF" ] || { echo "FAIL: no gguf"; exit 1; }
echo "gguf bytes: $(stat -c%s "$GGUF")"
if [ -f "$TASK" ]; then PROMPT="$(cat "$TASK")"; else PROMPT="$TASK"; fi
"$CLI" -m "$GGUF" -p "$PROMPT" -n 2048 -t 4 --temp "${TEMP:-0.7}" > draft-raw.txt 2> draft-stderr.txt || { echo "FAIL: infer rc=$?"; tail -c 800 draft-stderr.txt; exit 1; }
[ -s draft-raw.txt ] || { echo "FAIL: empty draft"; exit 1; }
python3 - draft-raw.txt draft-output.md <<'EOF'
import sys
raw = open(sys.argv[1], errors='replace').read().replace(chr(8), '').replace(chr(13), '')
lines = raw.split(chr(10))
end = len(lines)
for i, l in enumerate(lines):
    if l.startswith('[ Prompt:') or l.strip() == 'Exiting...':
        end = i
        break
start = 0
found = False
for i in range(end):
    if lines[i].startswith('> ') or lines[i].strip() == '>':
        start = i + 1
        found = True
if not found:
    print('FAIL: no prompt echo found')
    sys.exit(1)
body = chr(10).join(lines[start:end]).strip()
if not body:
    print('FAIL: stripped draft empty')
    sys.exit(1)
open(sys.argv[2], 'w').write(body + chr(10))
print('STRIP OK (%d bytes -> %d bytes)' % (len(raw), len(body)))
EOF
[ -s draft-output.md ] || { echo "FAIL: empty stripped draft"; exit 1; }
echo "DRAFT OK ($(wc -c < draft-output.md) bytes)"
