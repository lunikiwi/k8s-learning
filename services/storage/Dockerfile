# syntax=docker/dockerfile:1

# ─── Stage 1: Build ──────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /src

COPY go.mod go.su[m] ./
RUN go mod download

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build \
      -ldflags="-s -w" \
      -trimpath \
      -o /storage-service \
      .

# ─── Stage 2: Final ──────────────────────────────────────────────────────────
FROM scratch

USER 65532:65532

COPY --from=builder /storage-service /storage-service

EXPOSE 8080

ENTRYPOINT ["/storage-service"]
