#!/bin/bash
# Generic python payload check: TASK = python source. py_compile + import +
# baked driver (playbook API tests when present, IMPORT_OK otherwise). Fail-loud.
set -euo pipefail
[ -n "${TASK:-}" ] || { echo "FAIL: empty task"; exit 1; }
mkdir -p /tmp/payload_check
if [ -f "$TASK" ]; then cp "$TASK" /tmp/payload_check/mod.py; else printf "%s" "$TASK" > /tmp/payload_check/mod.py; fi
[ -s /tmp/payload_check/mod.py ] || { echo "FAIL: empty payload"; exit 1; }
python3 -m py_compile /tmp/payload_check/mod.py && echo "COMPILE_OK"
python3 - /tmp/payload_check > draft-output.md 2>&1 <<'PYEOF' || { echo "FAIL: driver rc=$?"; tail -c 2000 draft-output.md; exit 1; }
import json, os, pathlib, sys
sys.path.insert(0, "/tmp/payload_check")
os.environ["ARC3_PERSISTENT_FUNCTIONS"] = "1"
os.environ["ARC3_PERSISTENT_FUNCTIONS_SCOPE"] = "session"
os.environ["KAGGLE_WORKING_DIR"] = "/tmp/pbtest"
import mod
results = []
def check(name, cond):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name)
if hasattr(mod, "propose_rule") and hasattr(mod, "admit_pending_rules"):
    root = pathlib.Path("/tmp/pbtest"); (root / "transitions").mkdir(parents=True, exist_ok=True)
    rows = [
        {"episode": "g1/p0", "t": 1, "events": {"level": 1, "score": 0}},
        {"episode": "g1/p0", "t": 2, "events": {"level": 1, "score": 5}},
        {"episode": "g1/p0", "t": 3, "events": {"level": 2, "score": 5}},
    ]
    (root / "transitions" / "p0.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    check("T1 enabled", mod.playbook_enabled() is True)
    mod.propose_rule("press SPACE on box match", [{"episode": "g1/p0", "t": 2, "level": 1, "score": 5}])
    mod.propose_rule("dangling ref", [{"episode": "nope/p0", "t": 9, "level": 1, "score": 0}])
    mod.propose_rule("wrong score", [{"episode": "g1/p0", "t": 2, "level": 1, "score": 99}])
    mod.propose_rule("no support", [])
    a, rej = mod.admit_pending_rules()
    check("T2 admit=(1,3) got=(%d,%d)" % (a, rej), (a, rej) == (1, 3))
    check("T2 rules==1", mod.playbook_stats()["rules"] == 1)
    for i in range(70):
        mod.propose_rule("rule %03d" % i, [{"episode": "g1/p0", "t": 1, "level": 1, "score": 0}])
    a2, r2 = mod.admit_pending_rules()
    n = mod.prune_rules()
    check("T3 admit71 prune->64 got=%d" % n, (a2, r2) == (70, 0) and n == 64)
    tail = mod.playbook_tail()
    check("T4 tail bounded nonempty", 0 < len(tail) <= 2500)
    mk = mod.boundary_readout_line("g1")
    check("T4 readout", mk.startswith("PLAYBOOK_READOUT game=g1 rules=64"))
else:
    check("IMPORT_OK", True)
print("DRIVER_DONE %d/%d" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
PYEOF
cat draft-output.md
