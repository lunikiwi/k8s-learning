#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"

echo "=== A) sequential + 'Connection: close' (expected: sticky, ONE pod) ==="
for _ in $(seq 20); do
  curl -fsS -H 'Connection: close' http://localhost:8080/ping | jq -r .processor.pod
done | sort | uniq -c

echo
echo "=== B) 40 requests, 10 in parallel (expected: BOTH pods) ==="
seq 40 | xargs -P 10 -I{} sh -c \
  'curl -fsS http://localhost:8080/ping | jq -r .processor.pod' | sort | uniq -c

echo
echo "=== C) same, via the Traefik Ingress on :8081 ==="
seq 40 | xargs -P 10 -I{} sh -c \
  'curl -fsS http://localhost:8081/ping | jq -r .processor.pod' | sort | uniq -c
