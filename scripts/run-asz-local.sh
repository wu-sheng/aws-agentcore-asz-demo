#!/usr/bin/env bash
# Tier-1: run asz standalone, storing conversations in a local docker volume.
# This is the "simple" deploy mode — no OAP, no BanyanDB.
#
# Two ports, both bound to 127.0.0.1 on the host:
#   1985  langsmith-ingest receiver  (LANGSMITH_ENDPOINT points here)
#   8787  asz web UI                 (open in a browser)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASZ_IMAGE="${ASZ_IMAGE:-ghcr.io/apache/skywalking-ai-sessionizer:8104ada77cbd0d5ca69754d50cbbc0cd6f9bbec5}"
ASZ_UI_PORT="${ASZ_UI_PORT:-8787}"
ASZ_INGEST_PORT="${ASZ_INGEST_PORT:-1985}"
CONTAINER="${CONTAINER:-asz-local}"

# A named volume, not a bind mount: asz chmods its own files, which Docker
# Desktop's host file sharing refuses. A fresh named volume is root-owned, and
# the image runs as distroless "nonroot" (65532), so hand it over once.
ASZ_VOLUME="${ASZ_VOLUME:-asz-local-data}"
docker volume create "$ASZ_VOLUME" >/dev/null
docker run --rm -v "$ASZ_VOLUME:/d" busybox:1.37 chown 65532:65532 /d

echo "Starting asz ($ASZ_IMAGE) ..."
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER" \
  -p "127.0.0.1:${ASZ_UI_PORT}:8787" \
  -p "127.0.0.1:${ASZ_INGEST_PORT}:1985" \
  -v "$ROOT/config/asz-local.yaml:/asz/asz.yaml:ro" \
  -v "$ASZ_VOLUME:/asz/data" \
  "$ASZ_IMAGE"

echo "asz running."
echo "  UI:      http://127.0.0.1:${ASZ_UI_PORT}"
echo "  ingest:  http://127.0.0.1:${ASZ_INGEST_PORT}  (LANGSMITH_ENDPOINT, see agent/.env.example)"
echo "  data:    docker volume $ASZ_VOLUME (wipe: docker volume rm $ASZ_VOLUME)"
echo "Logs: docker logs -f $CONTAINER    Stop: docker rm -f $CONTAINER"
