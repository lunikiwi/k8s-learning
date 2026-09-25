#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — one-shot local GitOps environment
#
#   1. build the three Docker images
#   2. create a k3d cluster (idempotent) with host port mappings
#   3. import the images into the cluster (no registry needed)
#   4. install Argo CD into namespace "argocd"
#   5. wait until the Argo CD controller + server are ready
#   6. apply argocd-app.yaml (the GitOps root Application)
#   7. print the follow-up commands for the developer
#
# Every step is idempotent: re-running the script on an existing cluster only
# rebuilds/re-imports the images and re-applies the manifests.
#
# Usage:
#   ./bootstrap.sh                      # full bootstrap
#   ./bootstrap.sh --recreate           # delete an existing cluster first
#   ./bootstrap.sh --skip-build         # reuse the images already in Docker
#   ./bootstrap.sh --no-argocd          # plain "kubectl apply -f k8s/", no GitOps
#   REPO_URL=https://github.com/me/repo.git ./bootstrap.sh
#
# Environment overrides:
#   CLUSTER      k3d cluster name              (default: k3s-default)
#   TAG          image tag                     (default: latest)
#   HOST_PORT    host port → LoadBalancer:8080 (default: 8080)
#   INGRESS_PORT host port → Traefik:80        (default: 8081)
#   ARGOCD_PORT  suggested UI port-forward     (default: 8083)
#   REPO_URL     Git repo injected into the Argo CD Application
#   AGENTS       number of k3d agent nodes     (default: 1)
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

# ─── configuration ───────────────────────────────────────────────────────────
CLUSTER="${CLUSTER:-k3s-default}"
TAG="${TAG:-latest}"
HOST_PORT="${HOST_PORT:-8080}"
INGRESS_PORT="${INGRESS_PORT:-8081}"
ARGOCD_PORT="${ARGOCD_PORT:-8083}"
AGENTS="${AGENTS:-1}"
ARGOCD_NAMESPACE="argocd"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
APP_NAMESPACE="default"

# Resolve the repo root from the script location so the script can be called
# from anywhere (e.g. "bash ../../bootstrap.sh").
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

SERVICES=(gateway processor storage)

# Flags
RECREATE=false
SKIP_BUILD=false
USE_ARGOCD=true

# ─── pretty output ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

step() { echo; echo "${BOLD}${BLUE}==> $*${RESET}"; }
info() { echo "    $*"; }
ok()   { echo "${GREEN}    ✓ $*${RESET}"; }
warn() { echo "${YELLOW}    ! $*${RESET}" >&2; }
die()  { echo "${RED}${BOLD}ERROR: $*${RESET}" >&2; exit 1; }

# Report which command failed instead of dying silently (set -e).
trap 'die "command failed (line $LINENO): ${BASH_COMMAND}"' ERR

# ─── argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate)   RECREATE=true ;;
    --skip-build) SKIP_BUILD=true ;;
    --no-argocd)  USE_ARGOCD=false ;;
    -h|--help)
      sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# ─── 0. preflight ────────────────────────────────────────────────────────────
step "Preflight checks"

for bin in docker kubectl; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH."
done
ok "docker and kubectl found"

docker info >/dev/null 2>&1 \
  || die "Docker daemon not reachable. Start Docker Desktop / dockerd and retry."
ok "Docker daemon reachable"

if ! command -v k3d >/dev/null 2>&1; then
  warn "'k3d' not found in PATH."
  cat <<'EOF'
    Install it with one of:
      curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
      brew install k3d                 # macOS / Linuxbrew
      choco install k3d                # Windows
EOF
  die "k3d is required."
fi
ok "k3d $(k3d version | awk '/k3d version/ {print $3}')"

# ─── 1. build images ─────────────────────────────────────────────────────────
if $SKIP_BUILD; then
  step "Building Docker images (skipped: --skip-build)"
else
  step "Building Docker images"
  for svc in "${SERVICES[@]}"; do
    info "docker build -t ${svc}-service:${TAG} services/${svc}"
    docker build --quiet -t "${svc}-service:${TAG}" "services/${svc}" >/dev/null
    ok "${svc}-service:${TAG}"
  done
fi

# Fail early with a clear message rather than on ErrImageNeverPull later.
for svc in "${SERVICES[@]}"; do
  docker image inspect "${svc}-service:${TAG}" >/dev/null 2>&1 \
    || die "image ${svc}-service:${TAG} missing — run without --skip-build."
done

# ─── 2. create the k3d cluster ───────────────────────────────────────────────
step "k3d cluster '${CLUSTER}'"

cluster_exists() { k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER}\""; }

if cluster_exists && $RECREATE; then
  info "--recreate given → deleting existing cluster"
  k3d cluster delete "$CLUSTER"
fi

if cluster_exists; then
  ok "cluster already exists — reusing it"
  # A stopped cluster has no API server; start it before doing anything else.
  k3d cluster start "$CLUSTER" >/dev/null 2>&1 || true
