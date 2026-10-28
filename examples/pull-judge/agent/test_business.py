import json
from pathlib import Path
import tempfile
import unittest

from business import ReleaseWorkspace


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ws = ReleaseWorkspace(Path(self.temp.name))

    def prepare(self, environment="staging", timeout=300):
        self.ws.write("configs/app.json", json.dumps({"release": "demo-v1", "environment": environment,
                      "replicas": 2, "idle_timeout_seconds": timeout}))
        return self.ws.build("configs/app.json")

    def test_deployment_matches_immutable_bundle_after_config_changes(self):
        old = self.prepare()
        self.prepare(timeout=600)
        result = self.ws.deploy(old["bundle_id"])
        self.assertEqual(result["configuration"]["idle_timeout_seconds"], 300)
        self.assertEqual(self.ws.deployment("staging"), result)

    def test_denial_does_not_create_a_deployment(self):
        bundle = self.prepare("production")
        self.assertEqual(self.ws.deploy(bundle["bundle_id"])["status"], "denied")
        self.assertEqual(self.ws.deployment("production")["status"], "not_deployed")

    def test_submission_never_implies_approval(self):
        self.assertEqual(self.ws.submit("staging")["status"], "rejected")
        self.ws.deploy(self.prepare()["bundle_id"])
        submitted = self.ws.submit("staging")
        self.assertEqual(submitted["status"], "submitted")
        status = self.ws.acceptance(submitted["request_id"])
        self.assertIsNone(status["approved"])
        self.assertEqual(status["status"], "unavailable")

    def test_invalid_config_is_not_bundled(self):
        self.prepare(timeout=True)
        self.assertEqual(self.ws.validate("configs/app.json")["status"], "invalid")
        self.assertFalse((self.ws.root / "bundles").exists())

    def test_tools_cannot_forge_state_or_escape_workspace(self):
        for name in ("../escape", "state/staging.json", "configs/../../escape", "configs/../state/staging.json"):
            with self.assertRaises(ValueError):
                self.ws.write(name, "{}")


if __name__ == "__main__":
    unittest.main()
