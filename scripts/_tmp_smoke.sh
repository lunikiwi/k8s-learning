#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"

echo "=== 1) /ping via k3d LoadBalancer mapping (localhost:8080) ==="
curl -fsS http://localhost:8080/ping | jq . || echo "FAILED (LoadBalancer)"

echo
echo "=== 2) /ping via Traefik Ingress (localhost:8081) ==="
curl -fsS http://localhost:8081/ping | jq -c . || echo "FAILED (Ingress)"

echo
echo "=== 3) load balancing: 20 requests, processor pod distribution ==="
for _ in $(seq 20); do
  curl -fsS -H 'Connection: close' http://localhost:8080/ping | jq -r .processor.pod
done | sort | uniq -c

echo
echo "=== 4) healthz endpoints ==="
curl -fsS http://localhost:8080/healthz; echo

echo
echo "=== 5) services / endpoints ==="
kubectl get svc,endpoints -n default
