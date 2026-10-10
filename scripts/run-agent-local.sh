#!/usr/bin/env bash
# Tier-1: run the agent's container image locally, against asz-local
# (scripts/run-asz-local.sh), with file-change recording on, as on AgentCore.
#
#   ./scripts/run-agent-local.sh                    the five-turn demo, a fresh thread
#   ./scripts/run-agent-local.sh -q "question"      one turn
#   THREAD=<id> ./scripts/run-agent-local.sh -q ..  continue a thread
#
# It runs the same image up.sh pushes to ECR, built for this machine. With no
# BEDROCK_MODEL_ID the agent uses its scripted stand-in model. To use a real
# model, export BEDROCK_MODEL_ID and credentials the container can read
# (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN, e.g. from
# `aws configure export-credentials --format env`, or AWS_BEARER_TOKEN_BEDROCK).
#
# The workspace the agent clones into lives in the container and goes with it,
# like a session's microVM; what write_file changed stays in asz.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${AGENT_IMAGE:-asz-demo-agent:local}"
NETWORK="${NETWORK:-asz-demo}"
CHANGES_VOLUME="${CHANGES_VOLUME:-asz-local-changes}"
THREAD="${THREAD:-local-$(date -u +%Y%m%d%H%M%S)}"
ASZ_COMMIT="$(sed -n 's/^ASZ_IMAGE=.*skywalking-ai-sessionizer:\([0-9a-f]\{40\}\).*/\1/p' "$ROOT/scripts/run-asz-local.sh")"

docker inspect asz-local >/dev/null 2>&1 || { echo "asz-local is not running: ./scripts/run-asz-local.sh first" >&2; exit 1; }

if [ "${SKIP_BUILD:-}" != 1 ]; then
  echo "Building $IMAGE (asz-changes and the shim from asz ${ASZ_COMMIT:0:7}) ..."
  docker buildx build --build-arg "ASZ_COMMIT=$ASZ_COMMIT" -t "$IMAGE" --load "$ROOT/agent" >/dev/null
fi

[ $# -gt 0 ] || set -- --demo

pass=()
for v in BEDROCK_MODEL_ID AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK; do
  [ -z "${!v:-}" ] || pass+=(-e "$v")
done

# uid 65532: on AgentCore the EFS access point makes every write this user,
# the one asz runs as; here the container runs as it, for the same result.
docker run --rm \
  --network "$NETWORK" \
  --user 65532:65532 \
  -e HOME=/tmp/home \
  -e LANGSMITH_TRACING=true \
  -e LANGSMITH_ENDPOINT=http://asz-local:1985 \
  -e LANGSMITH_API_KEY=local \
  -e LANGSMITH_PROJECT=aws-agentcore-asz-demo \
  -e DEMO_WORKSPACE=/tmp/home/workspace \
  -e ASZ_CHANGES=true \
  -e ASZ_WATCH=/tmp/home/workspace \
  -e ASZ_CHANGES_DATA=/mnt/changes \
  -v "$CHANGES_VOLUME:/mnt/changes" \
  ${pass[@]+"${pass[@]}"} \
  "$IMAGE" python app.py --local --thread-id "$THREAD" "$@"

echo
echo "thread: $THREAD  ->  http://127.0.0.1:8787 (ls-aws-agentcore-asz-demo-${THREAD}-...)"
