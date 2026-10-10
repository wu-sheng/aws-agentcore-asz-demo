# Setup & verification guide

## 1. Local toolchain

| Tool | Why | Install (macOS) | Needed for |
|---|---|---|---|
| Python 3.10+ | the agent | `brew install python` | Tier 1 + 2 |
| Docker Desktop (with buildx) | asz locally; Tier-1 agent image builds; `up.sh` copies the published agent image into ECR | docker.com | Tier 1 + 2 |
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
`ls-aws-agentcore-asz-demo-advisor-demo-001-…`: five rounds, each with its LLM
calls and tool calls. From the CLI:

```bash
docker exec asz-local /usr/local/bin/asz index
docker exec asz-local /usr/local/bin/asz verify
```

Real model instead of the stand-in: set `BEDROCK_MODEL_ID` (and a Bedrock API key
in `AWS_BEARER_TOKEN_BEDROCK`, or its alias `AWS_BEDROCKS_API`, or AWS credentials).

With file-change recording, as on AgentCore: run the agent's own image instead of
the venv. It builds `asz-changes` and the LangChain shim in, writes what
`write_file` changed to the `asz-local-changes` volume, and asz shows the diff on
that tool step:

```bash
./scripts/run-agent-local.sh      # builds the image, plays the five turns on a fresh thread
```

Things that bite: the receiver is **1985**, not the UI's 8787; asz only runs it
when `langsmith-ingest` is enabled (`config/asz-local.yaml`); the published image
is on **GHCR**, not Docker Hub.

Stop: `docker rm -f asz-local` (data stays in volumes `asz-local-data` and
`asz-local-changes`; `docker volume rm` wipes them).

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

The agent image is built and published only by GitHub Actions
(`.github/workflows/agent-image.yml`): `linux/arm64`, to
`ghcr.io/wu-sheng/aws-agentcore-asz-demo-agent`, tagged with the commit and `main`.
AgentCore runs images only from ECR, so `up.sh` pulls that image, checks it carries
`asz-changes` from the asz commit `var.asz_image` pins, creates the ECR repo, copies
the image in, then applies everything else with that tag. `AGENT_IMAGE` picks
another published tag, e.g. a commit id. Nothing is built locally for Tier 2.

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
  session id as its thread. `invoke.sh` sends all turns on one session, and
  `SESSION=<id> ./scripts/invoke.sh "question"` adds a turn to an earlier one.
- The graph's history is in memory, so it lasts as long as the session's
  microVM. AgentCore stops an idle session after 15 minutes by default
  (`agent_idle_session_timeout` changes it); a later turn on the same session id
  runs in a fresh microVM with no history, and asz files it in the same
  conversation, where its prompt shows exactly that.
- asz runs one task (one writer to its storage root). The image is distroless, so
  a one-shot init container writes its `asz.yaml`.
- File changes: the agent image carries `asz-changes` and the LangChain shim,
  built from the asz commit `var.asz_image` names (`up.sh` passes it). The runtime
  mounts an EFS access point at `/mnt/changes` (uid 65532, IAM-authenticated, NFS
  from the agent's security group); `asz-changes` writes there what `write_file`
  changed in the conversation's workspace, `/home/agent/workspace/<thread>`, and asz
  reads the same directory at
  `/asz/changes`. The init container writes `config/asz-changes-settings.yaml`
  there. If that mount fails, AgentCore fails every invocation with HTTP 424.

Every resource is in OpenTofu state and tagged `Project=<project_name>`.
`up.sh` writes the list to `.deploy/resources.txt`. AWS itself creates two
things outside state:

| Created by AWS | Removed by |
|---|---|
| log groups `/aws/bedrock-agentcore/runtimes/<runtime-id>-*` | `down.sh` deletes them |
| service-linked role `AWSServiceRoleForBedrockAgentCoreNetwork` (VPC mode) | left: account-wide, shared with any other AgentCore VPC agent |

### 3.4 Cost

Fixed while up, us-east-1: NAT gateway ~$0.045/h, two ALBs ~$0.045/h, Fargate
0.5 vCPU / 1 GB arm64 ~$0.02/h, three public IPv4 addresses (the NAT's EIP and the
public ALB in two AZs) ~$0.015/h. About **$0.125/hour**, ~$3/day. On top: ALB
LCUs, NAT data, EFS, ECR and logs (cents at demo volume), AgentCore for the CPU
and memory its sessions use, and Bedrock per token.

### 3.5 Teardown

```bash
./scripts/down.sh          # asks you to type the project name; --yes skips
./scripts/down.sh check    # read-only: what is removed, what is still in progress
```

`down.sh` requests deletion of everything, then waits up to 10 minutes
(`--wait <seconds>` changes it) for it to finish:

1. `tofu destroy`, repeated every minute while anything is left in state.
2. Deletes the runtime's log groups, which AWS creates outside state.
3. Prints a status report: every resource from `.deploy/resources.txt` that is
   gone ("ok"), and everything still in progress ("wip"), each marked as free or
   billable. Exit 0 means finished and nothing left; exit 3 means still in progress.

Expect exit 3. AWS keeps AgentCore's network interfaces in the agent's subnets
for [up to 8 hours](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html)
after the runtime is deleted; in our run it took about 10. You cannot delete
them yourself. Until they go, the VPC, its two private subnets and the agent
security group stay. They cost nothing; everything that bills is gone within
the first pass. Later, run `./scripts/down.sh check` to see where it stands,
and `./scripts/down.sh --yes` to finish (it is safe to re-run).

"Finished" is decided by OpenTofu state, the AgentCore runtime list, the log
groups and the IAM roles. The tagging index is shown only as a note: it lags
deletions, and keeps INACTIVE ECS clusters and task definitions for a while.

This deletes asz's stored conversations (EFS) and the agent images (ECR).

### 3.6 If something fails

- **apply fails on the runtime's subnets**: AgentCore VPC mode supports only some
  AZs per region. Set `availability_zone_ids` to supported AZ ids and re-run `up.sh`.
- **up.sh stops at "model"**, or **invoke returns 500 on every turn**: the account
  cannot call the model. `up.sh` checks with one `converse` call and prints Bedrock's
  reason. "Model use case details have not been submitted": submit the Anthropic
  use-case form (Bedrock console, Model access) and wait ~15 min. "is not available
  for this account": AWS does not serve that model to this account; ask AWS Support,
  or pick another model, e.g. `BEDROCK_MODEL_ID=us.amazon.nova-pro-v1:0 ./scripts/up.sh`.
- **apply fails with "Execution role is missing required filesystem permissions"**:
  `CreateAgentRuntime` checks `elasticfilesystem:DescribeAccessPoints` and
  `DescribeMountTargets` without a resource; `main.tf` grants both on `*`.
- **up.sh fails pushing the image** (`proxyconnect ... i/o timeout`): a proxy timed out
  mid-layer. `up.sh` retries three times; re-running it skips layers already in ECR.
- **conversation never appears**: `aws logs tail /ecs/<project>-asz --follow`
  shows asz; the agent's logs are under `/aws/bedrock-agentcore/runtimes/`.
- **UI unreachable**: `asz_ui_cidrs` must include your current public IP.

### 3.7 Scale mode (optional)

Add `export.otlp.endpoint` to the asz config (`local.asz_config` in `main.tf`) to
also ship landed files to SkyWalking OAP + BanyanDB. Ingest is unchanged.
OAP/BanyanDB are not provisioned here.
