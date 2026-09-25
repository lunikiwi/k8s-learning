#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
bash -n bootstrap.sh && echo "SYNTAX OK"
docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable bootstrap.sh \
  && echo "SHELLCHECK CLEAN"
