# aws-agentcore-asz-demo

Run a **LangGraph** agent on **Amazon Bedrock AgentCore Runtime**, and observe it
end-to-end with **[Apache SkyWalking AI Sessionizer (asz)](https://github.com/apache/skywalking-ai-sessionizer)** —
no code changes to the agent, no LangSmith SaaS account.

This repo is the companion code for the
[Apache SkyWalking blog post](https://skywalking.apache.org/blog/2026-10-09-ai-sessionizer-agentcore/)
on running a LangGraph agent on AgentCore with AI Sessionizer. Everything
deploy-specific (region, account, image tags, endpoints) is a parameter — clone,
fill in `terraform.tfvars`, run.

> IaC is written for **OpenTofu** (`tofu`), the MPL-licensed open-source fork of
> Terraform. The `.tf` files are standard HCL and work unchanged with
> `terraform` too — only the binary name differs.

---

## The idea in one diagram

asz observes the **framework inside the container**, not AgentCore itself.
AgentCore is a transparent HTTP wrapper; the LangGraph `langsmith` tracing client
emits exactly as it would anywhere, pointed at asz's receiver instead of
LangSmith cloud.

```
INGEST plane (the real data source — must reach asz directly):
┌──────────────────────────┐
│ AgentCore microVM         │   LangSmith wire (4 env vars)
│  LangGraph + langsmith ───┼──────────────────────────────┐
│  + asz plugin (file edits)┼──────────────────────────────┤
└──────────────────────────┘                               ▼
                                        ┌───────────────────────────────┐
                                        │ asz  (persistent service)      │
                                        │  langsmith-ingest receiver     │
                                        │  → Conversation model → ./data  │
                                        │  full fidelity + replay + UI   │
                                        └───────────────┬───────────────┘
                                                        │ EXPORT plane (downstream only)
                                                        ▼  export.otlp.endpoint
                                        ┌───────────────────────────────┐
                                        │ SkyWalking OAP → BanyanDB       │
                                        │  stores landed files; NOT a    │
                                        │  substitute for ingest         │
                                        └───────────────────────────────┘
```

Two distinct planes — do not conflate them:

- **Ingest**: how asz *gets* the agent's data. The `langsmith` client (bundled in
  `langchain-core`) is pointed at asz's `langsmith-ingest` receiver via four env
  vars. This is the high-fidelity source and the only hop that *must* reach asz.
- **Export**: how asz hands landed files *downstream* to SkyWalking OAP → BanyanDB
  via `export.otlp.endpoint`. OTLP is a transport for already-captured data, never
  a collection source. OTLP does **not** cover all the data.

---

## Topology: two processes, two lifecycles

| | Where | Lifecycle | Registry |
|---|---|---|---|
| **LangGraph agent** | AgentCore Runtime microVM | ephemeral, per session | **ECR (required)** — AgentCore pulls from ECR |
| **asz collector** | ECS/Fargate (this repo) | persistent, shared, durable `/asz/data` on EFS | `ghcr.io/apache/skywalking-ai-sessionizer`, no ECR needed |

asz is **not** a sidecar. AgentCore Runtime runs one image per agent in ephemeral
microVMs — there is no sidecar slot. asz is a long-lived collector with durable
storage and a UI, so it runs as a separate service the microVM reaches over the
network.

---

## Two deploy modes (simple vs scale)

Both modes **ingest identically** (LangSmith wire + plugin). They differ only in
where asz stores/exports:

- **Simple** — asz standalone: local `/asz/data`, built-in UI on `:8787`, LangSmith receiver on `:1985`.
- **Scale** — asz additionally exports via `export.otlp.endpoint` to SkyWalking
  OAP + BanyanDB. The scale mode adds a downstream sink; it does not change
  collection.

---

## Repo layout

```
.
├── agent/                   # the LangGraph agent, packaged for AgentCore
│   ├── app.py               # tool-calling "deployment advisor" graph + /invocations + /ping
│   ├── Dockerfile           # linux/arm64 image for AgentCore Runtime
│   ├── requirements.txt     # what the image installs
│   ├── pyproject.toml       # local dev install (bootstrap.sh)
│   └── .env.example         # the 4 LANGSMITH_* env vars for Tier 1
├── config/
│   ├── asz-local.yaml       # Tier-1 asz config: receiver on :1985 + the changes adapter
│   └── asz-changes-settings.yaml  # which tools asz-changes watches (both tiers)
├── infra/terraform/         # OpenTofu: the WHOLE Tier-2 environment, agent included
│   ├── main.tf              # VPC, ECR, asz on ECS/Fargate + EFS + 2 ALBs, AgentCore runtime
│   ├── variables.tf         # ALL deploy params live here
│   ├── outputs.tf
│   ├── versions.tf
│   └── terraform.tfvars.example
├── scripts/
│   ├── bootstrap.sh         # check local toolchain + create venv
│   ├── run-asz-local.sh     # Tier 1: asz in docker (UI :8787, ingest :1985)
│   ├── run-agent-local.sh   # Tier 1: the agent's image, with file-change recording
│   ├── up.sh                # Tier 2: ECR -> push arm64 image -> apply everything
│   ├── invoke.sh            # Tier 2: play the demo conversation on AgentCore
│   └── down.sh              # Tier 2: destroy everything; `down.sh check` shows progress
└── docs/
    └── SETUP.md             # prerequisites + Tier-1 / Tier-2 walkthrough
```

---

## The demo conversation

The agent is a small LangGraph "deployment advisor". Three tools look facts up
(`search_docs`, `check_deployment`, `estimate_cost`), and three work on a clone of
this repository (`clone_demo_repo`, `read_file`, `write_file`). The demo plays the
conversation a developer actually has while setting this up: can asz be a
sidecar, why nothing landed on port 8787, whether OTLP is enough for replay, what
the PoC costs and how to tear it down, and finally "clone the repo and prepare my
`terraform.tfvars`". All five turns are one thread, so asz shows one conversation
with five rounds, their model calls and tool calls.

The last turn changes a file. The agent image carries `asz-changes` and the
LangChain shim from the pinned asz commit; the shim runs `asz-changes` around
`write_file` (the only tool `config/asz-changes-settings.yaml` names), which
scans the workspace before and after and records the difference. asz's `changes`
adapter files it beside that tool call. On AgentCore the clone lives on the
session's microVM and goes with it; the record lives in asz. The recorder writes
to an EFS access point the runtime mounts at `/mnt/changes`, and asz reads the
same directory.

With no `BEDROCK_MODEL_ID` a scripted stand-in model makes the same tool calls,
so Tier 1 needs no credential. Set it to use a real Bedrock model.

---

## Quick start

### Tier 1 — local observability validation (zero AWS)

```bash
./scripts/bootstrap.sh            # venv + deps + toolchain check
./scripts/run-asz-local.sh        # asz: UI 127.0.0.1:8787, ingest 127.0.0.1:1985
cd agent && set -a && . ./.env.example && set +a
.venv/bin/python app.py --local --demo --thread-id advisor-demo-001
# within ~10s: http://127.0.0.1:8787 shows ls-aws-agentcore-asz-demo-advisor-demo-001-...

# or the agent's own image, recording what write_file changes, as on AgentCore:
./scripts/run-agent-local.sh
```

### Tier 2 — real AWS

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars   # set asz_ui_cidrs
./scripts/up.sh       # ~10 min; everything is created by OpenTofu
                      # model: bedrock_model_id in tfvars (Nova Pro), or BEDROCK_MODEL_ID=... ./scripts/up.sh
./scripts/invoke.sh   # the demo conversation, on AgentCore, lands in the remote asz
./scripts/down.sh     # destroy everything (VPC can take hours: ./scripts/down.sh check)
```

See [`docs/SETUP.md`](docs/SETUP.md) for prerequisites, what gets created, and costs.

---

## Status / caveats

- Tier 1 is verified end to end (asz at commit `8104ada`, LangGraph 1.x, the arm64 agent image
  served over `/invocations` with an AgentCore session header).
- asz is pinned by upstream commit id, not a release tag, so the demo gets the
  newest features and fixes from `main` (currently `8104ada`, the UI fixes in
  apache/skywalking-ai-sessionizer#59). `:latest` and the release tags lag behind
  `main`. To move forward, set the full id of a newer `main` commit (CI publishes
  `ghcr.io/apache/skywalking-ai-sessionizer:<commit-id>`) in
  `scripts/run-asz-local.sh` and `var.asz_image`.
- Tier 2 was applied, exercised and torn down in `us-east-1` (OpenTofu, AWS
  provider 6.68) with `up.sh`, `invoke.sh` and `down.sh`.
- The agent keeps its graph history in memory (`InMemorySaver`). That history
  lives as long as the session's microVM: AgentCore stops it after 15 idle
  minutes by default (`agent_idle_session_timeout`), and a later call on the
  same session id starts with none. asz still files that call under the same
  conversation, so the replay shows the model was sent no history. Use a
  durable checkpointer for anything real.
- The receiver token is passed to the asz task as a plain task-definition
  environment value. Fine for a throwaway PoC; use Secrets Manager otherwise.
- `terraform.tfvars`, state files, `.deploy/` and `.env` are git-ignored.

## License

MIT © 吴晟 Wu Sheng
