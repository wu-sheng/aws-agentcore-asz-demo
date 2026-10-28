# Pull and judge a release assistant

Work in progress. The real Bedrock conversation, collection, HTTPS pull and local CLI
judge have been exercised locally. AgentCore cloud deployment is still pending.

The agent uses a real Bedrock model through LangGraph. Its business environment is a
disclosed simulator: configuration files, release bundles, deployments and acceptance
requests are persisted in a conversation's workspace. Production deployment permission
is denied; acceptance result lookup is unavailable. The model decides its own tool calls
and responses. There is no scripted model fallback and no predetermined judge output.

This directory has separate configuration and artifacts. The original `agent/`,
`config/`, `infra/terraform/` and `scripts/` at the repository root are unchanged.

## Prepare locally

Prerequisites: Git, Go 1.27+, uv, OpenSSL, AWS CLI and valid AWS credentials for the
real-model run. Python 3.12 is installed/selected by uv. Claude Code must be installed
and signed in for the proposed local CLI evaluation.

From this directory:

```sh
bash scripts/bootstrap.sh
```

This pins asz and its recorder to `341f8c0c9cb8245669cbe45ff5393f6972e05616`, installs
the agent dependencies into `.venv`, runs the business-tool tests and starts a temporary
local asz service to verify TLS, wrong-token rejection and authenticated pull listing.
It makes no Bedrock calls and creates no cloud resources.

Ports 18788 (HTTPS), 11985 (ingestion), and for the model run 8080 (agent) must be free.
The script stops only its own processes. Configuration, keys and evidence are kept in
the ignored `.work/` directory. Never commit that directory or copy its keys into screenshots.

## Run the real model locally

After checking AWS credentials and model access:

```sh
AWS_REGION=us-east-1 BEDROCK_MODEL_ID=us.amazon.nova-pro-v1:0 \
  .venv/bin/python scripts/local.py --run
```

For local model calls, an existing `AWS_BEDROCKS_API` variable is accepted as an alias
for the AWS SDK's `AWS_BEARER_TOKEN_BEDROCK`. Its value stays in the process environment;
do not put it in configuration files or command-line arguments. AgentCore deployment
still requires AWS management credentials, and the deployed agent uses its runtime role.

This path was verified locally on October 28, 2026. It sends the seven turns in
`scenarios/release.json` to the local AgentCore HTTP entrypoint, backed by the real Bedrock
model. It records file changes and pulls snapshots after turns 1, 5 and 7. A final pull checks
reuse of the unchanged head. All processes it starts are stopped at the end; snapshots remain.

The runner prints an evidence directory. Inside it, `client/asz.yaml` is the local pull/judge
configuration and `checkpoints.json` records the snapshot tags. From `client/`, use the
absolute path to this example's `.work/bin/asz`:

```sh
/absolute/path/to/examples/pull-judge/.work/bin/asz judge \
  -evaluator claude -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

Replace the placeholders with the values recorded by the pull. The local collector is
already stopped at this point; judging an existing snapshot does not need it. The CLI's
model service must still be reachable. This is not an offline model evaluation.

## Evidence and limitations

- A bundle can be built while its production deployment is denied. Target grouping is
  the evaluator's decision, so this may be `partly` or separate achieved/failed targets.
- Submission does not mean approval. The simulated acceptance result stays unknown.
- User-requested revisions are not automatically avoidable agent work.
- An autoscaling plan and cancelled implementation can be different targets.
- Unknown usage/prices must not be replaced with invented counts or fees.
- The runner waits for tracing flush and stable collected summaries including file changes.
  Before publication, inspect the actual final replies and tool results in each snapshot too.
- Preserve an evidence copy before snapshot TTL removes local runs.

See [the experiment plan](../../docs/blog/pull-judge/POC.md) and the
[Chinese](../../docs/blog/pull-judge/zh-CN.md) / [English](../../docs/blog/pull-judge/en.md) drafts.

## Current verification

On 2026-10-28, five business-state tests, missing-model rejection and the HTTPS/authenticated
pull preflight passed. The seven-turn Nova Pro run produced 18 model calls and three pulled
snapshots; pulling the final head again returned unchanged. Local Claude Code judge runs
produced reports, including a partial report whose invalid evidence observation was rejected.
See [the local experiment record](../../docs/blog/pull-judge/LOCAL-RESULTS.md) for actual
findings and limitations. AWS management login is still needed for AgentCore deployment.
The original tracked blog and demo files remain unchanged.

## Independent cloud experiment

The `poc/pull-judge` branch's `pull-judge-image` GitHub Actions workflow publishes an
ARM64 image to a separate package with a commit tag. Never build and push this image locally.
With AWS management credentials restored and an accessible real Bedrock model:

```sh
.venv/bin/python scripts/prepare-cloud.py --client-ip YOUR_PUBLIC_IPV4
AGENT_IMAGE=ghcr.io/wu-sheng/aws-agentcore-asz-pull-judge-agent:COMMIT bash scripts/up.sh
.venv/bin/python scripts/cloud.py
.venv/bin/python scripts/judge.py .work/cloud-TIMESTAMP
```

The cloud runner prints the evidence directory and retains the session ID, all responses,
three snapshots, and pull durations. The judge runner copies the local configuration with
an unreachable remote address, checks that pulling fails, then judges the existing snapshots.
It keeps the evaluator's model-service connection available. Inspect each report's state:
a finished CLI process is not a guarantee that every judgment stage is complete.

Use `scripts/metrics.py --start UTC_TIMESTAMP --output EVIDENCE/metrics.json` to export
one-minute ECS metrics. Wait for CloudWatch ingestion before the final export; empty samples
are missing data, not zero. Match the metric timestamps to the saved invocation/pull/judge windows.

After copying evidence outside the cloud service, run `bash scripts/down.sh --yes` and
`bash scripts/down.sh check`. AWS-managed AgentCore network interfaces may delay final
network cleanup. Also remove the experiment's Container Insights performance log group
(`/aws/ecs/containerinsights/asz-pull-judge-cluster/performance`) after exporting needed metrics.
