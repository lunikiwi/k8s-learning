#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"

echo "=== make lb-test ==="
make lb-test

echo
echo "=== failover: delete one processor pod, keep sending traffic ==="
POD=$(kubectl get pods -n default -l app=processor-service \
  -o jsonpath='{.items[0].metadata.name}')
echo "deleting $POD"
kubectl delete pod -n default "$POD" --wait=false >/dev/null

fail=0
ok=0
for _ in $(seq 40); do
  if curl -fsS --max-time 5 http://localhost:8080/ping >/dev/null 2>&1; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
  sleep 0.25
done
echo "requests during pod deletion: OK=$ok FAILED=$fail"

echo
echo "=== pods after failover ==="
kubectl get pods -n default -l app=processor-service

echo
echo "=== make k8s-status ==="
make k8s-status
