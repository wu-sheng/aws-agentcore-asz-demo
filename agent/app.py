"""A LangGraph tool-calling agent packaged for Amazon Bedrock AgentCore Runtime.

The agent is a small "deployment advisor": it answers questions about running a
LangGraph agent on AgentCore with asz observability, calling tools to look up
the facts, check the deployment and estimate cost. The demo conversation
(``--demo``) is the one a developer actually has while setting this up.

Run modes:
  * ``python app.py --local --demo``  -> play the multi-turn demo conversation
    on one thread (Tier-1 local validation; no AgentCore, no AWS).
  * ``python app.py --local -q "..."`` -> ask one question.
  * ``python -m app`` (no flag)       -> serve the ``/invocations`` + ``/ping``
    contract AgentCore expects. This is the container's command.

Observability is NOT in this file by design. The ``langsmith`` tracing client is
bundled with ``langchain-core`` and is configured purely by environment variables
(see ``.env.example``). Point those at asz's ``langsmith-ingest`` receiver and
every graph run lands in asz.

The one thing the LangSmith wire cannot infer is the conversation identity, so
we supply it as ``thread_id`` in run metadata: the CLI's ``--thread-id``, or the
AgentCore runtime session id when served.

Model: a real Bedrock model when ``BEDROCK_MODEL_ID`` is set, otherwise a
scripted stand-in model that makes the same tool calls, so Tier-1 needs no
credential and still produces a realistic trace (tool calls, tool results,
multi-turn history).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, ToolMessage
from langchain_core.outputs import ChatGeneration, ChatResult
from langchain_core.tools import tool
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import START, MessagesState, StateGraph
from langgraph.prebuilt import ToolNode, tools_condition

SYSTEM_PROMPT = (
    "You are a deployment advisor for running LangGraph agents on Amazon Bedrock "
    "AgentCore Runtime with Apache SkyWalking AI Sessionizer (asz) observability. "
    "Use the tools to look facts up instead of guessing, and answer briefly. "
    "You can clone the demo repository and read and write its files."
)

# --------------------------------------------------------------------------- #
# Tools                                                                       #
# --------------------------------------------------------------------------- #
# What the advisor knows, distilled from setting this demo up for real.
_KNOWLEDGE = {
    "sidecar": (
        "AgentCore Runtime runs one container image per agent in a per-session "
        "microVM. There is no sidecar slot. asz is a persistent service with "
        "durable storage and a UI, so it runs as its own long-lived container "
        "(ECS/Fargate here) and the agent reaches it over the network."
    ),
    "ingest_port": (
        "asz serves its UI on 8787. The LangSmith receiver is a separate adapter, "
        "langsmith-ingest, off by default, listening on 1985. Enable it in asz.yaml "
        "and point LANGSMITH_ENDPOINT at :1985, not :8787."
    ),
    "env_vars": (
        "Four variables: LANGSMITH_TRACING=true, LANGSMITH_ENDPOINT=<asz ingest>, "
        "LANGSMITH_API_KEY=<the receiver token, any value if none>, "
        "LANGSMITH_PROJECT=<name>. The thread id goes in run metadata."
    ),
    "otlp": (
        "OTLP is asz's export plane: it ships already-landed files to SkyWalking "
        "OAP/BanyanDB. It is not a data source. Full replay needs the LangSmith "
        "wire plus what the wire cannot carry: the supplied thread identity and "
        "the plugin's record of which tool changed which files."
    ),
    "networking": (
        "Run the AgentCore agent in VPC mode in the private subnets. It reaches "
        "asz's ingest through an internal ALB on 1985, allowed only from the "
        "agent's security group, and Bedrock/ECR through the NAT gateway."
    ),
    "teardown": (
        "Every AWS resource is in OpenTofu state, including the AgentCore runtime. "
        "scripts/down.sh destroys it all and deletes the log groups AgentCore creates "
        "at runtime. AWS keeps AgentCore's network interfaces for up to 8 hours after "
        "the runtime is gone, so the VPC, its subnets and a security group, all free, "
        "can outlast the first run: scripts/down.sh check reports, and "
        "scripts/down.sh --yes later finishes."
    ),
    "file_changes": (
        "asz-changes, attached by the apache-skywalking-asz-langchain shim, scans the "
        "workspace before and after each tool its settings name (write_file here) and "
        "records what changed. asz's changes adapter files that beside the tool call, "
        "in the same conversation, so the change outlives the microVM it was made in."
    ),
    "image": (
        "The asz image is ghcr.io/apache/skywalking-ai-sessionizer (multi-arch, "
        "distroless, non-root uid 65532). The agent image must be linux/arm64 in ECR."
    ),
}


@tool
def search_docs(topic: str) -> str:
    """Look up a deployment fact. Topics: sidecar, ingest_port, env_vars, otlp,
    networking, teardown, image, file_changes."""
    key = topic.strip().lower().replace(" ", "_").replace("-", "_")
    if key in _KNOWLEDGE:
        return _KNOWLEDGE[key]
    hits = [v for k, v in _KNOWLEDGE.items() if k in key or key in k]
    return hits[0] if hits else f"No entry for {topic!r}. Known: {', '.join(_KNOWLEDGE)}."


@tool
def check_deployment(component: str) -> str:
    """Report how this running agent is wired to a component: 'tracing' or 'model'."""
    if component.strip().lower() == "model":
        model = os.getenv("BEDROCK_MODEL_ID")
        return f"model: {model} via Bedrock" if model else "model: scripted stand-in (no credential)"
    endpoint = os.getenv("LANGSMITH_ENDPOINT") or os.getenv("LANGCHAIN_ENDPOINT") or "(unset)"
    tracing = os.getenv("LANGSMITH_TRACING") or os.getenv("LANGCHAIN_TRACING_V2") or "false"
    project = os.getenv("LANGSMITH_PROJECT") or os.getenv("LANGCHAIN_PROJECT") or "default"
    port_note = " -- WARNING: 8787 is asz's UI, the receiver is :1985" if endpoint.endswith(":8787") else ""
    return f"tracing={tracing} endpoint={endpoint} project={project}{port_note}"


# Rough us-east-1 on-demand prices (USD/hour), for an order-of-magnitude answer.
_HOURLY = {
    "nat_gateway": 0.045,
    "alb_x2": 2 * 0.0225,
    "fargate_asz_arm64_0.5vcpu_1gb": 0.5 * 0.03238 + 1 * 0.00356,
    "public_ipv4_x3": 3 * 0.005,  # the NAT's EIP and the public ALB in two AZs
}


@tool
def estimate_cost(hours: float) -> str:
    """Estimate the PoC's fixed AWS cost for running it the given number of hours."""
    lines = [f"{k}: ${v * hours:.2f}" for k, v in _HOURLY.items()]
    total = sum(_HOURLY.values()) * hours
    return (
        f"{hours:g}h -> about ${total:.2f} fixed ({'; '.join(lines)}). AgentCore bills "
        "for the CPU and memory its sessions use, and Bedrock per token, on top; "
        "ALB, NAT data, EFS and logs are cents at demo volume."
    )


