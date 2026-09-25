#!/bin/sh
# Verification script: normalizes line endings, then checks gofmt / vet / build.
# Intended to be run inside a golang:1.22-alpine container.
set -e

apk add --no-cache dos2unix file >/dev/null 2>&1 || true

echo "=== normalizing line endings (CRLF -> LF) ==="
find . -type f \( -name '*.go' -o -name 'go.mod' -o -name 'Dockerfile' \
     -o -name 'Makefile' -o -name '*.sh' -o -name '*.md' \
     -o -name '.gitignore' -o -name '.gitattributes' -o -name '.dockerignore' \) \
     -exec dos2unix -q {} +

echo "=== file types ==="
file services/gateway/main.go services/processor/main.go services/storage/main.go Makefile

echo "=== gofmt -l (empty output == clean) ==="
gofmt -l services/
echo "--- end gofmt ---"

for s in gateway processor storage; do
  echo "=== $s: vet + build ==="
  cd "services/$s"
  go vet ./...
  go build -o "/tmp/$s" .
  echo "$s OK"
  cd ../..
done

echo "=== ALL CHECKS PASSED ==="
