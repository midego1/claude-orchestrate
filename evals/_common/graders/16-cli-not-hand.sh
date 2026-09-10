# with-only
# protocol: the orchestrator (main session, not a subagent) wrote contracts with `contract new` and integrated with `integrate`; no hand merge of a unit branch
python3 - "$TRACE" <<'PY'
import json, sys, re
cmds = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: o = json.loads(line)
    except Exception: continue
    if o.get("type") != "assistant" or o.get("parent_tool_use_id"): continue
    for b in o.get("message", {}).get("content", []):
        if b.get("type") == "tool_use" and b.get("name") == "Bash":
            cmds.append(b.get("input", {}).get("command", ""))
joined = "\n".join(cmds)
integrate = bool(re.search(r'\bintegrate\s+U\d', joined))
contract = bool(re.search(r'\bcontract new\s+U\d', joined))
hand_merge = bool(re.search(r'git merge[^\n]*\bunit/', joined))
print("integrate", integrate, "contract new", contract, "hand merge", hand_merge)
sys.exit(0 if (integrate and contract and not hand_merge) else 1)
PY