# --------------------------------------------------------------------------- #
# The workspace: a clone of this demo, which the agent may change             #
# --------------------------------------------------------------------------- #
# On AgentCore the workspace is on the microVM's own disk, so it goes when the
# session's microVM is stopped. asz-changes (see the Dockerfile) watches it: it
# scans before and after write_file and records the difference beside the call.
REPO_URL = os.getenv("DEMO_REPO_URL", "https://github.com/wu-sheng/aws-agentcore-asz-demo")
WORKSPACE = Path(os.getenv("DEMO_WORKSPACE") or Path.home() / "workspace")
REPO_DIR = WORKSPACE / "aws-agentcore-asz-demo"
_NOT_CLONED = "The repository is not cloned in this workspace; call clone_demo_repo first."


def _in_repo(path: str) -> Path:
    """The file a repository path names, refusing anything outside the clone."""
    root = REPO_DIR.resolve()
    target = (root / path).resolve()
    if target != root and root not in target.parents:
        raise ValueError("outside the repository")
    return target


@tool
def clone_demo_repo() -> str:
    """Clone the demo repository, wu-sheng/aws-agentcore-asz-demo, into the
    workspace unless it is already there, and list its top-level entries."""
    if not (REPO_DIR / ".git").is_dir():
        WORKSPACE.mkdir(parents=True, exist_ok=True)
        done = subprocess.run(
            ["git", "clone", "--depth", "1", "--quiet", REPO_URL, str(REPO_DIR)],
            capture_output=True, text=True, timeout=120,
        )
        if done.returncode != 0:
            return f"git clone failed: {done.stderr.strip()[-300:]}"
    entries = sorted(e.name + ("/" if e.is_dir() else "") for e in REPO_DIR.iterdir() if e.name != ".git")
    return f"{REPO_URL} is cloned at {REPO_DIR}: {', '.join(entries)}"


@tool
def read_file(path: str) -> str:
    """Read a file of the cloned demo repository, by its path in the repository,
    e.g. infra/terraform/terraform.tfvars.example."""
    if not REPO_DIR.is_dir():
        return _NOT_CLONED
    try:
        return _in_repo(path).read_text()[:20000]
    except (OSError, ValueError) as e:
        return f"cannot read {path!r}: {e}"


