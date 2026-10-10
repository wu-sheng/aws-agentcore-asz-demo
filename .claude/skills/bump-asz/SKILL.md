---
name: bump-asz
description: Move the demo to a newer Apache SkyWalking AI Sessionizer (asz) build by its upstream main commit id. Use when an asz fix or feature the demo needs has merged to apache/skywalking-ai-sessionizer main.
---

# Bump the asz image

asz is pinned by the full commit id of `apache/skywalking-ai-sessionizer` `main`; CI publishes
`ghcr.io/apache/skywalking-ai-sessionizer:<commit-id>` for every main commit. `:latest` is the
last release and lags main.

1. Pick the commit and confirm its image exists:
   ```bash
   git -C ~/github/skywalking-ai-sessionizer fetch -q origin
   git -C ~/github/skywalking-ai-sessionizer log --oneline -5 origin/main
   docker manifest inspect ghcr.io/apache/skywalking-ai-sessionizer:<full-commit-id> >/dev/null && echo ok
   ```
   The UI renderer comes from Horizon at the commit in
   `internal/view/conversation-view/HORIZON_COMMIT` of that asz commit.
2. Set the full id in every place, which must agree: `scripts/run-asz-local.sh` (`ASZ_IMAGE`
   default), `infra/terraform/variables.tf` (`asz_image` default), and `agent/Dockerfile`
   (`ARG ASZ_COMMIT` default). `up.sh` and `run-agent-local.sh` pass the pinned commit as the
   build arg, so the image's `asz-changes` and LangChain shim always match the asz image.
3. Update the README's status line that names the pinned commit and why.
4. Check with the `tier1-local` skill: restart asz on the new image against the existing volume,
   run `./scripts/run-agent-local.sh` (it rebuilds the agent image at the new commit), check the
   conversation and its file change landed, and `docker exec asz-local /usr/local/bin/asz verify`.
5. PR: summary names the asz PR(s) the bump brings in; "Tested" lists the Tier-1 run;
   "Not tested" says Tier 2 was not re-applied, unless it was.