else
  info "creating cluster (1 server, ${AGENTS} agent(s))"
  # --port …@loadbalancer publishes host ports through the k3d serverlb:
  #   HOST_PORT    → node port 8080 → Service type LoadBalancer (klipper-lb)
  #   INGRESS_PORT → node port 80   → Traefik Ingress controller
  k3d cluster create "$CLUSTER" \
    --agents "$AGENTS" \
    --port "${HOST_PORT}:8080@loadbalancer" \
    --port "${INGRESS_PORT}:80@loadbalancer" \
    --wait
  ok "cluster created"
fi

# Make sure kubectl talks to THIS cluster, even if another context was active.
kubectl config use-context "k3d-${CLUSTER}" >/dev/null
ok "kubectl context: k3d-${CLUSTER}"

info "waiting for nodes to become Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
ok "all nodes Ready"

# ─── 3. import images into the cluster ───────────────────────────────────────
step "Importing images into k3d"

IMAGES=()
for svc in "${SERVICES[@]}"; do IMAGES+=("${svc}-service:${TAG}"); done

info "k3d image import ${IMAGES[*]} --cluster ${CLUSTER}"
k3d image import "${IMAGES[@]}" --cluster "$CLUSTER"
ok "images available inside the cluster (imagePullPolicy: Never)"

# ─── 4. install Argo CD ──────────────────────────────────────────────────────
if $USE_ARGOCD; then
  step "Installing Argo CD into namespace '${ARGOCD_NAMESPACE}'"

  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  ok "namespace ready"

  info "applying ${ARGOCD_MANIFEST}"
  # server-side apply: the Argo CD CRDs exceed the 262 kB annotation limit of
  # the client-side "last-applied-configuration".
  kubectl apply -n "$ARGOCD_NAMESPACE" --server-side --force-conflicts \
    -f "$ARGOCD_MANIFEST" >/dev/null
  ok "manifests applied"

  # ─── 5. wait for Argo CD ───────────────────────────────────────────────────
  step "Waiting for Argo CD to become ready (this can take 2–3 minutes)"

  # The CRDs must be registered before an Application can be created.
  info "waiting for the Application CRD"
  kubectl wait --for=condition=Established \
    crd/applications.argoproj.io --timeout=180s >/dev/null
  ok "CRD applications.argoproj.io established"

  # Wait for the Deployments to roll out, then for the StatefulSet pod.
  for dep in argocd-repo-server argocd-server; do
    info "rollout: deployment/${dep}"
    kubectl rollout status -n "$ARGOCD_NAMESPACE" "deployment/${dep}" \
      --timeout=300s >/dev/null
    ok "${dep} ready"
  done

  info "rollout: statefulset/argocd-application-controller"
  kubectl rollout status -n "$ARGOCD_NAMESPACE" \
    statefulset/argocd-application-controller --timeout=300s >/dev/null
  ok "argocd-application-controller ready"

  # Belt and braces: every argocd pod must report Ready.
  kubectl wait --for=condition=Ready pods --all \
    -n "$ARGOCD_NAMESPACE" --timeout=300s >/dev/null
  ok "all Argo CD pods Ready"

  # ─── 6. apply the root Application ─────────────────────────────────────────
  step "Applying the Argo CD root Application"

  [[ -f argocd-app.yaml ]] || die "argocd-app.yaml not found in ${REPO_ROOT}"

  # Auto-detect the Git remote if the user did not export REPO_URL.
  if [[ -z "${REPO_URL:-}" ]] && command -v git >/dev/null 2>&1; then
    REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  fi

  APP_FILE="argocd-app.yaml"
  if [[ -n "${REPO_URL:-}" ]]; then
    APP_FILE="$(mktemp -t argocd-app.XXXXXX.yaml)"
    # Escape '&' and '|' so they are not interpreted by sed's replacement.
    ESCAPED_URL="${REPO_URL//&/\\&}"
    sed "s|https://github.com/DEIN_USERNAME/DEIN_REPO.git|${ESCAPED_URL}|" \
      argocd-app.yaml > "$APP_FILE"
    ok "repoURL set to ${REPO_URL}"
  fi

  kubectl apply -f "$APP_FILE" >/dev/null
  ok "Application 'k8s-learning' created in namespace ${ARGOCD_NAMESPACE}"
  [[ "$APP_FILE" != "argocd-app.yaml" ]] && rm -f "$APP_FILE"

  # Argo CD caches manifest-generation errors. On a re-run (e.g. right after
  # the missing commit was pushed) a hard refresh avoids waiting for the cache.
  kubectl annotate application -n "$ARGOCD_NAMESPACE" k8s-learning \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

  # ─── 6b. verify that Argo CD can actually reach the manifests ──────────────
  # Argo CD pulls from the REMOTE repo — never from the local working copy.
  # So it fails if k8s/ has not been committed and pushed yet, or if repoURL
  # is still the placeholder. Detect that and fall back to a direct apply,
  # otherwise the script would report success with an empty cluster.
  step "Waiting for Argo CD to sync from Git"

  SYNC_STATUS=""
  COMPARISON_ERROR=""
  for _ in $(seq 1 30); do
    SYNC_STATUS="$(kubectl get application -n "$ARGOCD_NAMESPACE" k8s-learning \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    COMPARISON_ERROR="$(kubectl get application -n "$ARGOCD_NAMESPACE" k8s-learning \
      -o jsonpath='{.status.conditions[?(@.type=="ComparisonError")].message}' \
      2>/dev/null || true)"
    [[ "$SYNC_STATUS" == "Synced" || -n "$COMPARISON_ERROR" ]] && break
    sleep 5
  done

  if [[ "$SYNC_STATUS" == "Synced" ]]; then
    ok "Application is Synced — manifests come from Git (real GitOps)"
  else
    warn "Argo CD cannot render the manifests from Git."
    [[ -n "$COMPARISON_ERROR" ]] && warn "reason: ${COMPARISON_ERROR}"
    cat >&2 <<EOF
    Most likely one of:
      * the "k8s/" directory is not committed & pushed to the remote yet
            git add k8s argocd-app.yaml bootstrap.sh && git commit -m "add k8s manifests" && git push
      * spec.source.repoURL in argocd-app.yaml is still the placeholder
      * the repository is private (then add credentials:
            argocd repo add <url> --username <user> --password <token>)

    Falling back to a direct "kubectl apply -f k8s/" so the chain runs now.
    Once the manifests are pushed, Argo CD takes ownership on the next sync.
