#!/bin/bash
# Single draft worker: one task in, one artifact out. Fail-loud: any error = nonzero exit.
set -euo pipefail
[ -n "${TASK:-}" ] || { echo "FAIL: empty task"; exit 1; }
RESP=$(curl -sS -w "\n%{http_code}" -X POST "https://models.github.ai/inference/chat/completions" \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$TASK" '{model:"openai/gpt-4o-mini", messages:[{role:"system",content:"You are a draft worker. Do exactly the task, output only the deliverable."},{role:"user",content:$t}], max_tokens:1500}')" \
  || { echo "FAIL: inference call failed"; exit 1; })
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then echo "FAIL: inference HTTP $CODE"; echo "$BODY" | head -c 500; exit 1; fi
echo "$BODY" | jq -r '.choices[0].message.content // empty' > draft-output.md
[ -s draft-output.md ] || { echo "FAIL: empty draft"; exit 1; }
echo "DRAFT OK ($(wc -c < draft-output.md) bytes)"
