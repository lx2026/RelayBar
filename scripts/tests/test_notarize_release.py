"""Exercise distribution routing in a disposable repository with no Apple/network calls."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
DRIVER = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys, zipfile
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name.startswith("build-"):
    app = "Frame" if name == "build-frame" else "RelayBar"
    source = root / ("Apps/Frame/AppBundle/Info.plist" if app == "Frame" else "Apps/RelayBar/Packaging/Info.plist")
    target = root / ("Apps/Frame/.build/app/Frame.app" if app == "Frame" else ".build/RelayBar.app")
    (target / "Contents").mkdir(parents=True, exist_ok=True)
    (target / "Contents/Info.plist").write_bytes(source.read_bytes())
elif name == "ditto":
    source, target = map(pathlib.Path, args[-2:])
    if "-x" in args:
        with zipfile.ZipFile(source) as archive:
            archive.extractall(target)
    else:
        with zipfile.ZipFile(target, "w") as archive:
            for path in source.rglob("*"):
                if path.is_file(): archive.write(path, path.relative_to(source.parent))
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        if os.environ.get("FAIL_SUBMIT"): sys.exit(42)
        print(json.dumps({"id": "fixture-submission", "status": os.environ.get("NOTARY_STATUS", "Accepted")}))
    elif args[:2] == ["stapler", "staple"]:
        (pathlib.Path(args[2]) / "Contents/ticket").write_text("fixture ticket")
    elif args[:2] == ["stapler", "validate"]:
        assert (pathlib.Path(args[2]) / "Contents/ticket").is_file()
    else: raise AssertionError(args)
elif name == "plutil":
    print(json.loads(pathlib.Path(args[-1]).read_text())["status"])
elif name == "spctl":
    assert (pathlib.Path(args[-1]) / "Contents/ticket").is_file()
elif name == "codesign":
    assert (pathlib.Path(args[-1]) / "Contents/Info.plist").is_file()
else: raise AssertionError(name)
'''


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release scripts ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("notarize-release.sh", "package-release.sh", "require-publication-approval.sh", "release-plan.py"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        bin_path = self.root / "bin"
        bin_path.mkdir()
        driver = bin_path / "driver"
        driver.write_text(DRIVER)
        driver.chmod(0o755)
        for name in ("ditto", "xcrun", "plutil", "spctl", "codesign", "build-frame", "build-relaybar"):
            (bin_path / name).symlink_to(driver)
        for app, relative in (("Frame", "Apps/Frame/AppBundle"), ("RelayBar", "Apps/RelayBar/Packaging")):
            folder = self.root / relative
            folder.mkdir(parents=True)
            info = {"CFBundleIdentifier": f"fixture.{app}", "CFBundleVersion": "9",
                    "CFBundleShortVersionString": "0.1.0", "SUFeedURL": "https://example.invalid/appcast.xml"}
            (folder / "Info.plist").write_bytes(plistlib.dumps(info))
        frame_scripts = self.root / "Apps/Frame/Scripts"
        frame_scripts.mkdir()
        # Invoke distinct build commands so cross-app routing is observable.
        for path, app in ((scripts / "build-app.sh", "relaybar"), (frame_scripts / "build-app.sh", "frame")):
            path.write_text(f'#!/bin/bash\nexec build-{app} "$@"\n')
            path.chmod(0o755)
        self.env = {**os.environ, "PATH": str(bin_path) + os.pathsep + os.environ["PATH"],
                    "FIXTURE_ROOT": str(self.root), "RELAYBAR_PUBLICATION_APPROVED": "yes",
                    "NOTARY_PROFILE": "fixture-profile"}
        self.env.pop("FAIL_SUBMIT", None)
        self.env.pop("NOTARY_STATUS", None)

    def run_script(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/notarize-release.sh"), *args],
                              env=self.env, capture_output=True, text=True)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def check_success(self, app, *args):
        result = self.run_script(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(calls[0], [f"build-{app.lower()}", "release"])
        archive = self.root / f".build/{app}.zip"
        submit = next(call for call in calls if call[:3] == ["xcrun", "notarytool", "submit"])
        self.assertEqual(submit[3], str(archive))
        self.assertIn("--wait", submit)
        with zipfile.ZipFile(archive) as bundle:
            self.assertIn(f"{app}.app/Contents/ticket", bundle.namelist())
            self.assertTrue(all(name.startswith(f"{app}.app/") for name in bundle.namelist()))
        validates = [call[-1] for call in calls if call[:3] == ["xcrun", "stapler", "validate"]]
        self.assertEqual(len(validates), 2)
        self.assertNotEqual(validates[0], validates[1])
        self.assertFalse(Path(validates[1]).exists(), "Clean extraction must be removed")
        self.assertIn('"sha256":', result.stdout)
        self.assertEqual(len([c for c in calls if c[0] == "spctl"]), 2)

    def test_default_keeps_relaybar_route(self):
        self.check_success("RelayBar")

    def test_frame_uses_only_frame_bundle_and_archive(self):
        self.check_success("Frame", "frame")

    def test_rejected_submission_never_staples_or_repackages(self):
        self.env["NOTARY_STATUS"] = "Invalid"
        result = self.run_script("frame")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not accepted", result.stderr)
        self.assertFalse(any(c[:2] == ["xcrun", "stapler"] for c in self.calls()))
        self.assertEqual(len([c for c in self.calls() if c[0] == "ditto"]), 1)

    def test_failed_submit_stops_pipeline(self):
        self.env["FAIL_SUBMIT"] = "1"
        self.assertNotEqual(self.run_script("frame").returncode, 0)
        self.assertFalse(any(c[:2] == ["xcrun", "stapler"] for c in self.calls()))

    def test_unknown_app_and_extra_arguments_have_no_side_effects(self):
        for args in (("unknown",), ("frame", "relaybar")):
            self.assertEqual(self.run_script(*args).returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_publication_guard_precedes_build(self):
        self.env.pop("RELAYBAR_PUBLICATION_APPROVED")
        self.assertNotEqual(self.run_script("frame").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_missing_profile_precedes_build(self):
        self.env.pop("NOTARY_PROFILE")
        self.assertNotEqual(self.run_script("frame").returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
