#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"

echo "=== git remote of this working copy ==="
git remote -v
echo
echo "=== is the remote reachable / does it contain k8s/ ? ==="
git ls-remote --heads origin 2>&1 | head -5
echo
echo "=== is k8s/ committed locally? ==="
git status --porcelain k8s argocd-app.yaml bootstrap.sh
echo
echo "=== Argo CD repo-server: clone vs. path error ==="
kubectl logs -n argocd deployment/argocd-repo-server --tail=200 2>/dev/null \
  | grep -i -E 'app path does not exist|authentication required|could not read|repository not found' \
  | tail -5
