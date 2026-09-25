# k8s-learning — Distributed Microservices Demo

A minimal three-tier microservice chain written in Go, designed to run in a
local Kubernetes cluster (k3d / k3s) and operated via GitOps.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Client                                                          │
│  curl GET /ping                                                  │
└────────────────────┬─────────────────────────────────────────────┘
                     │ HTTP GET /ping
                     ▼
┌────────────────────────────────┐
│  gateway-service  :8080        │  generates X-Request-ID
│  GET /ping                     │  measures total_duration_ms
│  GET /healthz                  │
└────────────────────┬───────────┘
                     │ HTTP GET /process  (X-Request-ID forwarded)
                     ▼
┌────────────────────────────────┐
│  processor-service  :8080      │  adds pod name + RFC3339 timestamp
│  GET /process                  │  measures storage_duration_ms
│  GET /healthz                  │
└────────────────────┬───────────┘
                     │ HTTP GET /data  (X-Request-ID forwarded)
                     ▼
┌────────────────────────────────┐
│  storage-service  :8080        │  returns status + pod name
│  GET /data                     │
│  GET /healthz                  │
└────────────────────────────────┘
```

### Request / Response chain

```
GET /ping
  └─► GET /process
        └─► GET /data
              ◄── { status, message, pod }          ← storage-service
        ◄── { pod, timestamp, storage_duration_ms,
               storage: { … } }                     ← processor-service
  ◄── { status, gateway_pod, request_id,
         total_duration_ms,
         processor: { … } }                         ← gateway-service
```

---

## Repository layout

```
.
├── Makefile
├── .gitignore
├── .gitattributes          # forces LF endings (gofmt/Docker correctness)
├── README.md
├── scripts/
│   └── verify.sh           # gofmt + vet + build check (runs in Docker)
└── services/
    ├── gateway/
    │   ├── main.go
    │   ├── go.mod
    │   ├── Dockerfile
    │   └── .dockerignore
    ├── processor/
    │   ├── main.go
    │   ├── go.mod
    │   ├── Dockerfile
    │   └── .dockerignore
    └── storage/
        ├── main.go
        ├── go.mod
        ├── Dockerfile
        └── .dockerignore
```

---

## Environment variables

### gateway-service

| Variable               | Default                                    | Description                                      |
|------------------------|--------------------------------------------|--------------------------------------------------|
| `PORT`                 | `8080`                                     | HTTP listen port                                 |
| `HOSTNAME`             | `unknown` (set automatically by K8s)       | Pod name logged as `gateway_pod`                 |
| `PROCESSOR_SERVICE_URL`| `http://processor-service:8080/process`    | Full URL of the processor-service `/process` endpoint |

### processor-service

| Variable             | Default                                  | Description                                    |
|----------------------|------------------------------------------|------------------------------------------------|
| `PORT`               | `8080`                                   | HTTP listen port                               |
| `HOSTNAME`           | `unknown` (set automatically by K8s)     | Pod name logged as `pod`                       |
| `STORAGE_SERVICE_URL`| `http://storage-service:8080/data`       | Full URL of the storage-service `/data` endpoint |

### storage-service

| Variable   | Default                              | Description                          |
|------------|--------------------------------------|--------------------------------------|
| `PORT`     | `8080`                               | HTTP listen port                     |
| `HOSTNAME` | `unknown` (set automatically by K8s) | Pod name returned in the JSON payload |

---

## Local development (no Docker / K8s required)

### Prerequisites

- Go 1.22+

### Build all binaries

```bash
make build-all
```

### Run the full chain locally

```bash
make run-local
```

This starts:
- `storage-service`  on `:8082`
- `processor-service` on `:8081` → calls `localhost:8082`
- `gateway-service`  on `:8080` → calls `localhost:8081`

Test the chain:

```bash
curl -s http://localhost:8080/ping | jq .
```

Expected output:

```json
{
  "status": "ok",
  "gateway_pod": "gateway-local",
  "request_id": "8c926a4834c4bd32",
  "total_duration_ms": 5,
  "processor": {
    "pod": "processor-local",
    "timestamp": "2026-09-24T19:39:32.134673402Z",
    "storage_duration_ms": 2,
    "storage": {
      "status": "ok",
      "message": "Data retrieved from storage",
      "pod": "storage-local"
    }
  }
}
```

