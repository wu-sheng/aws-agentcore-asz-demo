---
name: tier2-down
description: Tear the demo's AWS environment down with scripts/down.sh and report what is left; finish a teardown that AgentCore's network interfaces held up. Use after a Tier-2 run, or to check whether anything of the demo is still in the account.
---

# Tier 2: tear down

`down.sh` deletes everything in OpenTofu state - including EFS (the stored conversations) and the
ECR images - plus the runtime's log groups. Save any evidence first (`verify-run` skill).

```bash
./scripts/down.sh check                       # read-only status, any time
./scripts/down.sh --yes > .deploy/down-run.log 2>&1; echo "exit=$?" >> .deploy/down-run.log
```
Run the destroy in the background: it waits up to `--wait` seconds (default 600) and tofu's own
output goes to `.deploy/down.log`.

Exit codes: **0** finished (manifest removed), **3** still in progress, **1** error or aborted.

Exit 3 is normal. AWS keeps AgentCore's `agentic_ai` network interfaces in the agent's subnets
for up to 8 hours after the runtime is deleted (about 10 in our run); nobody can delete them.
Until they go, the VPC, its private subnets and the agent security group stay. The report marks
each leftover `no cost` or `BILLABLE`; after the first pass only free network pieces should
remain. Tell the user, and finish later:

```bash
./scripts/down.sh check        # says when nothing blocks the rest any more
./scripts/down.sh --yes        # finishes; safe to re-run
```

- `.deploy/resources.txt` is kept until the teardown finishes, so `check` can tell removed from
  in progress. Do not delete it by hand.
- `AWSServiceRoleForBedrockAgentCoreNetwork` is left on purpose (account-wide, shared, free).
- The tagging index lags deletions (ECS keeps INACTIVE records); it is a note, not a leftover.
