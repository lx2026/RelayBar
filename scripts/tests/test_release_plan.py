import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("release_plan", Path(__file__).parents[1] / "release-plan.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleasePlanTests(unittest.TestCase):
    def test_existing_channels_and_independent_release_identity(self):
        relay = release.plan("relaybar")
        frame = release.plan("frame")
        self.assertEqual(relay["install"], "brew install --cask lx2026/tap/relaybar")
        self.assertEqual(relay["upgrade"], "brew upgrade --cask lx2026/tap/relaybar")
        self.assertEqual(relay["feed"], "https://lx2026.github.io/RelayBar/appcast.xml")
        self.assertEqual(relay["tap"], "lx2026/homebrew-tap")
        self.assertTrue(relay["make_latest"])
        self.assertFalse(frame["make_latest"])
        self.assertTrue(frame["tag"].startswith("frame-v"))
        self.assertFalse(relay["publication_authorized"])
        self.assertFalse(frame["publication_authorized"])

    def test_wrong_app_and_stale_build_are_rejected_but_nested_helpers_are_allowed(self):
        metadata = plistlib.loads((release.ROOT / release.APPS["relaybar"][1]).read_bytes())
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / "RelayBar.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("RelayBar.app/Contents/Info.plist", plistlib.dumps(metadata))
                bundle.writestr("RelayBar.app/Contents/Frameworks/Updater.app/Contents/Info.plist", b"helper")
            self.assertIn("sha256", release.plan("relaybar", archive))
            with self.assertRaises(ValueError):
                release.plan("frame", archive)
            metadata["CFBundleVersion"] = "-1"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("RelayBar.app/Contents/Info.plist", plistlib.dumps(metadata))
            with self.assertRaises(ValueError):
                release.plan("relaybar", archive)


if __name__ == "__main__":
    unittest.main()
