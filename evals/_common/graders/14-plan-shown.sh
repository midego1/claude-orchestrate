# with-only
# protocol: the routing table and the cap line were announced (in the assistant's own text, before the first dispatch)
python3 - "$TRACE" <<'PY'
import json, sys
seen_table = seen_cap = False; first_dispatch = None; i = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: o = json.loads(line)
    except Exception: continue
    if o.get("type") != "assistant" or o.get("parent_tool_use_id"): continue
    for b in o.get("message", {}).get("content", []):
        i += 1
        if b.get("type") == "text":
            t = b.get("text", "")
            if "| unit |" in t and "| tier |" in t: seen_table = True
            if "cap:" in t: seen_cap = True
        if b.get("type") == "tool_use" and b.get("name") == "Agent" and first_dispatch is None:
            first_dispatch = (seen_table, seen_cap)
print("table", seen_table, "cap", seen_cap, "before first Agent call:", first_dispatch)
sys.exit(0 if first_dispatch == (True, True) else 1)
PY
