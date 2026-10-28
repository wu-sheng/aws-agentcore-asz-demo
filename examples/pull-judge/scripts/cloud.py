"""Invoke the isolated AgentCore runtime and pull three evidence snapshots.

Reads only this example's OpenTofu outputs. Never prints or passes tokens as arguments.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import http.client
import json
from pathlib import Path
import socket
import ssl
import subprocess
import time
from urllib.parse import urlparse
from urllib.request import getproxies, proxy_bypass
import uuid

import boto3
from botocore.config import Config

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / ".work/bin/asz"


def save(path, value):
    path.write_text(json.dumps(value, indent=2, default=str) + "\n")


def now():
    return datetime.now(timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()
    outputs = json.loads(subprocess.check_output(["tofu", "output", "-json"], cwd=ROOT / "infra"))
    value = lambda name: outputs[name]["value"]
    if value("project_tag") != "asz-pull-judge":
        raise ValueError("Refusing to invoke another project's deployment")
    arn = value("agent_runtime_arn")
    if not arn.startswith("arn:"):
        raise ValueError("The independent runtime is not deployed")
    work = ROOT / ".work" / ("cloud-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    work.mkdir(mode=0o700)
    client = work / "client"
    client.mkdir()
    token = value("pull_token")
    token_path = work / "token"
    token_path.write_text(token)
    token_path.chmod(0o600)
    ca = ROOT / ".work/cloud/cert.pem"
    endpoint = urlparse(value("asz_ui_url"))
    server_name = value("tls_server_name")
    save(client / "asz.yaml", {"storage": {"root": str(client / "data")}, "adapters": [],
        "remotes": [{"name": "demo", "url": value("asz_ui_url"), "token_file": str(token_path),
                     "ca_file": str(ca), "server_name": server_name}],
        "judge": {"timeout": "15m", "mode": "single", "read_bytes": 524288}})
    context = ssl.create_default_context(cafile=str(ca))

    def api(path, bearer=token):
        # Connect to the load balancer while verifying the certificate's private DNS name.
        proxy_url = None if proxy_bypass(endpoint.hostname) else getproxies().get("https")
        if proxy_url:
            proxy = urlparse(proxy_url)
            if proxy.scheme != "http" or proxy.username or proxy.password:
                raise ValueError("This experiment supports an HTTP CONNECT proxy without embedded credentials")
            conn = http.client.HTTPConnection(proxy.hostname, proxy.port or 80, timeout=30)
            conn.set_tunnel(endpoint.hostname, endpoint.port)
            conn.connect()
            conn.sock = context.wrap_socket(conn.sock, server_hostname=server_name)
        else:
            conn = http.client.HTTPSConnection(server_name, endpoint.port, context=context, timeout=30)
            conn.sock = context.wrap_socket(socket.create_connection((endpoint.hostname, endpoint.port), timeout=30),
                                            server_hostname=server_name)
        try:
            conn.request("GET", path, headers={"Authorization": "Bearer " + bearer})
            response = conn.getresponse()
            body = response.read()
            if response.status != 200:
                return response.status, None
            return response.status, json.loads(body)
        finally:
            conn.close()

    def cli(*arguments):
        start, tick = now(), time.monotonic()
        result = subprocess.run([str(BIN), *arguments], cwd=client, text=True, capture_output=True, check=True)
        return {"started": start, "ended": now(), "seconds": time.monotonic() - tick,
                "stdout": result.stdout, "stderr": result.stderr}

    print("Evidence:", work, flush=True)
    if api("/api/conversations", "wrong")[0] != 401:
        raise AssertionError("wrong token was not rejected")
    status, initial = api("/api/conversations")
    if status != 200:
        raise RuntimeError("Authenticated remote access failed")
    initial_ids = {row["id"] for row in initial}
    save(work / "pull-list.json", cli("pull", "-list", "-remote", "demo"))
    session = boto3.Session(region_name=args.region)
    # An invocation mutates simulator state; disable automatic retries to avoid duplicating a turn.
    runtime = session.client("bedrock-agentcore", config=Config(
        retries={"mode": "standard", "total_max_attempts": 1}, connect_timeout=15, read_timeout=300))
    thread = "release-" + uuid.uuid4().hex
    save(work / "session.json", {"thread_id": thread, "runtime_arn": arn, "region": args.region, "started": now()})
    checkpoints = []
    for turn in json.loads((ROOT / "scenarios/release.json").read_text())["turns"]:
        print("AgentCore real-model turn", turn["id"], flush=True)
        start, tick = now(), time.monotonic()
        response = runtime.invoke_agent_runtime(agentRuntimeArn=arn, runtimeSessionId=thread,
            contentType="application/json", payload=json.dumps({"prompt": turn["prompt"]}).encode())
        body = response["response"].read()
        response["response"].close()
        answer = json.loads(body)
        save(work / f"turn-{turn['id']}.json", {"request": turn, "response": answer,
            "started": start, "ended": now(), "seconds": time.monotonic() - tick,
            "status_code": response["statusCode"]})
        if response["statusCode"] != 200 or not answer.get("answer"):
            raise RuntimeError("Agent did not return a successful answer; see evidence")
        if "checkpoint" not in turn:
            continue
        previous, stable = None, 0
        for _ in range(60):
            status, rows = api("/api/conversations")
            if status != 200:
                raise RuntimeError("Could not read cloud collection status")
            candidates = [row for row in rows if row["id"] not in initial_ids]
            if len(candidates) > 1:
                raise RuntimeError("Multiple new conversations; choose explicitly before proceeding")
            if len(candidates) == 1:
                row = candidates[0]
                if row["talks"] >= turn["id"] and row.get("changes", 0) > 0 and row.get("unresolved", 0) == 0:
                    stable = stable + 1 if row == previous else 0
                    previous = row
                    if stable >= 3:
                        break
            time.sleep(5)
        else:
            raise TimeoutError("Cloud collection did not settle")
        pulled = cli("pull", "demo/" + previous["id"])
        checkpoints.append({"checkpoint": turn["checkpoint"], "conversation": previous, "pull": pulled})
        save(work / "checkpoints.json", checkpoints)
        print(pulled["stdout"].strip(), flush=True)
    save(work / "pull-repeat.json", cli("pull", "demo/" + previous["id"]))
    save(work / "result.json", {"completed": now(), "thread_id": thread, "checkpoints": checkpoints})
    print("Seven turns and three cloud snapshots complete:", work, flush=True)


if __name__ == "__main__":
    main()
