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
Model access: `up.sh` calls the model once and stops before building anything if the account
cannot use it. The model is `bedrock_model_id` from tfvars (default `us.amazon.nova-pro-v1:0`),
or `BEDROCK_MODEL_ID` for one run, e.g. `BEDROCK_MODEL_ID=us.anthropic.claude-opus-4-6-v1 ./scripts/up.sh`.
To check by hand:
```bash
aws bedrock-runtime converse --region us-east-1 --model-id <model> \
  --messages '[{"role":"user","content":[{"text":"Reply with OK."}]}]' --inference-config maxTokens=8
```
- "Model use case details have not been submitted": the user submits the Anthropic use-case form
  in the Bedrock console (Model access), then waits ~15 minutes.
- "<model> is not available for this account": AWS does not serve that model to this account;
  only AWS Support or the account team can change it. Pick another model.
- Bedrock can let a Claude model's first calls through and enforce the form afterwards, so a
  model that answered earlier may refuse later. Check again right before deploying.

If `down.sh check` exits 3 because AgentCore's network interfaces still hold the old VPC, `up.sh`
can still run: OpenTofu reuses what is in state.

## Run

Run it in the background, logging to `.deploy/up.log`, because it takes ~10 minutes:
```bash
mkdir -p .deploy && ./scripts/up.sh > .deploy/up.log 2>&1; echo "exit=$?" >> .deploy/up.log
```
Steps: model check -> pull `ghcr.io/wu-sheng/aws-agentcore-asz-demo-agent:main` (built and
published only by the `agent-image` GitHub Actions workflow) and check its asz commit -> ECR repo ->
copy the image in -> `tofu apply` of everything else -> `.deploy/resources.txt` (the manifest
`down.sh` reads). It is re-runnable. `AGENT_IMAGE` picks another published tag. If `up.sh` says
the image's asz commit differs from `var.asz_image`, the workflow on main has not published
the current pin yet: wait for it (`gh run list -w agent-image`), do not build locally.

## After

- `tofu -chdir=infra/terraform output -raw asz_ui_url` - the replay page; the asz task needs about
  a minute to pass health checks.
- Record for the post or a PR: the "Apply complete! Resources: N added" line and the slowest
  "Creation complete after" lines in `.deploy/up.log`.
- Failures: the runtime's subnets refused -> set `availability_zone_ids` to supported AZ ids
  (`us-east-1`: `use1-az1`, `use1-az2`, `use1-az4`); see `docs/SETUP.md` 3.6.
- Next: the `verify-run` skill.
