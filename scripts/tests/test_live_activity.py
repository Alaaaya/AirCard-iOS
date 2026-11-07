"""Host-side packaging checks. These do not compile Swift or validate signing."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]


class LiveActivityPackagingTests(unittest.TestCase):
    def test_extension_embedded_and_shared_types_in_both_targets(self):
        project = yaml.safe_load((ROOT / "project.yml").read_text())
        app = project["targets"]["Mirsa"]
        widget = project["targets"]["MirsaLiveActivity"]
        self.assertIn({"target": "MirsaLiveActivity", "embed": True}, app["dependencies"])
        self.assertIn({"path": "LiveActivityShared"}, app["sources"])
        self.assertIn({"path": "LiveActivityShared"}, widget["sources"])
        self.assertEqual(widget["type"], "app-extension")
        app_id = app["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"]
        self.assertTrue(widget["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"].startswith(app_id + "."))

    def test_owner_facing_artifact_is_mirsa(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/unsigned-ipa.yml").read_text())
        steps = workflow["jobs"]["build"]["steps"]
        artifact = next(s for s in steps if s.get("uses") == "actions/upload-artifact@v4")
        self.assertEqual(artifact["with"]["path"], "build/Mirsa.ipa")
        self.assertEqual(artifact["with"]["name"], "Mirsa-unsigned")
        releases = [s for s in steps if s.get("name", "").startswith("Publish")]
        self.assertTrue(all(s["if"] == "github.event_name == 'push'" for s in releases))

    def test_plists(self):
        parent = plistlib.loads((ROOT / "ios-app/Info.plist").read_bytes())
        child = plistlib.loads((ROOT / "MirsaLiveActivity/Info.plist").read_bytes())
        self.assertIs(parent["NSSupportsLiveActivities"], True)
        self.assertEqual(child["NSExtension"]["NSExtensionPointIdentifier"], "com.apple.widgetkit-extension")
        self.assertEqual(parent["CFBundleVersion"], child["CFBundleVersion"])
        self.assertEqual(parent["CFBundleShortVersionString"], child["CFBundleShortVersionString"])

    def setup_script(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/unsigned-ipa.yml").read_text())
        step = next(s for s in workflow["jobs"]["build"]["steps"]
                    if s.get("name") == "Publish Mirsa Setup + Feather source")
        # All publishing remains push-only; manual verification builds cannot release.
        self.assertEqual(step["if"], "github.event_name == 'push'")
        script = step["run"].split("<<'PYSETUP'\n", 1)[1].split("\nPYSETUP", 1)[0]
        compile(script, "setup-extension-rebase", "exec")
        return script

    def run_rebase(self, bundle_id, version="1.3.99"):
        with tempfile.TemporaryDirectory() as tmp:
            parent = pathlib.Path(tmp) / "Mirsa.app/Info.plist"
            child = parent.parent / "PlugIns/MirsaLiveActivity.appex/Info.plist"
            child.parent.mkdir(parents=True)
            parent.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.alaa.mirsa", "CFBundleVersion": "2.99.1"}))
            child.write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
            result = subprocess.run([sys.executable, "-c", self.setup_script(), str(parent), version],
                                    capture_output=True, text=True)
            return result, plistlib.loads(child.read_bytes()), plistlib.loads(parent.read_bytes())

    def test_setup_rebases_and_versions_extension(self):
        result, child, parent = self.run_rebase("com.alaa.mirsa.liveactivity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(child["CFBundleIdentifier"], "com.alaa.mirsa.setup.liveactivity")
        self.assertEqual(child["CFBundleShortVersionString"], "1.3.99")
        self.assertEqual(child["CFBundleVersion"], "2.99.1")
        # Parent change remains in the existing PlistBuddy commands.
        self.assertEqual(parent["CFBundleIdentifier"], "com.alaa.mirsa")

    def test_setup_rejects_unrelated_extension_id(self):
        result, child, _ = self.run_rebase("com.other.widget")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not prefixed", result.stderr)
        self.assertEqual(child["CFBundleIdentifier"], "com.other.widget")

    def test_setup_rebase_is_idempotent(self):
        # The prefix calculation also works if the containing app is already Setup.
        script = self.setup_script()
        with tempfile.TemporaryDirectory() as tmp:
            parent = pathlib.Path(tmp) / "Mirsa.app/Info.plist"
            child = parent.parent / "PlugIns/MirsaLiveActivity.appex/Info.plist"
            child.parent.mkdir(parents=True)
            parent.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.alaa.mirsa.setup", "CFBundleVersion": "2.99.1"}))
            child.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.alaa.mirsa.setup.liveactivity"}))
            subprocess.run([sys.executable, "-c", script, str(parent), "1.3.99"], check=True)
            self.assertEqual(plistlib.loads(child.read_bytes())["CFBundleIdentifier"], "com.alaa.mirsa.setup.liveactivity")

    def test_delegate_persists_opaque_id_and_flushes_before_completion(self):
        delegate = (ROOT / "ios-app/Apps/BackgroundIPADownloads.swift").read_text()
        self.assertIn("task.taskDescription = MirsaInstallActivity.shared.operationID", delegate)
        self.assertIn("operationID: downloadTask.taskDescription", delegate)
        self.assertIn("await MirsaInstallActivity.shared.flush()\n                completion?()", delegate)
        manager = (ROOT / "ios-app/Apps/MirsaInstallActivity.swift").read_text()
        self.assertIn("!endedIDs.contains(operationID)", manager)
        self.assertIn("guard activity == nil || activity?.attributes.operationID == operationID", manager)
        self.assertIn("pushType: nil", manager)
        self.assertIn("await previous?.value", manager)


if __name__ == "__main__":
    unittest.main()
