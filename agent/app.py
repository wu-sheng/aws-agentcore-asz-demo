"""Minimal LangGraph agent packaged for Amazon Bedrock AgentCore Runtime.

Two run modes:
  * ``python app.py --local``  -> invoke the graph once from the CLI (Tier-1 local
    observability validation; no AgentCore, no AWS).
  * AgentCore Runtime          -> the ``bedrock_agentcore`` app exposes the
    ``/invocations`` + ``/ping`` HTTP contract AgentCore expects.

Observability is NOT in this file by design. The ``langsmith`` tracing client is
bundled with ``langchain-core`` and is configured purely by environment variables
(see ``.env.example``). Point those env vars at an asz ``langsmith-ingest``
receiver and every graph run lands in asz — no code changes here.

The one thing the LangSmith wire cannot infer is the Conversation/thread identity,
so we set it explicitly in run metadata via ``configurable.thread_id``.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import TypedDict

from langgraph.graph import END, START, StateGraph


# --------------------------------------------------------------------------- #
# The graph                                                                   #
# --------------------------------------------------------------------------- #
class AgentState(TypedDict):
    question: str
    answer: str


def _call_model(state: AgentState) -> AgentState:
    """Single LLM node.

    The model provider is irrelevant to the observability path — asz reads the
    LangSmith trace, not the inference. Swap this for Bedrock, OpenAI, Anthropic,
    or a stub. We default to a Bedrock chat model when AWS creds are present and
    fall back to an echo stub so Tier-1 needs no credential at all.
    """
    question = state["question"]

    model_id = os.getenv("BEDROCK_MODEL_ID")
    if model_id:
        from langchain_aws import ChatBedrockConverse

        llm = ChatBedrockConverse(
            model=model_id,
            region_name=os.getenv("AWS_REGION", "us-east-1"),
        )
        answer = llm.invoke(question).content
    else:
        # Credential-free stub: proves the trace path without any LLM provider.
        answer = f"[stub answer] You asked: {question!r}"

    return {"question": question, "answer": answer}


def build_graph():
    graph = StateGraph(AgentState)
    graph.add_node("call_model", _call_model)
    graph.add_edge(START, "call_model")
    graph.add_edge("call_model", END)
    return graph.compile()


GRAPH = build_graph()


def run_once(question: str, thread_id: str) -> str:
    """Invoke the graph with an explicit thread_id in run metadata.

    asz never infers the Conversation identity — the thread key MUST be supplied.
    """
    result = GRAPH.invoke(
        {"question": question, "answer": ""},
        config={
            "configurable": {"thread_id": thread_id},
            "metadata": {"thread_id": thread_id},
            "run_name": "agentcore-asz-demo",
        },
    )
    return result["answer"]


# --------------------------------------------------------------------------- #
# AgentCore Runtime entrypoint                                                #
# --------------------------------------------------------------------------- #
# The bedrock_agentcore SDK wraps our handler as the /invocations + /ping server.
# NOTE: the SDK surface is unverified against live docs; confirm the current
# decorator/entrypoint name before the real Tier-2 deploy.
try:
    from bedrock_agentcore.runtime import BedrockAgentCoreApp

    app = BedrockAgentCoreApp()

    @app.entrypoint
    def invoke(payload: dict) -> dict:
        question = payload.get("prompt") or payload.get("question") or ""
        # AgentCore gives a session id per microVM session; use it as the thread.
        thread_id = payload.get("thread_id") or os.getenv(
            "AGENTCORE_SESSION_ID", "demo-thread"
        )
        return {"answer": run_once(question, thread_id)}

except ImportError:
    # bedrock_agentcore not installed (Tier-1 local run) — that's fine.
    app = None


# --------------------------------------------------------------------------- #
# CLI (Tier-1 local)                                                          #
# --------------------------------------------------------------------------- #
def _main() -> int:
    parser = argparse.ArgumentParser(description="LangGraph + asz demo agent")
    parser.add_argument("--local", action="store_true", help="run the graph once locally")
    parser.add_argument("--question", default="Hello from the LangGraph+asz demo. Who are you?")
    parser.add_argument("--thread-id", default="local-thread-001")
    parser.add_argument("--serve", action="store_true", help="start the AgentCore HTTP app")
    args = parser.parse_args()

    if args.serve:
        if app is None:
            print("bedrock_agentcore is not installed; cannot serve.", file=sys.stderr)
            return 1
        app.run()
        return 0

    # default / --local
    answer = run_once(args.question, args.thread_id)
    print(answer)
    print(
        "\nIf LANGCHAIN_TRACING_V2=true and the langsmith endpoint points at asz, "
        "this run just landed in the asz UI (http://127.0.0.1:8787).",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
