#!/usr/bin/env bash
# Tier-2: stand up the whole environment on AWS.
#
#   1. create the agent's ECR repo (the only thing the image push needs first)
#   2. put the agent image there: the one GitHub Actions builds and publishes
#      to GHCR (.github/workflows/agent-image.yml), copied as is, because
#      AgentCore runs images only from ECR. Images are built and published
#      only by that workflow; AGENT_IMAGE picks another of its tags (e.g. a
#      commit id). Nothing is built here.
#   3. apply everything else: VPC, asz on ECS/Fargate + EFS + load balancers,
#      and the agent on AgentCore Runtime pointing at asz
#   4. write .deploy/resources.txt: what now exists, for scripts/down.sh
#
# Every resource is in OpenTofu state; scripts/down.sh removes all of it.
# Uses your AWS CLI credentials (AWS_PROFILE / default chain). Re-runnable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$ROOT/infra/terraform"
DEPLOY="$ROOT/.deploy"

[ -f "$TF/terraform.tfvars" ] || {
  echo "Missing $TF/terraform.tfvars -- copy terraform.tfvars.example and fill it in." >&2
  exit 1
}

cd "$TF"
tofu init -input=false >/dev/null
REGION="$(tofu console <<<'var.aws_region' | tr -d '"')"
export AWS_REGION="$REGION"
# Use the tfvars profile for the AWS CLI too, so tofu and aws act as one identity.
PROFILE="$(tofu console <<<'var.aws_profile == null ? "" : var.aws_profile' | tr -d '"')"
[ -z "$PROFILE" ] || export AWS_PROFILE="$PROFILE"

echo "== AWS identity =="
aws sts get-caller-identity --query Arn --output text

# The agent's model: BEDROCK_MODEL_ID overrides bedrock_model_id in tfvars
# (set it empty for the scripted stand-in). Bedrock decides per account which
# models it serves, and says so only when a model is called, so call it once
# here rather than learn it from a 500 on the first invocation.
MODEL="${BEDROCK_MODEL_ID-$(tofu console <<<'var.bedrock_model_id' | tr -d '"')}"
echo "== model: ${MODEL:-scripted stand-in, no Bedrock} =="
if [ -n "$MODEL" ]; then
  if ! out="$(aws bedrock-runtime converse --region "$REGION" --model-id "$MODEL" \
        --messages '[{"role":"user","content":[{"text":"Reply with OK."}]}]' \
        --inference-config maxTokens=16 --query 'output.message.content[0].text' --output text 2>&1)"; then
    echo "$out" | tail -1 >&2
    echo "This account cannot call $MODEL. Claude models need the account's Anthropic" >&2
    echo "use-case form (Bedrock console, Model access), and AWS does not serve every newer" >&2
    echo "model to every account. Pick one it can call, e.g.:" >&2
    echo "  BEDROCK_MODEL_ID=us.amazon.nova-pro-v1:0 ./scripts/up.sh" >&2
    exit 1
  fi
  echo "  answers"
fi

echo "== agent image =="
# The image carries asz-changes and the LangChain shim built from an asz
# commit; it must be the one the asz image is pinned to, so a recorded change
# lands under the conversation asz names.
ASZ_IMAGE="$(tofu console <<<'var.asz_image' | tr -d '"')"
ASZ_COMMIT="${ASZ_IMAGE##*:}"
[[ "$ASZ_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "var.asz_image must end in a full asz commit id (got '$ASZ_COMMIT'); see the bump-asz skill" >&2
  exit 1
}
AGENT_IMAGE="${AGENT_IMAGE:-ghcr.io/wu-sheng/aws-agentcore-asz-demo-agent:main}"
echo "  pulling $AGENT_IMAGE (published by GitHub Actions)"
docker pull -q --platform linux/arm64 "$AGENT_IMAGE" >/dev/null
built_with="$(docker image inspect --format '{{ index .Config.Labels "io.github.wu-sheng.asz-commit" }}' "$AGENT_IMAGE")"
if [ "$built_with" != "$ASZ_COMMIT" ]; then
  echo "  $AGENT_IMAGE carries asz-changes from asz ${built_with:-<unknown>}, but var.asz_image pins" >&2
  echo "  $ASZ_COMMIT: recorded file changes would not join their conversation. Wait for the" >&2
  echo "  agent-image workflow on main to publish the image for the pinned commit." >&2
  exit 1
fi

echo "== 1/4 ECR repository =="
tofu apply -input=false -auto-approve -target=aws_ecr_repository.agent >/dev/null
REPO="$(tofu output -raw agent_ecr_repository_url)"
echo "  $REPO"

echo "== 2/4 agent image, copied into ECR =="
TAG="${IMAGE_TAG:-$(date -u +%Y%m%d-%H%M%S)}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}" >/dev/null
docker tag "$AGENT_IMAGE" "$REPO:$TAG"
docker push -q "$REPO:$TAG" >/dev/null
echo "  pushed $REPO:$TAG"

echo "== 3/4 environment (takes ~10 min: NAT, EFS, load balancers, AgentCore) =="
tofu apply -input=false -auto-approve -var "agent_image_tag=$TAG" -var "bedrock_model_id=$MODEL"

echo "== 4/4 resource manifest =="
mkdir -p "$DEPLOY"
{
  echo "# Written by scripts/up.sh at $(date -u +%FT%TZ). Removed by scripts/down.sh."
  echo "region=$REGION"
  echo "project_tag=$(tofu output -raw project_tag)"
  echo "agent_image=$REPO:$TAG  (copied from $AGENT_IMAGE)"
  echo "model=${MODEL:-scripted stand-in}"
  echo "agent_runtime_id=$(tofu output -raw agent_runtime_id)"
  echo "agent_runtime_arn=$(tofu output -raw agent_runtime_arn)"
  echo
  echo "# In OpenTofu state (tofu destroy removes these):"
  tofu state list
  echo
  echo "# Created by AWS at runtime, outside state:"
  echo "#   log groups /aws/bedrock-agentcore/runtimes/$(tofu output -raw agent_runtime_id)-*   (down.sh deletes)"
  echo "#   service-linked role AWSServiceRoleForBedrockAgentCoreNetwork      (account-wide; down.sh reports)"
} >"$DEPLOY/resources.txt"
echo "  $DEPLOY/resources.txt ($(tofu state list | wc -l | tr -d ' ') resources in state)"

echo
echo "Up. asz UI: $(tofu output -raw asz_ui_url)   (the asz task may need ~1 min to pass health checks)"
echo "Next: ./scripts/invoke.sh     Tear down: ./scripts/down.sh"
