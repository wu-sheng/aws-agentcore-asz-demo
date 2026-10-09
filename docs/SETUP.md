# Setup & verification guide

This guide lists everything you install locally, everything you must set up on
**AWS** to verify the full path, and the two-tier walkthrough.

---

## 1. Local toolchain (your dev machine)

| Tool | Why | Install (macOS) | Needed for |
|---|---|---|---|
| Python 3.10+ | LangGraph agent + AgentCore SDK | preinstalled / `brew install python` | Tier 1 + 2 |
| Docker Desktop | build ARM64 agent image; run asz locally | docker.com | Tier 1 + 2 |
| OpenTofu | the IaC in `infra/terraform/` (`tofu`) | `brew install opentofu` | Tier 2 |
| AWS CLI v2 | auth, ECR login, checks | `brew install awscli` | Tier 2 |
| gh CLI | repo operations | `brew install gh` | repo ops |

> Terraform works too (`brew tap hashicorp/tap && brew install hashicorp/tap/terraform`);
> the `.tf` files are standard HCL. OpenTofu is MPL-licensed and tap-free, which is
> why this repo targets it.

Run `./scripts/bootstrap.sh` to check the toolchain and create the agent venv.

---

## 2. What to set up on AWS (for eventual Tier-2 verification)

You do **not** need any of this for Tier 1. For the real-AWS PoC you need:

### 2.1 Account & access
- [ ] **An AWS account** (a "Bedrock account" is just an AWS account with Bedrock enabled).
- [ ] **Bedrock model access** granted in the Bedrock console — per-model opt-in
      (e.g. a Claude model). Only required if the agent uses a Bedrock model; the
      stub needs none.
- [ ] **Bedrock AgentCore available in your region.** Confirm AgentCore Runtime is
      offered in the region you pick (it was still rolling out regionally). Set that
      region as `aws_region`.
- [ ] **IAM permissions** for your deploy identity: ECR (create/push), ECS,
      EC2/VPC, EFS, ELB, IAM (create roles), CloudWatch Logs, and
      Bedrock AgentCore (create/invoke runtimes).

### 2.2 Local credentials
- [ ] `aws configure` **or** `aws sso login`, then reference the profile via
      `aws_profile` in `terraform.tfvars` and `AWS_PROFILE` in the scripts.
- [ ] A **Kiro account is NOT used** anywhere — Kiro is an IDE, unrelated to
      running your own agent on Bedrock/AgentCore.

### 2.3 Networking decision (the one real engineering question)
The AgentCore microVM must be able to reach the asz endpoint over the network.
Decide **before** `tofu apply`:
- [ ] **Public ALB** (`asz_alb_internal = false`) — simplest; narrow
      `asz_ingress_cidrs` to your IP + AgentCore's egress range. Good for a PoC.
- [ ] **Internal ALB** (`asz_alb_internal = true`) — asz stays VPC-private; requires
      AgentCore Runtime to egress into this VPC. **Confirm AgentCore's VPC-egress
      support against current docs** before choosing this.

### 2.4 Images / registries
- [ ] **Agent image → ECR (required).** Created by Terraform
      (`agent_ecr_repository_url` output); `build-push-agent.sh` pushes to it.
- [ ] **asz image.** The official multi-arch `skywalking-ai-sessionizer` image is
      pulled directly by Fargate — no ECR needed. Confirm the real published
      coordinates and set `asz_image`.

### 2.5 Cost note
This PoC provisions a NAT gateway, an ALB, a Fargate task, and EFS — all small but
**not free**. Run `tofu destroy` when done. `force_delete = true` on the ECR repo
is a PoC convenience.

---

## 3. Tier 1 — local observability validation (zero AWS)

Proves LangGraph → langsmith → asz with no cloud, no credential.

```bash
./scripts/bootstrap.sh
./scripts/run-asz-local.sh                 # asz on 127.0.0.1:8787
cp agent/.env.example agent/.env           # already points at localhost asz
cd agent && source .venv/bin/activate && set -a && . .env && set +a
python app.py --local
# open http://127.0.0.1:8787 — the conversation should appear
```

If it appears, the core claim is proven: AgentCore adds nothing to the data shape;
Tier 2 is purely a networking + packaging exercise.

---

## 4. Tier 2 — real AWS PoC

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill region/account/networking
tofu init
tofu apply                                      # VPC + ECR + EFS + ALB + ECS(asz)

export AWS_REGION=$(grep aws_region terraform.tfvars | cut -d'"' -f2)
export ASZ_ENDPOINT=$(tofu output -raw asz_endpoint)

../../scripts/build-push-agent.sh               # agent ARM64 image → ECR
../../scripts/deploy-agent.sh                   # register on AgentCore (verify toolkit cmds)
```

Invoke the deployed agent (via the AgentCore invoke API / console). The same
conversation should land in the remote asz UI at `asz_endpoint`.

### Scale mode (optional)
To exercise the "scale" deploy mode, configure asz's `export.otlp.endpoint` to a
SkyWalking OAP + BanyanDB backend. Ingest is unchanged; this only adds a downstream
sink. (Not provisioned by this repo's Terraform — add OAP/BanyanDB separately.)

---

## 5. Teardown

```bash
docker rm -f asz-local                 # Tier 1
cd infra/terraform && tofu destroy     # Tier 2 — removes NAT/ALB/Fargate/EFS cost
# plus: deregister the AgentCore runtime via the toolkit/console
```
