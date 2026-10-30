#!/bin/bash
# Self-hosted brain: prebuilt llama.cpp + cached GGUF on the runner. No API key.
# One task in, one artifact out. Fail-loud.
set -euo pipefail
[ -n "${TASK:-}" ] || { echo "FAIL: empty task"; exit 1; }
mkdir -p model llama-bin
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
    cmake --build llama.cpp/build -j4 --target llama-cli
    cp llama.cpp/build/bin/llama-cli llama-bin/
  fi
fi
[ -x "$CLI" ] || { echo "FAIL: no llama-cli"; exit 1; }
MDL="model/qwen2.5-0.5b-instruct-q4_k_m.gguf"
[ -f "$MDL" ] || curl -sSL -o "$MDL" "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
[ -f "$MDL" ] || { echo "FAIL: no model"; exit 1; }
echo "model bytes: $(stat -c%s "$MDL")"
"$CLI" -m "$MDL" -p "$TASK" -n 2048 -t 4 --temp 0.7 > draft-raw.txt 2> draft-stderr.txt || { echo "FAIL: infer rc=$?"; tail -c 800 draft-stderr.txt; exit 1; }
[ -s draft-raw.txt ] || { echo "FAIL: empty draft"; exit 1; }
python3 - draft-raw.txt draft-output.md <<'EOF'
import sys
raw = open(sys.argv[1], errors='replace').read().replace('\b', '').replace('\r', '')
lines = raw.split('\n')
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
body = '\n'.join(lines[start:end]).strip()
if not body:
    print('FAIL: stripped draft empty')
    sys.exit(1)
open(sys.argv[2], 'w').write(body + '\n')
print('STRIP OK (%d bytes -> %d bytes)' % (len(raw), len(body)))
EOF
[ -s draft-output.md ] || { echo "FAIL: empty stripped draft"; exit 1; }
echo "DRAFT OK ($(wc -c < draft-output.md) bytes)"
