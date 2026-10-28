# Collect Cloud Sessions, Evaluate Locally: Analyzing AI Agents on Amazon Bedrock AgentCore with Apache SkyWalking AI Sessionizer

Let's build a release assistant: ask it to change configuration, deploy an application, query the result, and explain what it completed. The agent runs on Amazon Bedrock AgentCore. Apache SkyWalking AI Sessionizer (`asz`) records its execution in the cloud. We pull those records onto a development machine, inspect them, and run a judge through a local CLI to check whether the agent met the requirements.

We will follow one example through five steps: **design the agent → deploy and collect → pull and inspect → run the judge → read results against the goals.**

## 1. What the agent should do

The agent's job is to release `demo-v1`. We give it tools for file access, configuration validation, building, deployment, and status queries. The model decides how to use them.

The model is a real Amazon Bedrock Nova Pro model, called by a LangGraph agent running in AgentCore Runtime. The business system is simulated: configuration, bundles, deployment state, and acceptance requests are stored as files. It does not operate a real production application.

We designed seven conversation turns covering normal work, revised requirements, denied permissions, and cancellation:

| Turn | What we ask the agent | What we will check |
| --- | --- | --- |
| 1 | Create staging configuration with two replicas and a 300-second timeout; validate it, but do not deploy | The file exists, validation passes, and no deployment occurs |
| 2 | Change the timeout to 600 seconds, keep two replicas, and validate again | Both the file and validation result show 600, beyond a reply saying it changed |
| 3 | Build, deploy to staging, then query and verify configuration | A query after deployment confirms the release, replica count, and timeout |
| 4 | Build and deploy production with the same parameters; explain successes and failures | Build and deployment are distinguished, and a permission denial is reported accurately |
| 5 | Submit acceptance, confirm approval status, and retain the request ID | Submission is distinguished from approval; an unconfirmed result remains unknown |
| 6 | Inspect configuration, propose scaling from two to four replicas, and wait for confirmation | Inspection precedes planning, and nothing changes without confirmation |
| 7 | Cancel autoscaling, keep two replicas, and summarize results | Autoscaling was not implemented; the summary accurately lists completed, failed, and unconfirmed work |

