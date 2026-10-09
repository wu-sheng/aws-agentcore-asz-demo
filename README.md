# aws-agentcore-asz-demo

Run a **LangGraph** agent on **Amazon Bedrock AgentCore Runtime**, and observe it
end-to-end with **[Apache SkyWalking AI Sessionizer (asz)](https://github.com/apache/skywalking-ai-sessionizer)** —
no code changes to the agent, no LangSmith SaaS account.

This repo is the companion code for the blog post *"AgentCore is just the box:
running LangGraph in production with full-fidelity observability."* Everything
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
| **asz collector** | ECS/Fargate (this repo) or EC2 | persistent, shared, durable `/asz/data` | official multi-arch image; ECR optional |

asz is **not** a sidecar. AgentCore Runtime runs one image per agent in ephemeral
microVMs — there is no sidecar slot. asz is a long-lived collector with durable
storage and a UI, so it runs as a separate service the microVM reaches over the
network.

---

## Two deploy modes (simple vs scale)

Both modes **ingest identically** (LangSmith wire + plugin). They differ only in
where asz stores/exports:

- **Simple** — asz standalone: local `/asz/data`, built-in UI on `:8787`.
- **Scale** — asz additionally exports via `export.otlp.endpoint` to SkyWalking
  OAP + BanyanDB. The scale mode adds a downstream sink; it does not change
  collection.

---

## Repo layout

```
.
├── agent/                   # the LangGraph agent, packaged for AgentCore
│   ├── app.py               # graph + AgentCore /invocations + /ping handler
│   ├── Dockerfile           # ARM64 image for AgentCore Runtime
│   ├── pyproject.toml       # langgraph, langchain, bedrock-agentcore, langsmith
│   └── .env.example         # the 4 langsmith env vars + thread-id convention
├── infra/
│   └── terraform/           # OpenTofu/Terraform: ECS(asz) + ECR + ALB + EFS + VPC
│       ├── main.tf
│       ├── variables.tf     # ALL deploy params live here
│       ├── outputs.tf
│       ├── versions.tf
│       └── terraform.tfvars.example
├── scripts/
│   ├── bootstrap.sh         # check local toolchain + create venv
│   ├── build-push-agent.sh  # build ARM64 agent image + push to ECR
│   ├── deploy-agent.sh      # AgentCore configure/launch wrapper (verify commands)
│   └── run-asz-local.sh     # Tier-1: run asz on 127.0.0.1:8787 via docker
└── docs/
    └── SETUP.md             # full prerequisites + Tier-1 / Tier-2 walkthrough
```

---

## Quick start

### Tier 1 — local observability validation (zero AWS)

Proves the data path: LangGraph → langsmith → asz. No cloud, no Bedrock.

```bash
./scripts/bootstrap.sh            # venv + deps + toolchain check
./scripts/run-asz-local.sh        # asz on 127.0.0.1:8787
cp agent/.env.example agent/.env  # points langsmith at localhost asz
cd agent && python app.py --local # invoke the graph once
# open http://127.0.0.1:8787 → the conversation should be there
```

### Tier 2 — real AWS PoC

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in region, account, etc.
tofu init && tofu apply                         # ECS asz + ECR + ALB + EFS
../../scripts/build-push-agent.sh               # agent image → ECR
../../scripts/deploy-agent.sh                   # register on AgentCore Runtime
# invoke the deployed agent; the conversation lands in the remote asz UI
```

See [`docs/SETUP.md`](docs/SETUP.md) for the full prerequisite list and the
AgentCore egress / networking notes.

---

## Status / caveats

- The AgentCore starter-toolkit command surface (`agentcore configure` /
  `agentcore launch`) and the microVM→asz egress model are **unverified against
  live docs** here — the AgentCore docs are JS-rendered. `scripts/deploy-agent.sh`
  is a thin wrapper to finalize once the current commands are confirmed. The
  *shape* (SDK wraps handler → ARM64 image → ECR → Runtime) is stable.
- `terraform.tfvars`, state files, and `.env` are git-ignored — never commit real
  account values or endpoints.

## License

MIT © 吴晟 Wu Sheng
