---
name: tier2-up
description: Create the demo's AWS environment (VPC, asz on ECS Fargate + EFS, the agent on Bedrock AgentCore Runtime) with scripts/up.sh, after preflight checks. Use when the user asks to deploy, redeploy or bring the demo up on AWS. It costs money; confirm with the user first.
---

# Tier 2: bring the environment up

Ask the user before running `up.sh`: it creates billable resources (~$0.125/h fixed, plus
AgentCore and Bedrock usage) and the run should end with the `tier2-down` skill.

## Preflight (all must pass)

```bash
aws sts get-caller-identity --output text                 # expired? ask the user to sign in again
docker info --format '{{.ServerVersion}}'                 # Docker running, with buildx
./scripts/down.sh check                                    # 0 = nothing left from a previous run
test -f infra/terraform/terraform.tfvars || echo "copy terraform.tfvars.example"
curl -s https://checkip.amazonaws.com                      # must be inside asz_ui_cidrs in tfvars
```
Model access: with an Anthropic `bedrock_model_id` (default `us.anthropic.claude-opus-4-7`),
```bash
aws bedrock-runtime converse --region us-east-1 --model-id us.anthropic.claude-opus-4-7 \
  --messages '[{"role":"user","content":[{"text":"Reply with OK."}]}]' --inference-config maxTokens=5
```
must answer. "Model use case details have not been submitted" means the user has to submit the
Anthropic use-case form in the Bedrock console (Model access) and wait ~15 minutes. Do not deploy
until it answers: every AgentCore invocation would return 500.

If `down.sh check` exits 3 because AgentCore's network interfaces still hold the old VPC, `up.sh`
can still run: OpenTofu reuses what is in state.

## Run

Run it in the background, logging to `.deploy/up.log`, because it takes ~10 minutes:
```bash
mkdir -p .deploy && ./scripts/up.sh > .deploy/up.log 2>&1; echo "exit=$?" >> .deploy/up.log
```
Steps: ECR repo -> `linux/arm64` agent image build and push -> `tofu apply` of everything else ->
`.deploy/resources.txt` (the manifest `down.sh` reads). It is re-runnable.

## After

- `tofu -chdir=infra/terraform output -raw asz_ui_url` - the replay page; the asz task needs about
  a minute to pass health checks.
- Record for the post or a PR: the "Apply complete! Resources: N added" line and the slowest
  "Creation complete after" lines in `.deploy/up.log`.
- Failures: the runtime's subnets refused -> set `availability_zone_ids` to supported AZ ids
  (`us-east-1`: `use1-az1`, `use1-az2`, `use1-az4`); see `docs/SETUP.md` 3.6.
- Next: the `verify-run` skill.
