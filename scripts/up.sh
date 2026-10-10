#!/usr/bin/env bash
# Tier-2: stand up the whole environment on AWS.
#
#   1. create the agent's ECR repo (the only thing the image push needs first)
#   2. build the linux/arm64 agent image and push it
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

echo "== 1/4 ECR repository =="
tofu apply -input=false -auto-approve -target=aws_ecr_repository.agent >/dev/null
REPO="$(tofu output -raw agent_ecr_repository_url)"
echo "  $REPO"

echo "== 2/4 agent image (linux/arm64) =="
TAG="${IMAGE_TAG:-$(date -u +%Y%m%d-%H%M%S)}"
# The image builds asz-changes and the LangChain shim from the commit the asz
# image is pinned to, so a recorded change lands under the conversation asz names.
ASZ_IMAGE="$(tofu console <<<'var.asz_image' | tr -d '"')"
ASZ_COMMIT="${ASZ_IMAGE##*:}"
[[ "$ASZ_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "var.asz_image must end in a full asz commit id (got '$ASZ_COMMIT'); see the bump-asz skill" >&2
  exit 1
}
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}" >/dev/null
docker buildx build --platform linux/arm64 --build-arg "ASZ_COMMIT=$ASZ_COMMIT" -t "$REPO:$TAG" --push "$ROOT/agent"
echo "  pushed $REPO:$TAG"

echo "== 3/4 environment (takes ~10 min: NAT, EFS, load balancers, AgentCore) =="
tofu apply -input=false -auto-approve -var "agent_image_tag=$TAG"

echo "== 4/4 resource manifest =="
mkdir -p "$DEPLOY"
{
  echo "# Written by scripts/up.sh at $(date -u +%FT%TZ). Removed by scripts/down.sh."
  echo "region=$REGION"
  echo "project_tag=$(tofu output -raw project_tag)"
  echo "agent_image=$REPO:$TAG"
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
