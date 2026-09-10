# outcome: docs/features.md carries the shout entry under "## Changes" (before "## Other"), no fragment left behind
python3 - <<'PY'
import re, sys, os
t = open("docs/features.md").read()
m = re.search(r"^## Changes\n(.*?)^## Other", t, re.S | re.M)
body = m.group(1) if m else ""
print(body.strip()[:200])
ok = "shout" in body and body.strip() != ""
if os.path.isdir("docs/_pending") and os.listdir("docs/_pending"):
    print("fragment left in docs/_pending"); ok = False
sys.exit(0 if ok else 1)
PY