@tool
def write_file(path: str, content: str) -> str:
    """Write a file of the cloned demo repository, by its path in the repository,
    creating it or replacing its whole content."""
    if not REPO_DIR.is_dir():
        return _NOT_CLONED
    try:
        target = _in_repo(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return f"wrote {path} ({len(content.encode())} bytes)"
    except (OSError, ValueError) as e:
        return f"cannot write {path!r}: {e}"


TOOLS = [search_docs, check_deployment, estimate_cost, clone_demo_repo, read_file, write_file]


# --------------------------------------------------------------------------- #
# Model                                                                       #
# --------------------------------------------------------------------------- #
# The scripted stand-in's plays: (whole words in the question, rounds of tool
# calls). Each round is sent after the results of the one before; the first
# entry with a matching word wins. _FROM_RESULT stands for an argument the
# stand-in derives from the last tool result, as a real model would.
_FROM_RESULT = object()

_SCRIPT: list[tuple[tuple[str, ...], list[list[tuple[str, dict[str, Any]]]]]] = [
    (("clone", "tfvars"), [
        [("clone_demo_repo", {})],
        [("read_file", {"path": "infra/terraform/terraform.tfvars.example"})],
        [("write_file", {"path": "infra/terraform/terraform.tfvars", "content": _FROM_RESULT})],
    ]),
    (("sidecar",), [[("search_docs", {"topic": "sidecar"})]]),
    (("otlp", "replay"), [[("search_docs", {"topic": "otlp"})]]),
    (("port", "landed", "8787"), [[
        ("check_deployment", {"component": "tracing"}),
        ("search_docs", {"topic": "ingest_port"}),
    ]]),
    (("cost", "tear", "destroy"), [[
        ("estimate_cost", {"hours": 4}),
        ("search_docs", {"topic": "teardown"}),
    ]]),
    (("network", "reach", "vpc"), [[("search_docs", {"topic": "networking"})]]),
]


def _tfvars_from(example: str) -> str:
    """What the stand-in writes for the tfvars turn: the example with the
    question's IP and a five-minute idle timeout."""
    out = re.sub(r"(?m)^asz_ui_cidrs\s*=.*$", 'asz_ui_cidrs = ["198.51.100.24/32"]', example)
    return out.rstrip("\n") + "\n\n# Stop a session's microVM after 5 idle minutes.\nagent_idle_session_timeout = 300\n"


class ScriptedAdvisor(BaseChatModel):
    """Credential-free stand-in: calls the tools a real model would, round by
    round, then answers from what the last round returned. Deterministic, so
    the demo trace is reproducible."""

    @property
    def _llm_type(self) -> str:
        return "scripted-advisor"

    def bind_tools(self, tools: Any, **kwargs: Any) -> "ScriptedAdvisor":
        return self

    def _generate(self, messages: list[BaseMessage], stop: Any = None, run_manager: Any = None, **kwargs: Any) -> ChatResult:
        # This turn: its question and everything after it.
        turn: list[BaseMessage] = []
        question = ""
        for m in reversed(messages):
            if isinstance(m, HumanMessage):
                question = str(m.content)
                break
            turn.insert(0, m)
        words = set(re.findall(r"[a-z0-9]+", question.lower()))
        rounds = next((r for keys, r in _SCRIPT if words & set(keys)), [])
        done = sum(1 for m in turn if isinstance(m, AIMessage) and m.tool_calls)
        last: list[str] = []  # the results of the latest round of tool calls
        for m in reversed(turn):
            if isinstance(m, AIMessage):
                break
            if isinstance(m, ToolMessage):
                last.insert(0, str(m.content))
        if done < len(rounds):
            calls = []
            for name, args in rounds[done]:
                args = {k: (_tfvars_from(last[-1] if last else "") if v is _FROM_RESULT else v) for k, v in args.items()}
                calls.append({"name": name, "args": args, "id": f"call_{uuid.uuid4().hex[:12]}", "type": "tool_call"})
            msg = AIMessage(content="", tool_calls=calls)
        elif rounds:
            msg = AIMessage(content=" ".join(last))
        else:
            msg = AIMessage(content="I can help with sidecars, ports, OTLP vs replay, networking, cost, teardown, "
                                    "and preparing the demo repository's files.")
        return ChatResult(generations=[ChatGeneration(message=msg)])


def _model() -> BaseChatModel:
    model_id = os.getenv("BEDROCK_MODEL_ID")
    if not model_id:
        return ScriptedAdvisor()
    # Bedrock API keys: boto3 reads them from AWS_BEARER_TOKEN_BEDROCK.
    # Accept AWS_BEDROCKS_API as an alias so an existing key works as-is.
    # On AgentCore neither is set and the runtime's IAM role is used.
    if not os.getenv("AWS_BEARER_TOKEN_BEDROCK") and os.getenv("AWS_BEDROCKS_API"):
        os.environ["AWS_BEARER_TOKEN_BEDROCK"] = os.environ["AWS_BEDROCKS_API"]
    from langchain_aws import ChatBedrockConverse

    return ChatBedrockConverse(model=model_id, region_name=os.getenv("AWS_REGION", "us-east-1"))


# --------------------------------------------------------------------------- #
# The graph                                                                   #
# --------------------------------------------------------------------------- #
def build_graph():
    llm = _model().bind_tools(TOOLS)

    def advisor(state: MessagesState) -> dict:
        from langchain_core.messages import SystemMessage

        return {"messages": [llm.invoke([SystemMessage(SYSTEM_PROMPT), *state["messages"]])]}

    graph = StateGraph(MessagesState)
    graph.add_node("advisor", advisor)
    graph.add_node("tools", ToolNode(TOOLS))
    graph.add_edge(START, "advisor")
    graph.add_conditional_edges("advisor", tools_condition)
    graph.add_edge("tools", "advisor")
    # In-process memory: one AgentCore session keeps its microVM, so a thread's
    # history survives across that session's invocations.
    return graph.compile(checkpointer=InMemorySaver())


GRAPH = build_graph()


def ask(question: str, thread_id: str) -> str:
    """One turn on a conversation. asz never infers the conversation identity,
    so the thread key is supplied both as LangGraph's checkpoint thread and as
    run metadata."""
    result = GRAPH.invoke(
        {"messages": [HumanMessage(question)]},
        config={
            "configurable": {"thread_id": thread_id},
            "metadata": {"thread_id": thread_id},
            "run_name": "deployment-advisor",
        },
    )
    content = result["messages"][-1].content
    if isinstance(content, list):  # Bedrock Converse returns content blocks
        content = "".join(b.get("text", "") for b in content if isinstance(b, dict))
    return str(content)


# The conversation a developer has while setting this demo up.
DEMO_TURNS = [
    "I'm deploying a LangGraph agent on Bedrock AgentCore Runtime. Can I run asz as a sidecar next to it?",
    "OK, separate service then. I pointed the LangSmith client at asz on 8787 and nothing landed. Which port should it be?",
    "Is asz's OTLP export enough for full replay, or do I still need the LangSmith wire?",
    "How much will the PoC cost if I leave it up for 4 hours, and how do I tear everything down afterwards?",
    "Clone the demo repo and prepare infra/terraform/terraform.tfvars from the example for me: "
    "my IP is 198.51.100.24, and stop idle sessions after 5 minutes.",
]


# --------------------------------------------------------------------------- #
# AgentCore Runtime entrypoint                                                #
# --------------------------------------------------------------------------- #
# Checked against bedrock-agentcore 1.24 (BedrockAgentCoreApp.entrypoint/run).
try:
    from bedrock_agentcore.runtime import BedrockAgentCoreApp, BedrockAgentCoreContext

    app = BedrockAgentCoreApp()

    @app.entrypoint
    def invoke(payload: dict) -> dict:
        question = payload.get("prompt") or payload.get("question") or ""
        # One AgentCore runtime session = one conversation. The session id
        # arrives per request (X-Amzn-Bedrock-AgentCore-Runtime-Session-Id);
        # an explicit payload thread_id wins so a caller can pick its own.
        thread_id = payload.get("thread_id") or BedrockAgentCoreContext.get_session_id() or "demo-thread"
        return {"thread_id": thread_id, "answer": ask(question, thread_id)}

except ImportError:
    # bedrock_agentcore not installed (Tier-1 local run) -- that's fine.
    app = None


# --------------------------------------------------------------------------- #
# CLI                                                                         #
# --------------------------------------------------------------------------- #
def _main() -> int:
    parser = argparse.ArgumentParser(description="LangGraph + asz deployment-advisor agent")
    parser.add_argument("--local", action="store_true", help="run in-process instead of serving")
    parser.add_argument("--demo", action="store_true", help="play the multi-turn demo conversation")
    parser.add_argument("-q", "--question", default=DEMO_TURNS[0])
    parser.add_argument("--thread-id", default=None, help="conversation id (default: a fresh one)")
    parser.add_argument("--serve", action="store_true", help="serve the AgentCore HTTP app (default)")
    args = parser.parse_args()

    if not args.local:
        if app is None:
            print("bedrock_agentcore is not installed; cannot serve.", file=sys.stderr)
            return 1
        app.run()
        return 0

    thread_id = args.thread_id or f"advisor-{uuid.uuid4().hex[:8]}"
    turns = DEMO_TURNS if args.demo else [args.question]
    for question in turns:
        print(f"\nuser> {question}")
        print(f"agent> {ask(question, thread_id)}")
    print(f"\nthread_id={thread_id}  (asz conversation: ls-<project>-{thread_id}-...)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
