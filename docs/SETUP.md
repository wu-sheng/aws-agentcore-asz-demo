# Setup & verification guide

## 1. Local toolchain

| Tool | Why | Install (macOS) | Needed for |
|---|---|---|---|
| Python 3.10+ | the agent | `brew install python` | Tier 1 + 2 |
| Docker Desktop (with buildx) | asz locally; build the arm64 agent image | docker.com | Tier 1 + 2 |
| OpenTofu | `infra/terraform/` (`tofu`) | `brew install opentofu` | Tier 2 |
| AWS CLI v2 | credentials, ECR login, invoking the agent | `brew install awscli` | Tier 2 |

`./scripts/bootstrap.sh` checks these and creates `agent/.venv`.
Terraform works too; the `.tf` files are standard HCL.

---

## 2. Tier 1 — local, zero AWS

```bash
./scripts/bootstrap.sh
./scripts/run-asz-local.sh          # UI 127.0.0.1:8787, receiver 127.0.0.1:1985
cd agent && set -a && . ./.env.example && set +a
.venv/bin/python app.py --local --demo --thread-id advisor-demo-001
```

Within ~10s, http://127.0.0.1:8787 lists
`ls-aws-agentcore-asz-demo-advisor-demo-001-…`: four rounds, each with its LLM
calls and tool calls. From the CLI:

```bash
docker exec asz-local /usr/local/bin/asz index
docker exec asz-local /usr/local/bin/asz verify
```

Real model instead of the stand-in: set `BEDROCK_MODEL_ID` (and a Bedrock API key
in `AWS_BEARER_TOKEN_BEDROCK`, or its alias `AWS_BEDROCKS_API`, or AWS credentials).

Things that bite: the receiver is **1985**, not the UI's 8787; asz only runs it
when `langsmith-ingest` is enabled (`config/asz-local.yaml`); the published image
is on **GHCR**, not Docker Hub.

Stop: `docker rm -f asz-local` (data stays in volume `asz-local-data`;
`docker volume rm asz-local-data` wipes it).

---

## 3. Tier 2 — real AWS

### 3.1 What you need on AWS

- [ ] An account and a region that offers **Bedrock AgentCore Runtime** (`aws_region`).
- [ ] **Bedrock model access** for `bedrock_model_id` (console, per model). Leave
      `bedrock_model_id` empty to run the stand-in model with no Bedrock cost.
- [ ] Credentials in your terminal: `aws configure` / `aws sso login`; check with
      `aws sts get-caller-identity`. Set `aws_profile` in tfvars or `AWS_PROFILE`.
- [ ] Permission to create: VPC/EC2 networking, NAT + EIP, ECR, ECS, EFS, ELB,
      IAM roles, CloudWatch Logs, Bedrock AgentCore runtimes.

### 3.2 Run

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
#   set asz_ui_cidrs to your IP:  curl -s https://checkip.amazonaws.com
./scripts/up.sh
./scripts/invoke.sh
#   open the asz_ui_url it prints; the conversation is ls-<project>-<session>-…
./scripts/down.sh
```

`up.sh` applies in two steps because the AgentCore runtime needs the image to
exist: it creates the ECR repo, builds and pushes `linux/arm64`, then applies
everything else with that tag.

### 3.3 What gets created

```
                          ┌──────────────── VPC (private subnets) ─────────────────┐
 you ──8787──► public ALB ─┤                                                        │
  (asz_ui_cidrs only)      │  asz on Fargate ◄──1985── internal ALB ◄── AgentCore    │
                           │   /asz/data on EFS        (agent SG only)    agent ENIs │
                           │                                              │          │
                           └──────────────────────────────────── NAT ─────┴──► Bedrock, ECR
```

- The agent runs in **AgentCore VPC mode** in the private subnets. It reaches the
  receiver through an **internal** load balancer that only its security group may
  call, and sends the generated token as `LANGSMITH_API_KEY`.
- Each AgentCore runtime session is one asz conversation: the agent uses the
  session id as its thread. `invoke.sh` sends all turns on one session.
- asz runs one task (one writer to its storage root). The image is distroless, so
  a one-shot init container writes its `asz.yaml`.

Every resource is in OpenTofu state and tagged `Project=<project_name>`.
`up.sh` writes the list to `.deploy/resources.txt`. AWS itself creates two
things outside state:

| Created by AWS | Removed by |
|---|---|
| log groups `/aws/bedrock-agentcore/runtimes/<runtime-id>-*` | `down.sh` deletes them |
| service-linked role `AWSServiceRoleForBedrockAgentCoreNetwork` (VPC mode) | left: account-wide, shared with any other AgentCore VPC agent |

### 3.4 Cost

Fixed while up, us-east-1: NAT gateway ~$0.045/h, two ALBs ~$0.045/h, Fargate
0.5 vCPU / 1 GB arm64 ~$0.02/h, plus NAT data, EFS and logs at cents. About
**$0.11/hour**, ~$2.70/day. AgentCore bills per active session; Bedrock per token.

### 3.5 Teardown

```bash
./scripts/down.sh          # asks you to type the project name; --yes skips
```

1. `tofu destroy` (retries: AgentCore and Fargate release ENIs asynchronously, so
   a subnet or security group can refuse deletion for a few minutes).
2. Deletes the runtime's log groups.
3. Verifies: state is empty, nothing tagged `Project=<project>` remains, no
   AgentCore runtime of ours remains. Exits non-zero and keeps the manifest if
   anything is left. The tagging index lags a few minutes; re-run to re-check.

This deletes asz's stored conversations (EFS) and the agent images (ECR).

### 3.6 If something fails

- **apply fails on the runtime's subnets**: AgentCore VPC mode supports only some
  AZs per region. Set `availability_zone_ids` to supported AZ ids and re-run `up.sh`.
- **conversation never appears**: `aws logs tail /ecs/<project>-asz --follow`
  shows asz; the agent's logs are under `/aws/bedrock-agentcore/runtimes/`.
- **UI unreachable**: `asz_ui_cidrs` must include your current public IP.

### 3.7 Scale mode (optional)

Add `export.otlp.endpoint` to the asz config (`local.asz_config` in `main.tf`) to
also ship landed files to SkyWalking OAP + BanyanDB. Ingest is unchanged.
OAP/BanyanDB are not provisioned here.
