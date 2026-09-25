#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
# Re-run on the existing cluster: exercises the idempotent paths and the new
# "can Argo CD actually render from Git?" check with its kubectl fallback.
./bootstrap.sh --skip-build 2>&1 | grep -v -E '^\x1b\[36mINFO' | tail -60
