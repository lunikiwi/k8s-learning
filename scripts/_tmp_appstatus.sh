#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
kubectl get app -n argocd k8s-learning -o json > /tmp/app.json
python3 - <<'PY'
import json
d = json.load(open("/tmp/app.json"))
s = d.get("status", {})
print("sync   :", s.get("sync", {}).get("status"))
print("health :", s.get("health", {}).get("status"))
for c in s.get("conditions", []):
    print("cond   :", c.get("type"), "->", str(c.get("message"))[:400])
op = s.get("operationState", {})
print("opphase:", op.get("phase"), "|", str(op.get("message"))[:400])
PY
echo "--- pods in default ---"
kubectl get pods -n default 2>&1 | head -20
