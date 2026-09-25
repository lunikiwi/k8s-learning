# syntax=docker/dockerfile:1

# ─── Stage 1: Build ──────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS builder

# Provided automatically by BuildKit; lets one Dockerfile serve amd64 and arm64
# (e.g. Apple Silicon or Raspberry Pi k3s nodes).
ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /src

# Cache the dependency layer separately so it is only re-resolved when the
# module files change. The glob keeps this working while go.sum does not exist
# (the services have no external dependencies).
COPY go.mod go.su[m] ./
RUN go mod download

COPY main.go ./

# Static binary: no CGO, stripped debug info and symbol table → smallest size.
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build \
      -ldflags="-s -w" \
      -trimpath \
      -o /gateway-service \
      .

# ─── Stage 2: Final ──────────────────────────────────────────────────────────
FROM scratch

# Run as non-root UID 65532 (distroless "nonroot" convention).
# Numeric UID is required: scratch has no /etc/passwd to resolve a name.
USER 65532:65532

COPY --from=builder /gateway-service /gateway-service

EXPOSE 8080

ENTRYPOINT ["/gateway-service"]
