---
name: tier1-local
description: Run the demo locally with no AWS - asz in Docker, the LangGraph agent in a venv - and check the conversation landed. Use to validate agent, receiver or asz-image changes before touching AWS, or to try a Bedrock model from the laptop.
---

# Tier 1: local, no AWS

1. Toolchain and venv (once): `./scripts/bootstrap.sh`. Needs python3 and Docker; it reports the rest.
2. Start asz at the pinned commit image: `./scripts/run-asz-local.sh`.
   UI `http://127.0.0.1:8787`, receiver `127.0.0.1:1985`, data in the Docker volume `asz-local-data`
   (it survives restarts; `docker volume rm asz-local-data` wipes it). It re-creates the
   `asz-local` container, so other conversations in the volume stay.
3. Play the demo on a fresh thread id (pick a new one each run, it becomes the conversation):
   ```bash
   cd agent && set -a && . ./.env.example && set +a
   .venv/bin/python app.py --local --demo --thread-id <thread-id>
   ```
   No `BEDROCK_MODEL_ID` = the scripted stand-in model (deterministic, free). To use a real model,
   also export `BEDROCK_MODEL_ID=us.anthropic.claude-opus-4-7` and `AWS_REGION=us-east-1`; boto3
   uses the user's AWS credentials (or a Bedrock API key in `AWS_BEARER_TOKEN_BEDROCK`). Anthropic
   models need the account's Anthropic use-case form first.
4. Check, within ~10 s (the local collector interval):
   ```bash
   curl -s http://127.0.0.1:8787/api/conversations | python3 -m json.tool | grep '"id"'
   docker exec asz-local /usr/local/bin/asz verify
   ```
   Expect `ls-aws-agentcore-asz-demo-<thread-id>-<digest>` with 4 talks and 8 model calls
   (stand-in model; a real model may make a different number of calls).
5. Screenshots or a closer look: the `verify-run` skill's `shoot.cjs` works against
   `http://127.0.0.1:8787` too.

The agent image can also be checked without AgentCore: build it (`docker buildx build --platform
linux/arm64 -t asz-demo-agent:test --load agent`) and POST to its `/invocations` on 8080 with an
`X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header; the header's value becomes the thread.

Stop: `docker rm -f asz-local`.