EOF
    kubectl apply -n "$APP_NAMESPACE" -f k8s/ >/dev/null
    ok "k8s/ applied directly (GitOps takes over after push)"
  fi
else
  step "Argo CD skipped (--no-argocd) — applying k8s/ directly"
  kubectl apply -n "$APP_NAMESPACE" -f k8s/ >/dev/null
  ok "k8s/ applied with kubectl"
fi

# ─── 7. wait for the application workloads ───────────────────────────────────
step "Waiting for the microservice chain"

# With GitOps, Argo CD needs a moment to create the Deployments before
# "rollout status" can find them.
for dep in storage-service processor-service gateway-service; do
  for _ in $(seq 1 60); do
    kubectl get -n "$APP_NAMESPACE" "deployment/${dep}" >/dev/null 2>&1 && break
    sleep 2
  done
  if kubectl get -n "$APP_NAMESPACE" "deployment/${dep}" >/dev/null 2>&1; then
    kubectl rollout status -n "$APP_NAMESPACE" "deployment/${dep}" \
      --timeout=180s >/dev/null && ok "${dep} ready"
  else
    warn "${dep} not created (yet). Check: kubectl get app -n argocd k8s-learning"
  fi
done

# ─── 8. summary ──────────────────────────────────────────────────────────────
echo
echo "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${GREEN}║  Bootstrap complete                                          ║${RESET}"
echo "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"

kubectl get pods -n "$APP_NAMESPACE" -o wide 2>/dev/null || true

cat <<EOF

${BOLD}Argo CD UI${RESET}
  # 1) start the port-forward (keep this terminal open)
  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} ${ARGOCD_PORT}:443

  # 2) open https://localhost:${ARGOCD_PORT}   (self-signed cert → accept the warning)
  #    user: admin

  # 3) read the initial admin password
  kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret \\
    -o jsonpath="{.data.password}" | base64 -d; echo

${BOLD}Test the chain${RESET}
  # a) via the k3d LoadBalancer port mapping (no port-forward needed)
  curl -s http://localhost:${HOST_PORT}/ping | jq .

  # b) via the Traefik Ingress
  curl -s http://localhost:${INGRESS_PORT}/ping | jq .

  # c) via kubectl port-forward
  kubectl port-forward svc/gateway-service -n ${APP_NAMESPACE} 8080:8080
  curl -s http://localhost:8080/ping | jq .

${BOLD}Observe load balancing across the 2 processor replicas${RESET}
  # Send the requests CONCURRENTLY. The gateway's Go HTTP client pools
  # keep-alive connections, so a sequential loop reuses one TCP connection and
  # therefore sticks to a single processor pod. Parallel requests force
  # additional connections, which kube-proxy spreads over both replicas:
  seq 40 | xargs -P 10 -I{} sh -c \\
    'curl -s http://localhost:${HOST_PORT}/ping | jq -r .processor.pod' \\
    | sort | uniq -c
  # → verified output, e.g.:  15 processor-…-lhqr6 / 25 processor-…-zll9j
  #
  # Shortcut: make lb-test

${BOLD}Failover test${RESET}
  # Delete one replica and keep sending traffic: the readiness probe removes it
  # from the Endpoints list, so requests keep returning 200 from the other pod.
  kubectl delete pod -l app=processor-service --wait=false
  watch -n1 "curl -s http://localhost:${HOST_PORT}/ping | jq -r .processor.pod"

${BOLD}Logs (X-Request-ID correlates all three services)${RESET}
  kubectl logs -f deployment/gateway-service   | jq .
  kubectl logs -f deployment/processor-service | jq .
  kubectl logs -f deployment/storage-service   | jq .

${BOLD}Argo CD status / teardown${RESET}
  kubectl get application -n ${ARGOCD_NAMESPACE} k8s-learning
  k3d cluster delete ${CLUSTER}
EOF
