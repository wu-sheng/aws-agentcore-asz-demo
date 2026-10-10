---
name: verify-run
description: Verify a deployed Tier-2 environment end to end and capture evidence - the four-turn demo on one AgentCore session, the turn after the session went idle, token counts, and readable screenshots of the asz replay page. Use after tier2-up, for a PR's "Tested" section or for the blog post's figures.
---

# Verify a Tier-2 run

Needs the environment up (`tier2-up` skill). Work from the repository root. Keep everything in a
dated directory: `RUN=.deploy/runs/$(date -u +%Y%m%dT%H%MZ); mkdir -p $RUN`.

```bash
UI=$(tofu -chdir=infra/terraform output -raw asz_ui_url)
```

## 1. The demo conversation

```bash
./scripts/invoke.sh | tee $RUN/invoke.log
```
Every turn must print an `agent>` answer. A 500 on every turn means model access (see `tier2-up`).
Keep the session id from the last lines (`session/thread: advisor-...`): `SESSION=...`.

Within ~30 s (the Tier-2 collector interval):
```bash
curl -s "$UI/api/conversations" | python3 -m json.tool | grep -E '"id"|"talks"|"llm_calls"'
```
Expect one `ls-aws-agentcore-asz-demo-advisor-...` conversation with 4 talks. Its name holds only a
shortened session id; match it by the session's timestamp prefix and keep the full id: `CONV=ls-...`.

## 2. The turn after the session went idle

AgentCore stops the session's microVM after `agent_idle_session_timeout` (default 900 s) without a
call. Any call resets the clock, so do not invoke on this session while waiting. After at least
16 minutes:

```bash
SESSION=$SESSION ./scripts/invoke.sh "Before we finish: what was the first thing I asked you, and what did you answer?" | tee $RUN/invoke-idle.log
```
Expected: the agent says it has no record of earlier questions, because the new microVM's
`InMemorySaver` is empty. asz files the call under the same conversation (5 talks), and that
talk's model call is sent only the system prompt and the new question. A turn sent sooner, on the
same session, would instead see the whole history: run both if the comparison is needed.

## 3. Screenshots and the API documents

```bash
# once: Playwright in the git-ignored .deploy/pw
[ -d .deploy/pw/node_modules/playwright ] || npm install --prefix .deploy/pw playwright
NODE_PATH=.deploy/pw/node_modules PW_EXE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  node .claude/skills/verify-run/shoot.cjs "$UI" "$CONV" $RUN/shots --prompt-talk 2 --idle-talk 5
```
Without `PW_EXE`, run `npx --prefix .deploy/pw playwright install chromium` first. The UI is
reachable only from `asz_ui_cidrs`.

Output (1280 px viewport, 2x scale, so UI text stays readable in an ~800 px blog column):
`list.png`, `conversation.png` (every talk), `turn.png` (talk 2 expanded: model calls and tool
steps with input and result), `prompt.png` (Prompt tab of talk 2's last model call, popped out,
all messages open), `idle-prompt.png` (talk 5's first model call), and `api/*.json`.

Check by reading the images, not just their existence:
- `prompt.png` lists, in order: SYSTEM, the first HUMAN question, its tool use and result, the
  first answer, the second HUMAN question, its tool calls and results. The first turn ran in a
  different invocation; seeing it proves the session carried the history.
- `idle-prompt.png` lists SYSTEM and one HUMAN message only.

Token counts and model calls from the saved view document:
```bash
python3 - "$RUN"/shots/api/*_view.json <<'PY'
import json, sys
doc = json.load(open(sys.argv[-1]))
def walk(n):
    if isinstance(n, dict):
        if n.get("kind") == "llm.call":
            yield n.get("at"), n.get("usage"), n.get("id")
        for v in n.values(): yield from walk(v)
    elif isinstance(n, list):
        for v in n: yield from walk(v)
for at, usage, cid in sorted(walk(doc), key=lambda x: x[0] or 0):
    print(at, usage, cid)
PY
```

## 4. Logs

```bash
aws logs tail "$(tofu -chdir=infra/terraform output -raw asz_log_group)" --since 2h > $RUN/asz-task.log
cp .deploy/up.log $RUN/ 2>/dev/null || true
```
The agent's logs are under `/aws/bedrock-agentcore/runtimes/<agent_runtime_id>-*`.

## 5. Finish

Report what was checked and what was not. Then tear down with the `tier2-down` skill: the
environment bills while it is up.

## Maintaining shoot.cjs

It drives asz's conversation page by these selectors, checked against asz `8104ada`:
`.acv-transcript`, `.acv-inspector`, `.acv-tab` ("Prompt"), `.acv-pop-btn` (pop the inspector
out), `.acv-title.acv-kind-model` (model-call steps), `.acv-card.acv-human` / `.acv-card.acv-agent`,
`.acv-fold` and the text "show what the agent did". After an asz bump, run it against Tier 1
(`http://127.0.0.1:8787`) and read the images before relying on it.
