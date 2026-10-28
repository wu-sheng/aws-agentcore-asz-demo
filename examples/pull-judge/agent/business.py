"""Stateful release simulator. No function deploys a real cloud application."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import uuid


def digest(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


class ReleaseWorkspace:
    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, name: str) -> Path:
        path = (self.root / name).resolve()
        if not path.is_relative_to(self.root.resolve()) or path == self.root.resolve():
            raise ValueError("path must be a file inside this conversation's workspace")
        return path

    def _save(self, name: str, value: dict) -> dict:
        path = self._path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        return value

    def read(self, name: str) -> dict:
        path = self._path(name)
        if not path.is_file():
            return {"status": "not_found", "path": name}
        return {"status": "read", "path": name, "content": path.read_text()}

    def write(self, name: str, content: str) -> dict:
        path = self._path(name)
        if path.relative_to(self.root.resolve()).parts[0] not in ("configs", "reports") or path.parts[-1].startswith("."):
            raise ValueError("write_file may write only configs/ or reports/; tool-owned state is read-only")
        if len(content.encode()) > 32000:
            raise ValueError("file exceeds 32000 bytes")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return {"status": "written", "path": name, "bytes": path.stat().st_size}

    def validate(self, name: str) -> dict:
        try:
            value = json.loads(self._path(name).read_text())
        except (OSError, json.JSONDecodeError) as exc:
            return {"status": "invalid", "errors": [str(exc)]}
        if not isinstance(value, dict):
            return {"status": "invalid", "errors": ["configuration must be a JSON object"]}
        errors = []
        expected = {"release", "environment", "replicas", "idle_timeout_seconds"}
        if set(value) != expected:
            errors.append("required keys, no extras: " + ", ".join(sorted(expected)))
        if not isinstance(value.get("release"), str) or not value.get("release"):
            errors.append("release must be a nonempty string")
        if value.get("environment") not in ("staging", "production"):
            errors.append("environment must be staging or production")
        for key, low, high in (("replicas", 1, 10), ("idle_timeout_seconds", 60, 3600)):
            if type(value.get(key)) is not int or not low <= value[key] <= high:
                errors.append(f"{key} must be an integer from {low} to {high}")
        if errors:
            return {"status": "invalid", "errors": errors}
        return {"status": "valid", "configuration": value, "sha256": digest(value)}

    def build(self, name: str) -> dict:
        checked = self.validate(name)
        if checked["status"] != "valid":
            return checked
        bundle_id = checked["sha256"]
        self._save(f"bundles/{bundle_id}.json", checked)
        return {"status": "built", "bundle_id": bundle_id, "configuration": checked["configuration"]}

    def deploy(self, bundle_id: str) -> dict:
        if len(bundle_id) != 64 or any(c not in "0123456789abcdef" for c in bundle_id):
            raise ValueError("bundle_id must be the SHA-256 returned by build_release")
        path = self._path(f"bundles/{bundle_id}.json")
        if not path.exists():
            return {"status": "not_found", "bundle_id": bundle_id}
        config = json.loads(path.read_text())["configuration"]
        if digest(config) != bundle_id:
            raise ValueError("bundle content does not match its digest")
        if config["environment"] == "production":
            return {"status": "denied", "environment": "production", "deployed": False,
                    "reason": "The demo operator has no production deployment permission.", "bundle_id": bundle_id}
        value = {"status": "deployed", "deployment_id": "dep-" + uuid.uuid4().hex,
                 "bundle_id": bundle_id, "configuration": config, "simulated": True}
        return self._save("state/staging.json", value)

    def deployment(self, environment: str) -> dict:
        if environment not in ("staging", "production"):
            raise ValueError("environment must be staging or production")
        path = self._path(f"state/{environment}.json")
        return json.loads(path.read_text()) if path.exists() else {"status": "not_deployed", "environment": environment}

    def submit(self, environment: str) -> dict:
        deployment = self.deployment(environment)
        if deployment["status"] != "deployed":
            return {"status": "rejected", "reason": "No deployment exists for acceptance."}
        request_id = "accept-" + uuid.uuid4().hex
        value = {"status": "submitted", "request_id": request_id,
                 "deployment_id": deployment["deployment_id"], "approved": None}
        return self._save(f"acceptance/{request_id}.json", value)

    def acceptance(self, request_id: str) -> dict:
        if not request_id.startswith("accept-") or not request_id[7:].isalnum():
            raise ValueError("use the request ID returned by submit_acceptance")
        path = self._path(f"acceptance/{request_id}.json")
        if not path.exists():
            return {"status": "not_found", "request_id": request_id}
        return {"status": "unavailable", "request_id": request_id, "approved": None,
                "reason": "The simulated acceptance result service is unavailable. Submission is saved; approval is unknown."}
