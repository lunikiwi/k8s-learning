# ─── Configuration ────────────────────────────────────────────────────────────
# NOTE: never put trailing comments on the same line as a variable assignment —
# make would include the whitespace before the '#' in the variable value.
REGISTRY ?= local
TAG      ?= dev

# k3d cluster name; override with: make k3d-import CLUSTER=mycluster
CLUSTER ?= k3s-default

# Namespace the microservice chain is deployed to (matches argocd-app.yaml).
APP_NAMESPACE   ?= default
ARGOCD_NAMESPACE ?= argocd

# Host port that k3d maps to the gateway LoadBalancer (see bootstrap.sh).
HOST_PORT   ?= 8080
# Host port for the Argo CD UI port-forward.
ARGOCD_PORT ?= 8083

# Kubernetes version used for offline schema validation (make k8s-validate).
K8S_VERSION ?= 1.31.0

GATEWAY_IMG   := $(REGISTRY)/gateway-service:$(TAG)
PROCESSOR_IMG := $(REGISTRY)/processor-service:$(TAG)
STORAGE_IMG   := $(REGISTRY)/storage-service:$(TAG)

SERVICES := gateway processor storage

GO_LDFLAGS := -s -w

.PHONY: all build-all docker-build docker-build-gateway docker-build-processor \
        docker-build-storage k3d-import run-local stop-local fmt vet test \
        image-sizes tidy clean help bootstrap bootstrap-recreate bootstrap-local \
        k8s-validate k8s-apply k8s-delete k8s-status argocd-ui argocd-password \
        port-forward smoke-k8s lb-test teardown

# ─── Default ──────────────────────────────────────────────────────────────────
all: build-all

# ─── Local Go builds ──────────────────────────────────────────────────────────
## build-all: Compile all three services as local static binaries.
build-all:
	@for svc in $(SERVICES); do \
	  echo "==> Building $$svc-service"; \
	  ( cd services/$$svc && CGO_ENABLED=0 go build -ldflags="$(GO_LDFLAGS)" -trimpath -o $$svc-service . ) || exit 1; \
	done
	@echo "==> All binaries built."

# ─── Code quality ─────────────────────────────────────────────────────────────
## fmt: Format all Go sources with gofmt.
fmt:
	@for svc in $(SERVICES); do \
	  echo "==> gofmt: services/$$svc"; \
	  gofmt -w services/$$svc/main.go; \
	done

## vet: Run 'go vet' and verify gofmt compliance in all services.
vet:
	@for svc in $(SERVICES); do \
	  echo "==> go vet: services/$$svc"; \
	  ( cd services/$$svc && go vet ./... ) || exit 1; \
	  unformatted=$$(gofmt -l services/$$svc); \
	  if [ -n "$$unformatted" ]; then \
	    echo "ERROR: not gofmt-clean: $$unformatted"; exit 1; \
	  fi; \
	done
	@echo "==> vet + gofmt clean."

## test: Run unit tests in all services.
test:
	@for svc in $(SERVICES); do \
	  echo "==> go test: services/$$svc"; \
	  ( cd services/$$svc && go test ./... ) || exit 1; \
	done

# ─── Docker builds ────────────────────────────────────────────────────────────
## docker-build: Build all three Docker images.
docker-build: docker-build-gateway docker-build-processor docker-build-storage

docker-build-gateway:
	@echo "==> Building Docker image $(GATEWAY_IMG)"
	docker build -t $(GATEWAY_IMG) services/gateway

docker-build-processor:
	@echo "==> Building Docker image $(PROCESSOR_IMG)"
	docker build -t $(PROCESSOR_IMG) services/processor

docker-build-storage:
	@echo "==> Building Docker image $(STORAGE_IMG)"
	docker build -t $(STORAGE_IMG) services/storage

## image-sizes: Print the size of the three built images.
image-sizes:
	@docker image inspect $(GATEWAY_IMG) $(PROCESSOR_IMG) $(STORAGE_IMG) \
	  --format '{{.RepoTags}} {{.Size}} bytes'

# ─── k3d image import ─────────────────────────────────────────────────────────
## k3d-import: Import all three images into the k3d cluster (no registry push needed).
k3d-import: docker-build
	@echo "==> Importing images into k3d cluster '$(CLUSTER)'"
	k3d image import $(GATEWAY_IMG) $(PROCESSOR_IMG) $(STORAGE_IMG) --cluster $(CLUSTER)
	@echo "==> Images imported. Use 'imagePullPolicy: Never' in your manifests."

# ─── Local run (no Docker / K8s needed) ──────────────────────────────────────
## run-local: Start all three services locally on ports 8080/8081/8082 with
##            correct env wiring. Ctrl-C stops all of them.
# All three are started inside ONE shell invocation, otherwise each make recipe
# line would run in its own shell and 'wait' could not track the children.
# The trap guarantees no orphan processes are left behind on Ctrl-C.
run-local: build-all
	@set -m; \
	trap 'echo; echo "==> Stopping services..."; kill 0 2>/dev/null; exit 0' INT TERM; \
	echo "==> Starting storage-service   on :8082"; \
	PORT=8082 HOSTNAME=storage-local \
	  ./services/storage/storage-service & \
	sleep 0.3; \
	echo "==> Starting processor-service on :8081"; \
	PORT=8081 HOSTNAME=processor-local \
	  STORAGE_SERVICE_URL=http://localhost:8082/data \
	  ./services/processor/processor-service & \
	sleep 0.3; \
	echo "==> Starting gateway-service   on :8080"; \
	PORT=8080 HOSTNAME=gateway-local \
	  PROCESSOR_SERVICE_URL=http://localhost:8081/process \
	  ./services/gateway/gateway-service & \
	sleep 0.5; \
	echo ""; \
	echo "Chain is up. Test with:"; \
	echo "  curl -s http://localhost:8080/ping | jq ."; \
	echo ""; \
	echo "Press Ctrl-C to stop all services."; \
	wait

