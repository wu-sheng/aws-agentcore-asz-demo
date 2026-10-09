#!/usr/bin/env bash
# Register / launch the agent on Bedrock AgentCore Runtime via the starter toolkit.
#
# WARNING: the AgentCore starter-toolkit command surface is UNVERIFIED against
# live docs (the AgentCore docs are JS-rendered and were not fetchable at authoring
# time). The commands below reflect the established convention — confirm against the
# current docs before relying on them. The deploy *shape* is stable:
#   SDK wraps handler  ->  ARM64 image in ECR  ->  register on AgentCore Runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${AWS_REGION:?set AWS_REGION}"
: "${ASZ_ENDPOINT:?set ASZ_ENDPOINT (from: tofu output -raw asz_endpoint)}"

cd "$ROOT/agent"

# The langsmith env vars pointing the agent at the remote asz receiver.
# These must be injected into the AgentCore runtime environment.
export LANGCHAIN_TRACING_V2="true"
export LANGCHAIN_ENDPOINT="$ASZ_ENDPOINT"
export LANGCHAIN_API_KEY="${LANGCHAIN_API_KEY:-asz-prod}"
export LANGCHAIN_PROJECT="${LANGCHAIN_PROJECT:-aws-agentcore-asz-demo}"

echo "Deploying agent to AgentCore Runtime in $AWS_REGION"
echo "  asz endpoint (traces -> here): $ASZ_ENDPOINT"
echo
echo "Established-convention commands (VERIFY against current docs):"
echo "  agentcore configure --entrypoint app.py --name langgraph-asz-demo"
echo "  agentcore launch \\"
echo "    --env LANGCHAIN_TRACING_V2=$LANGCHAIN_TRACING_V2 \\"
echo "    --env LANGCHAIN_ENDPOINT=$LANGCHAIN_ENDPOINT \\"
echo "    --env LANGCHAIN_API_KEY=*** \\"
echo "    --env LANGCHAIN_PROJECT=$LANGCHAIN_PROJECT"
echo
echo "This script intentionally does NOT execute those commands until the toolkit"
echo "surface is confirmed. Uncomment below once verified."

# agentcore configure --entrypoint app.py --name langgraph-asz-demo
# agentcore launch \
#   --env LANGCHAIN_TRACING_V2="$LANGCHAIN_TRACING_V2" \
#   --env LANGCHAIN_ENDPOINT="$LANGCHAIN_ENDPOINT" \
#   --env LANGCHAIN_API_KEY="$LANGCHAIN_API_KEY" \
#   --env LANGCHAIN_PROJECT="$LANGCHAIN_PROJECT"