### Error behaviour

If a downstream service is unavailable, the caller gets a JSON error envelope
with HTTP `502 Bad Gateway` (never an HTML error page):

```json
{
  "error": "processor-service error",
  "upstream_status": 502,
  "request_id": "05b0771b14f61580"
}
```

Non-`GET` requests return `405` with `{"error":"method not allowed"}`.

Health checks:

```bash
curl http://localhost:8080/healthz
curl http://localhost:8081/healthz
curl http://localhost:8082/healthz
```

---

## Docker builds

```bash
# Build all three images tagged :dev
make docker-build

# Or build individually
make docker-build-gateway
make docker-build-processor
make docker-build-storage

# Check image sizes
make image-sizes
```

Measured sizes (verified, `scratch` base + stripped static binary):

| Image                     | Size    |
|---------------------------|---------|
| `local/gateway-service`   | ~2.4 MB |
| `local/processor-service` | ~2.4 MB |
| `local/storage-service`   | ~2.2 MB |

Well under the 15 MB target. The Dockerfiles use BuildKit's `TARGETARCH`, so the
same file builds correctly for `amd64` and `arm64` (Apple Silicon, Raspberry Pi).

> Because the final stage is `scratch`, the image contains **no CA certificates**.
> That is fine for in-cluster plain HTTP. If a service ever needs to call an
> HTTPS endpoint, copy the certs in the final stage:
> `COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/`
>
> `scratch` also has no shell, so `kubectl exec` will not work. Use
> `alpine:latest` as the final stage if you need to debug inside the container.

---

## k3d — import images into local cluster

```bash
# Create a cluster first (if you haven't already)
k3d cluster create k3s-default

# Build + import in one step
make k3d-import

# Or target a different cluster name
make k3d-import CLUSTER=my-cluster
```

> **Important:** Set `imagePullPolicy: Never` in your Kubernetes manifests when
> using locally imported images, so K8s does not try to pull from a registry.

---

## Observability — following the request chain via kubectl logs

Every service emits structured JSON logs on `stdout`. The `X-Request-ID` header
is generated at the gateway and forwarded to all downstream services, so you can
correlate a single request across all three pods:

```bash
# In three separate terminals:
kubectl logs -f deployment/gateway-service   | jq .
kubectl logs -f deployment/processor-service | jq .
kubectl logs -f deployment/storage-service   | jq .
```

Sample log line (storage-service):

```json
{
  "time": "2024-09-24T18:00:00.123Z",
  "level": "INFO",
  "msg": "request",
  "method": "GET",
  "path": "/data",
  "status": 200,
  "duration_ms": 0,
  "request_id": "a3f1c2d4e5b67890"
}
```

---

## Makefile targets

| Target              | Description                                                    |
|---------------------|----------------------------------------------------------------|
| `make build-all`    | Compile all three services as local static binaries            |
| `make fmt`          | Format all Go sources with `gofmt`                             |
| `make vet`          | Run `go vet` and enforce gofmt compliance                      |
| `make test`         | Run unit tests in all services                                 |
| `make docker-build` | Build all three Docker images tagged `local/<svc>:dev`         |
| `make image-sizes`  | Print the size of the three built images                       |
| `make k3d-import`   | Build images and import them into the k3d cluster              |
| `make run-local`    | Build + start all three services locally (ports 8080/81/82)    |
| `make stop-local`   | Kill any leftover locally running service binaries             |
| `make tidy`         | Run `go mod tidy` in all service directories                   |
| `make clean`        | Remove compiled local binaries                                 |
| `make help`         | Show available targets                                         |

---

## Verifying the code

`gofmt`, `go vet` and a build for all three services can be checked without
installing Go locally:

```bash
docker run --rm -v "$PWD":/work -w /work golang:1.22-alpine sh scripts/verify.sh
```

> **Windows note:** this repo ships a [`.gitattributes`](.gitattributes) that forces
> LF line endings. Without it, Windows CRLF endings make `gofmt` report every Go
> file as unformatted and can break `Makefile` recipes inside Linux containers.