## stop-local: Kill any leftover locally running service binaries.
stop-local:
	-@pkill -f 'services/gateway/gateway-service'     2>/dev/null || true
	-@pkill -f 'services/processor/processor-service' 2>/dev/null || true
	-@pkill -f 'services/storage/storage-service'     2>/dev/null || true
	@echo "==> Local services stopped."

# ─── Go module maintenance ────────────────────────────────────────────────────
## tidy: Run 'go mod tidy' in all three service directories.
tidy:
	@for svc in $(SERVICES); do \
	  echo "==> go mod tidy: services/$$svc"; \
	  ( cd services/$$svc && go mod tidy ) || exit 1; \
	done

# ─── Kubernetes / k3d / Argo CD ───────────────────────────────────────────────
## bootstrap: Full local setup — build images, create k3d cluster, import
##            images, install Argo CD and apply the root Application.
bootstrap:
	@./bootstrap.sh

## bootstrap-recreate: Same as 'bootstrap' but deletes an existing cluster first.
bootstrap-recreate:
	@./bootstrap.sh --recreate

## bootstrap-local: Bootstrap WITHOUT Argo CD (plain 'kubectl apply -f k8s/').
bootstrap-local:
	@./bootstrap.sh --no-argocd

## k8s-validate: Schema-validate all manifests offline (no cluster needed).
# 'kubectl apply --dry-run=client' still contacts the API server to download the
# OpenAPI schema, so it fails without a cluster. kubeconform validates against
# the published JSON schemas instead and runs fully offline (after one pull).
# The Argo CD Application is a CRD, hence -ignore-missing-schemas.
k8s-validate:
	@echo "==> YAML syntax check"
	@docker run --rm -v "$(CURDIR)":/work -w /work ghcr.io/yannh/kubeconform:latest \
	  -summary -strict -kubernetes-version $(K8S_VERSION) k8s/
	@echo "==> argocd-app.yaml (CRD — schema not part of core Kubernetes)"
	@docker run --rm -v "$(CURDIR)":/work -w /work ghcr.io/yannh/kubeconform:latest \
	  -summary -strict -ignore-missing-schemas \
	  -kubernetes-version $(K8S_VERSION) argocd-app.yaml
	@echo "==> Manifests are valid."

## k8s-apply: Apply the manifests directly (bypasses Argo CD / GitOps).
k8s-apply:
	kubectl apply -n $(APP_NAMESPACE) -f k8s/

## k8s-delete: Remove the microservice chain from the cluster.
k8s-delete:
	-kubectl delete -n $(APP_NAMESPACE) -f k8s/ --ignore-not-found

## k8s-status: Show pods, services and endpoints of the chain.
k8s-status:
	@kubectl get pods,svc,endpoints -n $(APP_NAMESPACE) \
	  -l app.kubernetes.io/part-of=k8s-learning -o wide

## argocd-ui: Port-forward the Argo CD UI (default https://localhost:8083).
argocd-ui:
	@echo "==> Argo CD UI: https://localhost:$(ARGOCD_PORT) (user: admin)"
	@echo "==> Password:   make argocd-password"
	kubectl port-forward svc/argocd-server -n $(ARGOCD_NAMESPACE) $(ARGOCD_PORT):443

## argocd-password: Print the initial Argo CD admin password.
argocd-password:
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret \
	  -o jsonpath="{.data.password}" | base64 -d; echo

## port-forward: Forward the gateway-service to localhost:8080.
port-forward:
	@echo "==> curl http://localhost:8080/ping"
	kubectl port-forward svc/gateway-service -n $(APP_NAMESPACE) 8080:8080

## smoke-k8s: Single /ping request against the cluster (needs k3d port mapping).
smoke-k8s:
	@curl -fsS http://localhost:$(HOST_PORT)/ping | jq .

## lb-test: Fire 40 concurrent requests and count the answering processor pods.
# The requests MUST run concurrently: the gateway's Go HTTP client pools
# keep-alive connections, so a sequential loop reuses a single TCP connection
# and every request lands on the same processor pod. Parallel requests open
# additional connections, which kube-proxy distributes over both replicas.
lb-test:
	@echo "==> 40 requests to /ping (10 parallel) — processor pod distribution:"
	@seq 40 | xargs -P 10 -I{} sh -c \
	  'curl -fsS http://localhost:$(HOST_PORT)/ping | jq -r .processor.pod' \
	  | sort | uniq -c

## teardown: Delete the whole k3d cluster.
teardown:
	-k3d cluster delete $(CLUSTER)

# ─── Cleanup ──────────────────────────────────────────────────────────────────
## clean: Remove compiled binaries.
clean:
	@for svc in $(SERVICES); do \
	  rm -f services/$$svc/$$svc-service; \
	done
	@echo "==> Local binaries removed."

# ─── Help ─────────────────────────────────────────────────────────────────────
## help: Show this help message.
help:
	@echo "Available targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
