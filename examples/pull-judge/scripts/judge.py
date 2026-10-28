"""Judge the three saved checkpoints with the remote deliberately unreachable."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / ".work/bin/asz"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    work = args.evidence.resolve()
    client = work / "client"
    config = json.loads((client / "asz.yaml").read_text())
    # Retain the snapshot namespace and storage root, but make the cloud endpoint unreachable.
    for remote in config["remotes"]:
        remote["url"] = "https://127.0.0.1:9"
    config_path = client / "judge-only.yaml"
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    probe = subprocess.run([str(BIN), "pull", "-config", str(config_path), "-list", "-remote", "demo"],
                           cwd=client, text=True, capture_output=True, timeout=30)
    (work / "judge-remote-unreachable.txt").write_text(probe.stdout + probe.stderr)
    if probe.returncode == 0:
        raise AssertionError("The unreachable-remote check unexpectedly succeeded")
    checkpoints = json.loads((work / "checkpoints.json").read_text())

    def judge(checkpoint):
        pull = checkpoint["pull"]
        ref = (pull["stdout"] if isinstance(pull, dict) else pull).strip().removesuffix(" unchanged")
        if not ref.startswith("demo/") or "\n" in ref or " " in ref:
            raise ValueError("Unexpected snapshot reference")
        label = checkpoint["checkpoint"]
        print("Judging checkpoint", label, "without a reachable remote", flush=True)
        started = datetime.now(timezone.utc).isoformat()
        tick = time.monotonic()
        with (work / f"judge-{label}.log").open("w") as log:
            result = subprocess.run([str(BIN), "judge", "-config", str(config_path),
                "-evaluator", "claude", "-remote-conversation", ref], cwd=client,
                stdout=log, stderr=subprocess.STDOUT)
        return {"checkpoint": label, "snapshot": ref, "exit_code": result.returncode,
                "started": started, "ended": datetime.now(timezone.utc).isoformat(),
                "seconds": time.monotonic() - tick}

    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(judge, checkpoints))
    (work / "judge-results.json").write_text(json.dumps(results, indent=2) + "\n")
    print("Judge processes finished; inspect complete/partial/failed states in each report.", flush=True)


if __name__ == "__main__":
    main()
