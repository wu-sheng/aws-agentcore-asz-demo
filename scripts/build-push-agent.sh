#!/usr/bin/env bash
# Build the ARM64 agent image and push it to the ECR repo created by Terraform.
# AgentCore Runtime requires an ARM64 image in ECR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${AWS_REGION:?set AWS_REGION}"
: "${AWS_PROFILE:=default}"
: "${IMAGE_TAG:=latest}"

# ECR repo URL — read from terraform output, or override via ECR_REPO_URL.
if [ -z "${ECR_REPO_URL:-}" ]; then
  echo "Reading ECR repo URL from terraform output..."
  ECR_REPO_URL="$(cd "$ROOT/infra/terraform" && tofu output -raw agent_ecr_repository_url)"
fi

REGISTRY="${ECR_REPO_URL%%/*}"

echo "Logging in to ECR ($REGISTRY) ..."
aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Building + pushing ARM64 image -> ${ECR_REPO_URL}:${IMAGE_TAG}"
docker buildx build \
  --platform linux/arm64 \
  -t "${ECR_REPO_URL}:${IMAGE_TAG}" \
  --push \
  "$ROOT/agent"

echo "Done. Agent image: ${ECR_REPO_URL}:${IMAGE_TAG}"
echo "Next: ./scripts/deploy-agent.sh"
