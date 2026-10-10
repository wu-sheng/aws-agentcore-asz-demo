# aws-agentcore-asz-demo

A LangGraph agent on Amazon Bedrock AgentCore Runtime, traced into Apache SkyWalking
AI Sessionizer (asz) with four `LANGSMITH_*` environment variables and no tracing code.
Companion code for https://skywalking.apache.org/blog/2026-10-09-ai-sessionizer-agentcore/
(source in `~/github/skywalking-website/content/blog/2026-10-09-ai-sessionizer-agentcore/`).

## Layout

- `agent/app.py` — the agent: a "deployment advisor" graph with three tools (`search_docs`,
  `check_deployment`, `estimate_cost`), `InMemorySaver`, and the AgentCore entrypoint. With no
  `BEDROCK_MODEL_ID` it runs a scripted stand-in model, so Tier 1 needs no credentials.
  `DEMO_TURNS` is the four-question demo; `scripts/invoke.sh` repeats the same four.
- `agent/Dockerfile` — `linux/arm64` image (AgentCore requires arm64, pulled from ECR).
- `config/asz-local.yaml` — Tier-1 asz config: only the `langsmith-ingest` receiver.
- `infra/terraform/` — OpenTofu for the whole Tier-2 environment, the AgentCore runtime
  included. Every deploy-specific value is a variable (`variables.tf`); the operator's values
  live in `terraform.tfvars` (git-ignored; copy from `terraform.tfvars.example`).
- `scripts/` — `bootstrap.sh`, `run-asz-local.sh` (Tier 1); `up.sh`, `invoke.sh`, `down.sh` (Tier 2).
- `docs/SETUP.md` — prerequisites, what gets created, cost, teardown, troubleshooting.
- `.deploy/` (git-ignored) — run artifacts: `resources.txt` (manifest written by `up.sh`,
  read by `down.sh`), `up.log`, `down.log`, `evidence/`, `shots/`, `pw/` (Playwright).

## Two tiers

- **Tier 1, local, no AWS:** asz in Docker (UI `127.0.0.1:8787`, receiver `127.0.0.1:1985`),
  the agent in a venv. Skill: `tier1-local`.
- **Tier 2, real AWS:** VPC, NAT, two ALBs (internal :1985 for the receiver, public :8787 for the
  UI, restricted to `asz_ui_cidrs`), asz on ECS Fargate with EFS, S3 gateway endpoint, and the
  agent on AgentCore Runtime in VPC mode. Skills: `tier2-up`, `verify-run`, `tier2-down`.

## Facts that are easy to get wrong

- The receiver is port **1985**; **8787** is the replay page. The receiver is off by default and
  its default address is `127.0.0.1:1985`, so in a container it must listen on `0.0.0.0`.
  The collector interval is set to 30s (Tier 2) / 10s (Tier 1); asz's default is 10 minutes.
- asz is pinned by **upstream commit id**, not a release tag, in two places that must agree:
  `scripts/run-asz-local.sh` (`ASZ_IMAGE`) and `var.asz_image`. `:latest` is the last release
  and lags `main`. Skill: `bump-asz`.
- The default model is `us.anthropic.claude-opus-4-7`. Any Anthropic model needs the account's
  one-time Anthropic use-case form (Bedrock console, Model access); without it every AgentCore
  invocation returns `RuntimeClientError (500)`. A direct `aws bedrock-runtime converse` names it.
- One AgentCore session = one asz conversation: the agent uses the runtime session id as the
  LangGraph thread and as run metadata. Session ids must be at least 33 characters. The asz
  conversation name is `ls-<project>-<shortened session id>-<digest>`; `invoke.sh` prints the full id.
- AgentCore stops an idle session's microVM after 15 minutes by default (`agent_idle_session_timeout`),
  8 hours at most. The next call on the same session id gets a new microVM: `InMemorySaver` is empty.
- AgentCore VPC mode works only in some AZs (`us-east-1`: `use1-az1`, `use1-az2`, `use1-az4`);
  set `availability_zone_ids` if apply fails on the runtime's subnets.
- Teardown can take hours: AWS keeps AgentCore's `agentic_ai` network interfaces for up to 8 hours
  after the runtime is deleted (about 10 in our run), and they hold the VPC, private subnets and
  agent security group. `down.sh` exits **3** while that is in progress; `./scripts/down.sh check`
  is read-only; `./scripts/down.sh --yes` later finishes. Exit 0 = finished, 1 = error/aborted.
- `AWSServiceRoleForBedrockAgentCoreNetwork` is account-wide and shared; never delete it.
- The UI is plain HTTP; asz's copy buttons work there only from asz `8104ada` on.

## Working rules

- **Tier 2 costs money** (about $0.125/h fixed, plus AgentCore and Bedrock). Ask before running
  `up.sh`, keep the environment up only as long as the task needs, and end with `down.sh`.
- **Credentials are the user's.** If AWS calls fail with `ExpiredToken`/`RequestExpired`, ask the
  user to sign in again (`aws login` or their SSO); never handle keys or passwords.
- Run `up.sh` and `down.sh` in the background with their output in `.deploy/*.log`: they can
  outlast a 30-minute foreground tool timeout, and killing `tofu` mid-apply leaves state locked.
- Never commit `terraform.tfvars`, state, `.deploy/`, or `agent/.env`.
- Keep everything deploy-specific in variables; nothing account- or region-specific in `.tf` files.
- After changing `infra/terraform/`: `tofu fmt -check` and `tofu validate` (in `infra/terraform`).
  After changing scripts: `bash -n scripts/*.sh`. After changing the agent: `python3 -m py_compile agent/app.py`.
- Commits: plain imperative subject, a body that says why; no AI attribution trailers.
  PRs: `## Summary`, `## Tested`, and `## Not tested` when something was not run against AWS.