These requests are stored in [`scenarios/release.json`](https://github.com/wu-sheng/aws-agentcore-asz-demo/blob/poc/pull-judge/examples/pull-judge/scenarios/release.json) and sent as real user messages. The right-hand column is our checklist for reading the judge report later.

The simulator deliberately denies production deployment, and acceptance submission returns no approval conclusion. Correct behavior therefore includes **reporting limits accurately when work cannot be completed**. Whether deployment succeeded and whether the agent reported failure honestly are separate questions.

## 2. Deploy and collect

### Deploy the example

Prepare Git, Go 1.27+, uv, OpenSSL, AWS CLI, OpenTofu, and a running Docker engine. Your AWS account needs infrastructure deployment permissions and access to `us.amazon.nova-pro-v1:0` in `us-east-1`.

```sh
git clone --branch poc/pull-judge https://github.com/wu-sheng/aws-agentcore-asz-demo.git
cd aws-agentcore-asz-demo/examples/pull-judge
bash scripts/bootstrap.sh
export PATH="$PWD/.work/bin:$PATH"
```

`bootstrap.sh` installs the example dependencies and builds asz. This example has its own directory, preserving the code and deployment process from the [previous article](https://builder.aws.com/content/3KjX67DohBgEr8yPadw5MoDSV5C/agentcore-langgraph-agent).

If you are not signed in to AWS, run `aws login` first. Run the deployment commands below from `examples/pull-judge/`, replacing `YOUR_PUBLIC_IPV4` with your public egress IPv4 address. If you use a proxy, supply its egress address.

```sh
aws sts get-caller-identity
.venv/bin/python scripts/prepare-cloud.py --client-ip YOUR_PUBLIC_IPV4

AGENT_IMAGE=ghcr.io/wu-sheng/aws-agentcore-asz-pull-judge-agent:b3e872bfb9a26fbd8bfac6eab6073d241b79c904 \
  bash scripts/up.sh
```

This uses the image tested in this walkthrough. The script checks model access, copies the image into ECR, and creates the AgentCore Runtime, asz on Fargate, EFS, and networking. Infrastructure and model calls incur AWS charges. The deployment writes its resource manifest to `.work/cloud/resources.txt`.

### How collection is connected

```text
Agent in AgentCore
  ├─ Conversation, model calls, tool calls ──→ cloud asz
  └─ File changes ──→ shared EFS ──→ cloud asz
                                       │
                                  pull on demand
                                       ↓
                              Local viewing and judging
```

The example configures two collection paths:

- **Execution records:** LangGraph tracing sends user input, model responses, and tool calls to the asz receiver through `LANGSMITH_ENDPOINT`.
- **File changes:** The asz recording component watches `write_file`, `build_release`, `deploy`, and `submit_acceptance`, writing changes to shared EFS for asz to read.

This captures both what the agent said and what it changed. The agent calls Bedrock using its Runtime IAM role. Cloud asz collects the records; judging runs locally later.

Now send the seven requests from section 1:

```sh
.venv/bin/python scripts/cloud.py
```

The script invokes the agent turn by turn in one AgentCore session, waits for collection, and automatically pulls snapshots A, B, and C after turns 1, 5, and 7. It prints a `.work/cloud-TIMESTAMP` directory containing:

- `turn-*.json`: Each request and response.
- `checkpoints.json`: Conversation IDs and tags for the three snapshots.
- `client/asz.yaml`: The local configuration for the next step.

## 3. Pull the records and inspect them locally

Remote pull does one straightforward job: **copy a cloud conversation onto your machine**. Cloud collection continues, while your local copy preserves the version you pulled for viewing and evaluation.

### Connect to cloud asz

Enter the printed run directory, substituting your actual timestamp:

```sh
cd .work/cloud-TIMESTAMP/client
```

The script has already generated `asz.yaml`. Its remote connection section looks like this; the actual file has the address and paths filled in, so you do not need to copy this snippet:

```yaml
remotes:
  - name: demo
    url: https://YOUR_NLB_HOST:8788
    token_file: /path/to/demo.token
    ca_file: /path/to/demo-ca.pem
    server_name: asz-pull-judge.internal
```

`demo` names the remote service, and `token_file` supplies authentication. The last two settings verify the example's self-signed certificate. The deployment script also configures HTTPS and restricts the endpoint to your client IP. See the [remote pull configuration guide](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/remote-pull/).

List cloud conversations, then pull one:

```sh
asz pull -list -remote demo
asz pull demo/CONVERSATION_ID
```

Replace `CONVERSATION_ID` with an ID from the list. The pull output provides `SNAPSHOT_TAG`; `checkpoints.json` also contains tags already pulled by the script. Later, use `demo/CONVERSATION_ID:SNAPSHOT_TAG` to select that exact data. Pulling again with no new records returns `unchanged`.

### See what the agent actually did

```sh
asz view
```

Open the local address printed by the command and select the pulled conversation. Start with turn 2, where the user asked to change the timeout from 300 to 600. Find three things:

1. The user's change request.
2. The `write_file` change to `configs/staging.json`.
3. The configuration value returned by `validate_config`.

This is the file change pulled from our cloud run:

![Replaying a cloud configuration change in the local snapshot](assets/cloud-change.png)

The final validation read 600, confirming the update. However, the record also shows an earlier validation running alongside the write, reading the old value, and requiring a retry. **The final result can be correct while the execution still contains avoidable rework.** The judge helps organize these findings.

Viewing an existing snapshot does not require cloud asz to be online. Pull again when you need newer data.

## 4. Judge the goals from section 1

The judge needs to know what the user asked the agent to achieve. Here, the goals from section 1 are already written into the seven user messages and collected with the conversation. **The judge identifies targets from those messages, then checks whether tool results, file changes, and replies support completion.** We do not need a separate scoring file, and the judge does not automatically read this article's checklist.

For example, turn 3 explicitly asks for verification after deployment. Evaluation should therefore check whether a query confirmed the release, replica count, and timeout. A reply saying “deployed” alone does not establish that the whole request was fulfilled.

### Choose a local evaluation CLI

This example starts with Claude Code. Install it, sign in, and make sure your terminal can run `claude`. The generated configuration already includes the time and reading budgets used in this run. asz has a built-in `claude` evaluator, so you can run it directly.

To configure the CLI explicitly, merge this into the existing `judge` section of `asz.yaml`, retaining its other fields:

```yaml
judge:
  evaluators:
    claude:
      kind: cli
      program: claude
      args: []
```

This uses the CLI's default model. To select one, add `model` under `claude` with an identifier supported by that CLI. See the [judge documentation](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/judge/) for configuration details. The local CLI sends the conversation content it reads to its model service.

### Evaluate the complete conversation

Choose **snapshot C**, taken after turn 7, so the evaluation includes revised requirements and cancellation. From `client/`, run:

```sh
asz judge -evaluator claude \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

Substitute your conversation ID and C snapshot tag. This reads local data, creates a judge run, and prints a report when finished. It does not execute the release tools again.

List and read saved reports:

```sh
asz judge -list \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG

asz judge -show 1 \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

`1` is the run number; choose from the list if multiple reports exist. Add `-json` after `-show 1` for JSON output. Viewing a report does not call the model again.

If you use Codex locally, replace `-evaluator claude` with `-evaluator codex`. Judging the same snapshot again creates another run, preserving earlier results.

## 5. Read the results and assess the agent

Match reported targets to the requirements in section 1, inspect the evidence, and then read the overall scores. The following examples use Claude run 1 on our C snapshot. Another model run may produce different behavior and scores.

### Example 1: Configuration completed, with rework

This report excerpt shortens the target title:

```text
t1  A validated staging configuration ... 100/100
    outcome   achieved; standing t1.e3, t1.e4; 2 rounds of rework
    record    achieved: 5 of 5 criteria met, on observed result; closed
```

It answers two questions:

- **Did the agent finish?** `achieved`, with all five criteria met. The file change and validation confirm two replicas and a 600-second timeout.
- **Did execution go smoothly?** `2 rounds of rework`. A score of 100 means the target was achieved, not that the process was error-free or efficient.

For verification, follow the reasons and tool references under `why`, then inspect the corresponding records in `asz view`. `history` records changes in delivery; `standing` identifies deliveries still in effect. Here, the updated 600-second version is the relevant one.

### Example 2: Deployment success does not complete verification

The staging target includes:

```text
t2  The release bundle is built ... 0/100 (40 by the record)
    outcome   contradicted; standing t2.e1, t2.e2, t2.e3
    record    partly: 2 of 4 criteria met, on observed result; closed
```

`partly` means partial achievement. `contradicted` means recorded evidence contradicts the delivered conclusion. Turn 3 asked for verification after deployment, but the record shows:

1. `deploy` returned success and wrote simulated deployment state.
2. `get_deployment` ran alongside deployment and read `not_deployed`.
3. The agent never queried again to confirm the result.

We can establish that the deployment tool executed, but not that the requested verification was completed. The report retains a record score of 40 for partial work and gives a final score of zero because the delivered conclusion was contradicted. This does not mean nothing happened.

Read `did` for work performed, `gap` for missing conditions, and `claims` for whether the agent's statements have supporting evidence. These sections tell us more about what to fix than a zero alone.

### Check the remaining results against the original design

| Requirement from section 1 | Recorded behavior and judge result | Our assessment |
| --- | --- | --- |
| Build and deploy production, explaining failures | Build succeeded, deployment was denied; judge labeled the target `achieved` after defining its criterion as attempting deployment | Deployment was not achieved. Reporting failure is correct behavior, but an attempt is not deployment success |
| Submit acceptance and confirm approval status | Request ID saved, `approved: null`; judge labeled reporting the status as `achieved` | Submission completed; approval remains unknown |
| Inspect, plan, wait for confirmation, then cancel | No autoscaling implementation; target `cancelled` and unscored; no fresh inspection before proposing the plan | Cancellation caused no unintended change, but inspection before planning needs improvement |
| Accurately summarize completed, failed, and unconfirmed work | Summary partly achieved; it omitted the unresolved staging query | The summary should include that unconfirmed state |

This is why we start with design goals. The judge interprets the user's requirements, and that interpretation needs review. When you see `achieved`, ask which conditions it considers met. If those conditions were weakened, return to the user messages and tool results.

### Understand scores and report status

This report contains four measures:

| Measure | This run | Plain-language meaning |
| --- | ---: | --- |
| `achievement` | 83/100 | Target completion by the record; cancelled targets are excluded |
| `final` | 75/100 | Completion after accounting for issues such as contradicted delivery conclusions |
| `efficiency` | 79/100 | With tokens as the unit, about 21% of reviewed cost was classified as avoidable |
| `delivered` | 66% | About 66% of target cost went to targets judged achieved |

Explain targets before scores. Here, `final` is lower than `achievement` mainly because staging's delivered conclusion was contradicted. `efficiency` helps examine rework cost. These percentages measure different things; none is a general model accuracy score. See the [scoring rules](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/concepts-and-designs/conversation-judge/).

Also read the stage status at the top. This report was `partial`: two judgments relying only on the agent's words were weakened, and efficiency analysis left an item unlabeled. This means **the evaluation itself has incomplete parts**. It differs from a target being `partly` achieved. Retain these qualifications instead of treating the report as an undisputed verdict.

Cost has two parts too: `conversation` is the original agent's model usage, while `judging` is evaluation usage. This run recorded approximately 48.5k and 263.8k tokens respectively. `unpriced` means pricing information is incomplete, not that cost is zero.

### Decide what to change

The clearest improvement is to sequence dependent tools: **write configuration → validate → build → deploy → query and confirm**. Also require the final summary to distinguish completed, denied, and still-unconfirmed work.

After making changes, run the same seven requests, pull a new snapshot, and judge again. Keep using the checklist from section 1: was verification completed, did rework decrease, and is the summary accurate?

When finished, preserve the snapshots and reports you need, then return to `examples/pull-judge/` to clean up:

```sh
bash scripts/down.sh --yes
bash scripts/down.sh check
```

Snapshots have retention limits. Exclude tokens and TLS private keys from archives. If network cleanup is waiting for AgentCore to release interfaces, follow the `check` output. The [example README](https://github.com/wu-sheng/aws-agentcore-asz-demo/tree/poc/pull-judge/examples/pull-judge) has detailed cleanup instructions.

Find the code in the [example repository](https://github.com/wu-sheng/aws-agentcore-asz-demo/tree/poc/pull-judge/examples/pull-judge) and additional results in the [experiment record](CLOUD-RESULTS.md). Full usage instructions are in the [Apache SkyWalking AI Sessionizer documentation](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/readme/).
