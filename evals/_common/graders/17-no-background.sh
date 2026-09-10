# with-only
# protocol: every worker/verifier dispatch by the orchestrator ran inline (no run_in_background: true)
python3 - "$TRACE" <<'PY'
import json, sys
bg = total = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: o = json.loads(line)
    except Exception: continue
    if o.get("type") != "assistant" or o.get("parent_tool_use_id"): continue
    for b in o.get("message", {}).get("content", []):
        if b.get("type") == "tool_use" and b.get("name") == "Agent":
            total += 1
            if b.get("input", {}).get("run_in_background") is True: bg += 1
print("agent calls", total, "background", bg)
sys.exit(0 if total > 0 and bg == 0 else 1)
PY
