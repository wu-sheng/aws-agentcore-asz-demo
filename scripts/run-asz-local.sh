#!/usr/bin/env bash
# Tier-1: run asz standalone on 127.0.0.1:8787 with a local docker volume for
# durable /asz/data. This is the "simple" deploy mode — no OAP, no BanyanDB.
set -euo pipefail

ASZ_IMAGE="${ASZ_IMAGE:-apache/skywalking-ai-sessionizer:latest}"
ASZ_PORT="${ASZ_PORT:-8787}"
CONTAINER="${CONTAINER:-asz-local}"

echo "Starting asz ($ASZ_IMAGE) on 127.0.0.1:${ASZ_PORT} ..."
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER" \
  -p "127.0.0.1:${ASZ_PORT}:8787" \
  -v asz-local-data:/asz/data \
  "$ASZ_IMAGE"

echo "asz running. UI: http://127.0.0.1:${ASZ_PORT}"
echo "Point the agent's LANGCHAIN_ENDPOINT at http://127.0.0.1:${ASZ_PORT} (see agent/.env.example)."
echo "Stop with: docker rm -f $CONTAINER"
