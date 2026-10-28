"""Local HTTPS pull preflight, or real Bedrock Agent -> collection -> snapshots.

Uses only this example's .work directory. Processes started here are stopped on exit.
Run with .venv/bin/python scripts/local.py [--run]. Model access is needed only for --run.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / ".work/bin/asz"


def save(path: Path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def request(url, token=None, context=None, payload=None, session=None):
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    if session:
        headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"] = session
    if payload is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, headers=headers, data=None if payload is None else json.dumps(payload).encode())
    with urllib.request.urlopen(req, context=context, timeout=300) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args()
    if args.run and not os.environ.get("BEDROCK_MODEL_ID"):
        parser.error("--run requires BEDROCK_MODEL_ID; no scripted fallback")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    work = ROOT / ".work" / ("local-" + stamp + "-" + secrets.token_hex(2))
    work.mkdir(mode=0o700, parents=True)
    client = work / "client"
    client.mkdir()
    changes = work / "changes"
    changes.mkdir()
    shutil.copyfile(ROOT / "config/changes.yaml", changes / "settings.yaml")
    token = "asz_" + secrets.token_urlsafe(32)
    (work / "token").write_text(token)
    (work / "token").chmod(0o600)
    (work / "tokens").write_text("developer " + hashlib.sha256(token.encode()).hexdigest() + "\n")
    (work / "tokens").chmod(0o600)
    (work / "openssl.cnf").write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
        "[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n"
        "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n"
        "extendedKeyUsage=serverAuth\n")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3",
                    "-config", str(work / "openssl.cnf"), "-keyout", str(work / "key.pem"),
                    "-out", str(work / "cert.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ingest = secrets.token_urlsafe(24)
    save(work / "server.yaml", {"storage": {"root": str(work / "server-data")},
        "remote_server": {"tokens_file": str(work / "tokens"), "tls": {
            "cert_file": str(work / "cert.pem"), "key_file": str(work / "key.pem")}},
        "adapters": [
            {"name": "langsmith-ingest", "enabled": True, "listen": "127.0.0.1:11985", "token": ingest,
             "collector": {"mode": "watch", "interval": "2s"}},
            {"name": "changes", "enabled": True, "source_root": str(changes),
             "collector": {"mode": "watch", "interval": "2s"}}]})
    save(client / "asz.yaml", {"storage": {"root": str(client / "data")}, "adapters": [],
        "remotes": [{"name": "demo", "url": "https://localhost:18788", "token_file": str(work / "token"),
                     "ca_file": str(work / "cert.pem")}],
        "judge": {"timeout": "15m", "mode": "single", "read_bytes": 524288}})
    processes, logs = [], []

    def start(command, name, env=None):
        handle = (work / (name + ".log")).open("w")
        logs.append(handle)
        process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, env=env)
        processes.append(process)
        return process

    def cli(*arguments):
        result = subprocess.run([str(BIN), *arguments], cwd=client, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout

    try:
        server = start([str(BIN), "server", "-config", str(work / "server.yaml"), "127.0.0.1:18788"], "server")
        context = ssl.create_default_context(cafile=str(work / "cert.pem"))
        for _ in range(30):
            if server.poll() is not None:
                raise RuntimeError("asz exited; see " + str(work / "server.log"))
            try:
                request("https://localhost:18788/api/conversations", token, context)
                break
            except urllib.error.URLError:
                time.sleep(1)
        else:
            raise TimeoutError("asz did not become ready")
        try:
            request("https://localhost:18788/api/conversations", "wrong", context)
            raise AssertionError("wrong token was accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 401
        (work / "pull-list.txt").write_text(cli("pull", "-list", "-remote", "demo"))
        print("HTTPS verification, wrong-token rejection, and authenticated pull listing passed", flush=True)
        if not args.run:
            save(work / "result.json", {"preflight": "passed", "agent_run": False})
            return
        env = os.environ | {"LANGSMITH_TRACING": "true", "LANGSMITH_ENDPOINT": "http://127.0.0.1:11985",
            "LANGSMITH_API_KEY": ingest, "LANGSMITH_PROJECT": "asz-pull-judge-local",
            "AWS_REGION": os.environ.get("AWS_REGION", "us-east-1"),
            "ASZ_CHANGES": "true", "ASZ_CHANGES_BIN": str(ROOT / ".work/bin/asz-changes"),
            "ASZ_CHANGES_DATA": str(changes), "DEMO_WORKSPACE": str(work / "workspace")}
        thread = "release-" + uuid.uuid4().hex
        # AgentCore's local HTTP server runs on 8080. A port conflict is an error,
        # never permission to stop an existing process.
        agent = start([str(ROOT / ".venv/bin/python"), str(ROOT / "agent/app.py")], "agent", env)
        for _ in range(30):
            if agent.poll() is not None:
                raise RuntimeError("agent exited; see " + str(work / "agent.log"))
            try:
                request("http://127.0.0.1:8080/ping")
                break
            except urllib.error.URLError:
                time.sleep(1)
        else:
            raise TimeoutError("agent did not become ready")
        checkpoints = []
        for turn in json.loads((ROOT / "scenarios/release.json").read_text())["turns"]:
            print("Invoking real Bedrock model, turn", turn["id"], flush=True)
            response = request("http://127.0.0.1:8080/invocations", payload={"prompt": turn["prompt"]}, session=thread)
            save(work / f"turn-{turn['id']}.json", {"request": turn, "response": response})
            if "checkpoint" not in turn:
                continue
            previous, stable = None, 0
            for _ in range(60):
                rows = request("https://localhost:18788/api/conversations", token, context)
                if len(rows) == 1 and rows[0]["talks"] >= turn["id"] and (rows[0].get("changes") or 0) > 0:
                    stable = stable + 1 if rows[0] == previous else 0
                    previous = rows[0]
                    if stable >= 3:
                        break
                time.sleep(2)
            else:
                raise TimeoutError("conversation or changes did not settle")
            output = cli("pull", "demo/" + previous["id"])
            (work / ("pull-" + turn["checkpoint"] + ".txt")).write_text(output)
            checkpoints.append({"checkpoint": turn["checkpoint"], "conversation": previous, "pull": output})
            save(work / "checkpoints.json", checkpoints)
            print(output, flush=True)
        (work / "pull-repeat.txt").write_text(cli("pull", "demo/" + previous["id"]))
        save(work / "result.json", {"preflight": "passed", "agent_run": True,
             "thread_id": thread, "model": env["BEDROCK_MODEL_ID"], "checkpoints": checkpoints})
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for log in logs:
            log.close()
        print("Evidence:", work, flush=True)


if __name__ == "__main__":
    main()
