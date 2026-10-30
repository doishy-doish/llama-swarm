#!/bin/bash
# Qwen3-0.6B brain (thinking-family) for llama-swarm. Opt-in, drop-in compatible:
# same interface as draft.sh (TASK in, draft-output.md out) + draft-thinking.md.
# Does NOT replace draft.sh; wire-up is a separate decision after a trial dispatch.
#
# Thinking controls (firsthand, from Qwen3-0.6B README + tokenizer chat_template):
# - Hard switch: chat template `enable_thinking=False` prefills an empty
#   <think></think> block so the model answers directly with NO <think> output.
#   Not available in llama-cli raw `-p` mode (no template kwargs) -> we use the
#   soft switch below, which is trained behavior, not template logic.
# - Soft switch: append `/think` or `/no_think` to the user prompt. Requires the
#   template default (enable_thinking=True). Model ALWAYS emits a
#   <think>...</think> block; with /no_think the block is EMPTY and the answer
#   follows it. Most recent switch wins in multi-turn.
# - Sampling (README Best Practices): thinking Temp 0.6 / TopP 0.95 / TopK 20 /
#   MinP 0, never greedy. Non-thinking Temp 0.7 / TopP 0.8 / TopK 20 / MinP 0.
# - Parsing (README Quickstart): split at the LAST </think> (token 151668);
#   before = thinking_content, after = content. History should keep only the
#   final output, not the thinking (README Best Practices #4).
# - ARC-3 precedent (same family, Qwen3.8-27B-FP8 on vLLM): harness runs with
#   enable_thinking=False via chat_template_kwargs (kaggle.py smoke test +
#   openai_compat.py thinking flag), reasoning read separately via
#   reasoning_content, think tags stripped as a safety net only.
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
MDL="model/qwen3-0.6b-q8_0.gguf"
[ -f "$MDL" ] || curl -sSL -o "$MDL" "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf"
[ -f "$MDL" ] || { echo "FAIL: no model"; exit 1; }
echo "model bytes: $(stat -c%s "$MDL")"
# THINK=0 (default): /no_think direct-answer mode, same 2048 budget as draft.sh.
# THINK=1: /think reasoning mode, 4096 budget (thinking eats tokens first).
if [ "${THINK:-0}" = "1" ]; then
  PROMPT="$TASK /think"
  TEMP="0.6"; TOPP="0.95"; TOPK="20"; NTOK="4096"
else
  PROMPT="$TASK /no_think"
  TEMP="0.7"; TOPP="0.8"; TOPK="20"; NTOK="2048"
fi
"$CLI" -m "$MDL" -p "$PROMPT" -n "$NTOK" -t 4 --temp "$TEMP" --top-p "$TOPP" --top-k "$TOPK" > draft-raw.txt 2> draft-stderr.txt || { echo "FAIL: infer rc=$?"; tail -c 800 draft-stderr.txt; exit 1; }
[ -s draft-raw.txt ] || { echo "FAIL: empty draft"; exit 1; }
python3 - draft-raw.txt draft-output.md draft-thinking.md <<'EOF'
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
# Thinking split: at the LAST </think> (Qwen3 README Quickstart). Before =
# thinking (strip one leading <think>), after = answer. Empty thinking with a
# non-empty answer is the expected /no_think shape, not a fault.
thinking = ''
if '</think>' in body:
    idx = body.rfind('</think>')
    thinking = body[:idx].strip()
    if thinking.startswith('<think>'):
        thinking = thinking[len('<think>'):].strip()
    answer = body[idx + len('</think>'):].strip()
    if '<think>' in thinking or '</think>' in thinking:
        print('FAIL: nested/unbalanced think tags in thinking block')
        sys.exit(1)
    if not answer:
        print('FAIL: empty answer after think block (truncated? bump -n)')
        sys.exit(1)
elif '<think>' in body:
    print('FAIL: unclosed <think> block (truncated? bump -n)')
    sys.exit(1)
else:
    answer = body
    print('WARN: no think block in output (plain answer, usable)')
open(sys.argv[2], 'w').write(answer + '\n')
open(sys.argv[3], 'w').write(thinking + '\n' if thinking else '')
mode = 'think-split' if '</think>' in body else 'plain'
print('STRIP OK (%d bytes -> answer %d bytes, thinking %d bytes, %s)' % (len(raw), len(answer), len(thinking), mode))
EOF
[ -s draft-output.md ] || { echo "FAIL: empty stripped draft"; exit 1; }
echo "DRAFT OK (answer $(wc -c < draft-output.md) bytes, thinking $(wc -c < draft-thinking.md 2>/dev/null || echo 0) bytes)"
