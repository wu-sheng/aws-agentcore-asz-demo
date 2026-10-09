#!/usr/bin/env bash
# Tier-2: play the demo conversation against the deployed AgentCore agent.
#
# All turns share one AgentCore runtime session id, so they land in asz as one
# conversation (the agent uses the session id as its thread).
#   ./scripts/invoke.sh                 the four-turn demo conversation
#   ./scripts/invoke.sh "question"      one turn on a fresh session
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/infra/terraform"

ARN="$(tofu output -raw agent_runtime_arn)"
[ -n "$ARN" ] || { echo "No agent runtime yet -- run ./scripts/up.sh first." >&2; exit 1; }
REGION="$(tofu console <<<'var.aws_region' | tr -d '"')"
UI="$(tofu output -raw asz_ui_url)"

# AgentCore requires a session id of at least 33 characters.
SESSION="advisor-$(date -u +%Y%m%d%H%M%S)-$(openssl rand -hex 10)"

if [ $# -gt 0 ]; then
  TURNS=("$@")
else
  # Same turns as `python app.py --local --demo`.
  TURNS=(
    "I'm deploying a LangGraph agent on Bedrock AgentCore Runtime. Can I run asz as a sidecar next to it?"
    "OK, separate service then. I pointed the LangSmith client at asz on 8787 and nothing landed. Which port should it be?"
    "Is asz's OTLP export enough for full replay, or do I still need the LangSmith wire?"
    "How much will the PoC cost if I leave it up for 4 hours, and how do I tear everything down afterwards?"
  )
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
for question in "${TURNS[@]}"; do
  echo
  echo "user> $question"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1]}))' "$question")"
  aws bedrock-agentcore invoke-agent-runtime \
    --region "$REGION" \
    --agent-runtime-arn "$ARN" \
    --runtime-session-id "$SESSION" \
    --content-type application/json \
    --payload "$payload" \
    --cli-binary-format raw-in-base64-out \
    "$OUT" >/dev/null
  echo "agent> $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("answer"))' "$OUT")"
done

echo
echo "session/thread: $SESSION"
echo "Within ~30s it is in asz as ls-<project>-$SESSION-...  ->  $UI"
