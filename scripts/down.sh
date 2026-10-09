#!/usr/bin/env bash
# Tier-2: tear the whole environment down, then prove nothing is left.
#
#   1. tofu destroy -- every resource up.sh created is in state, including the
#      AgentCore runtime, the ECR repo (with its images) and EFS (with asz data)
#   2. delete the log groups AgentCore created at runtime, outside state
#   3. check: state empty, no resource tagged Project=<project> left, no
#      AgentCore runtime of ours left
#
# Destroys asz's stored conversations with EFS. Pass --yes to skip the prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$ROOT/infra/terraform"
MANIFEST="$ROOT/.deploy/resources.txt"
cd "$TF"

tofu init -input=false >/dev/null
REGION="$(tofu console <<<'var.aws_region' | tr -d '"')"
PROJECT="$(tofu console <<<'var.project_name' | tr -d '"')"
RUNTIME_ID="$(tofu output -raw agent_runtime_id 2>/dev/null || true)"
# Fall back to the manifest if state is already gone (e.g. a re-run).
if [ -z "$RUNTIME_ID" ] && [ -f "$MANIFEST" ]; then
  RUNTIME_ID="$(sed -n 's/^agent_runtime_id=//p' "$MANIFEST")"
fi

echo "About to destroy everything for project '$PROJECT' in $REGION:"
echo "  $(tofu state list | wc -l | tr -d ' ') resources in state, AgentCore runtime '${RUNTIME_ID:-none}'"
echo "  This deletes asz's stored conversations (EFS) and the agent images (ECR)."
if [ "${1:-}" != "--yes" ]; then
  read -r -p "Type the project name to confirm: " answer
  [ "$answer" = "$PROJECT" ] || { echo "Aborted."; exit 1; }
fi

echo "== 1/3 tofu destroy =="
# AgentCore and Fargate release their ENIs asynchronously; a subnet or
# security group can refuse deletion for a while (up to ~20 min). Retry.
attempt=1
until tofu destroy -input=false -auto-approve -var "agent_image_tag=unused"; do
  if [ "$attempt" -ge 10 ]; then
    echo "tofu destroy still failing after $attempt attempts; re-run ./scripts/down.sh --yes" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "  retrying in 120s (attempt $attempt/10) ..."
  sleep 120
done

echo "== 2/3 AgentCore runtime log groups =="
if [ -n "$RUNTIME_ID" ]; then
  groups="$(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "/aws/bedrock-agentcore/runtimes/$RUNTIME_ID" \
    --query 'logGroups[].logGroupName' --output text)"
  for g in $groups; do
    aws logs delete-log-group --region "$REGION" --log-group-name "$g"
    echo "  deleted $g"
  done
  [ -n "$groups" ] || echo "  none"
else
  echo "  no runtime id known; skipped"
fi

echo "== 3/3 verify nothing is left =="
left=0
n="$(tofu state list | wc -l | tr -d ' ')"
echo "  tofu state: $n resources"
[ "$n" = "0" ] || left=1

tagged="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=Project,Values=$PROJECT" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)"
if [ -n "$tagged" ]; then
  # The tagging index lags deletions by a few minutes; re-run to re-check.
  echo "  still tagged Project=$PROJECT (may be index lag, re-check in a few minutes):"
  printf '    %s\n' $tagged
  left=1
else
  echo "  tagged Project=$PROJECT: none"
fi

runtimes="$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?agentRuntimeName=='$(echo "${PROJECT}_agent" | tr - _)'].agentRuntimeId" --output text)"
if [ -n "$runtimes" ]; then
  echo "  AgentCore runtime still present: $runtimes"
  left=1
else
  echo "  AgentCore runtimes of ours: none"
fi

# IAM is global and the regional tagging index may not list roles; check by name.
prefix="$(printf '%s' "$PROJECT" | cut -c1-20)-"
roles="$(aws iam list-roles --query "Roles[?starts_with(RoleName, '$prefix')].RoleName" --output text)"
if [ -n "$roles" ]; then
  echo "  IAM roles still present: $roles"
  left=1
else
  echo "  IAM roles $prefix*: none"
fi

echo "  note: the AgentCore network service-linked role (AWSServiceRoleForBedrockAgentCoreNetwork),"
echo "        if AWS created one, is account-wide and shared with any other AgentCore VPC agent;"
echo "        it is left in place on purpose."

if [ "$left" = "0" ]; then
  rm -f "$MANIFEST"
  echo "Down. Nothing left."
else
  echo "Something is left (above); manifest kept at $MANIFEST." >&2
  exit 1
fi
