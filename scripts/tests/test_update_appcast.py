"""Exercise appcast generation in a disposable repository with no Apple, Sparkle or network calls."""
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
URL = "https://github.com/lx2026/RelayBar/releases/download/v0.1.0/RelayBar.zip"
DRIVER = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, plistlib, shutil, sys, zipfile
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
def signature(path):
    return "fixture:" + hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
if name == "ditto":
    assert args[:2] == ["-x", "-k"], args
    with zipfile.ZipFile(args[2]) as archive:
        archive.extractall(args[3])
elif name == "codesign":
    app = pathlib.Path(args[-1])
    identifier = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    team = (app / "Contents/fixture-team").read_text()
    satisfied = f'=anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
    # Like codesign, check a requirement only when one is given.
    if any(arg.startswith("-R=") and arg != "-R=" + satisfied for arg in args):
        sys.exit(f"{app}: test-requirement: code failed to satisfy specified code requirement(s)")
elif name == "cp":
    target = pathlib.Path(args[-1]).resolve()
    if os.environ.get("FAIL_FEED_COPY") and target.parent == (root / "docs").resolve():
        target.write_text("<rss><chan")
        sys.exit("cp: write error: No space left on device")
    os.execv("/bin/cp", ["cp", *args])
elif name == "xcrun":
    assert args[:2] == ["stapler", "validate"], args
    if not (pathlib.Path(args[2]) / "Contents/ticket").is_file():
        sys.exit("The validate action failed: no ticket is stapled.")
elif name == "spctl":
    if not (pathlib.Path(args[-1]) / "Contents/ticket").is_file():
        sys.exit("rejected: Unnotarized Developer ID")
elif name == "curl":
    source = root / "published" / args[-3].rsplit("/", 1)[-1]
    if not source.is_file(): sys.exit(22)
    shutil.copyfile(source, args[-1])
elif name == "generate_appcast":
    folder = pathlib.Path(args[-1])
    prefix = args[args.index("--download-url-prefix") + 1]
    items = []
    for archive in sorted(folder.glob("*.zip")):
        with zipfile.ZipFile(archive) as bundle:
            build = plistlib.loads(bundle.read("RelayBar.app/Contents/Info.plist"))["CFBundleVersion"]
        items.append(f'<item><sparkle:version>{build}</sparkle:version><enclosure url="{prefix}{archive.name}" '
                     f'length="{archive.stat().st_size}" sparkle:edSignature="{signature(archive)}"/></item>')
    (folder / "appcast.xml").write_text(
        '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        f'<channel>{"".join(items)}</channel></rss>')
elif name == "generate_keys":
    print(os.environ.get("FIXTURE_KEYCHAIN_KEY", "fixture-public-key"))
elif name == "sign_update":
    assert "--verify" in args, args
    if len(args) == 4:
        if os.environ.get("FAIL_FEED_VERIFY"): sys.exit("The feed signature is invalid.")
    elif args[-1] != signature(args[-2]):
        sys.exit("The archive signature is invalid.")
else: raise AssertionError(name)
'''


class UpdateAppcastTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="appcast scripts ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("update-appcast.sh", "verify-update-feed.sh", "require-publication-approval.sh", "release-plan.py"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        bin_path, sparkle = self.root / "bin", self.root / "sparkle"
        bin_path.mkdir()
        sparkle.mkdir()
        driver = bin_path / "driver"
        driver.write_text(DRIVER)
        driver.chmod(0o755)
        for name in ("ditto", "codesign", "xcrun", "spctl", "curl", "cp"):
            (bin_path / name).symlink_to(driver)
        for name in ("generate_appcast", "generate_keys", "sign_update"):
            (sparkle / name).symlink_to(driver)
        self.metadata = {"CFBundleIdentifier": "fixture.RelayBar", "CFBundleVersion": "9",
                         "CFBundleShortVersionString": "0.1.0",
                         "SUFeedURL": "https://lx2026.github.io/RelayBar/appcast.xml",
                         "SUPublicEDKey": "fixture-public-key", "SURequireSignedFeed": True,
                         "SUVerifyUpdateBeforeExtraction": True}
        packaging = self.root / "Apps/RelayBar/Packaging"
        packaging.mkdir(parents=True)
        (packaging / "Info.plist").write_bytes(plistlib.dumps(self.metadata))
        entitlements = {"com.apple.security.application-groups": ["ABCDE12345.FrameRelay"]}
        (packaging / "RelayBar.entitlements").write_bytes(plistlib.dumps(entitlements))
        (self.root / "docs").mkdir()
        self.feed = self.root / "docs/appcast.xml"
        self.feed.write_text("<rss><!-- the feed already published --></rss>\n")
        (self.root / "published").mkdir()
        self.archive = self.root / "RelayBar.zip"
        self.env = {**os.environ, "PATH": str(bin_path) + os.pathsep + os.environ["PATH"],
                    "FIXTURE_ROOT": str(self.root), "SPARKLE_BIN": str(sparkle),
                    "RELAYBAR_PUBLICATION_APPROVED": "yes"}
        for name in ("FAIL_FEED_VERIFY", "FAIL_FEED_COPY", "FIXTURE_KEYCHAIN_KEY", "SPARKLE_ACCOUNT"):
            self.env.pop(name, None)

    def build_archive(self, stapled=True, team="ABCDE12345", **changes):
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("RelayBar.app/Contents/Info.plist", plistlib.dumps({**self.metadata, **changes}))
            bundle.writestr("RelayBar.app/Contents/fixture-team", team)
            if stapled:
                bundle.writestr("RelayBar.app/Contents/ticket", "fixture ticket")
        shutil.copyfile(self.archive, self.root / "published/RelayBar.zip")

    def run_script(self):
        return subprocess.run(["bash", str(self.root / "scripts/update-appcast.sh"), str(self.archive), URL],
                              env=self.env, capture_output=True, text=True)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def check_refused_before_signing(self, result):
        self.assertNotEqual(result.returncode, 0)
        names = [call[0] for call in self.calls()]
        self.assertNotIn("generate_appcast", names)
        self.assertNotIn("curl", names)
        self.assertEqual(self.feed.read_text(), "<rss><!-- the feed already published --></rss>\n")

    def test_a_stapled_archive_is_verified_from_a_clean_extraction_then_signed_and_published(self):
        self.build_archive()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        names = [call[0] for call in calls]
        signing = names.index("generate_appcast")
        for check in ("codesign", "xcrun", "spctl", "curl"):
            self.assertLess(names.index(check), signing, f"{check} must precede signing")
        extracted = {call[-1] for call in calls if call[0] in ("codesign", "xcrun", "spctl")}
        self.assertEqual(len(extracted), 1, "Every check reads the same clean extraction")
        self.assertTrue(extracted.pop().endswith("/extracted/RelayBar.app"))
        codesign = next(call for call in calls if call[0] == "codesign")
        self.assertIn('-R==anchor apple generic and identifier "fixture.RelayBar" and '
                      'certificate leaf[subject.OU] = "ABCDE12345"', codesign)
        feed_checks = [call for call in calls if call[:2] == ["sign_update", "--account"] and len(call) == 5]
        self.assertEqual(len(feed_checks), 1)
        self.assertNotEqual(feed_checks[0][-1], str(self.feed), "The staged feed is verified, not the repository's")
        self.assertLess(names.index("generate_keys"), signing, "The signing key is checked before signing")
        self.assertIn(f'url="{URL}"', self.feed.read_text())
        self.assertEqual(sorted(path.name for path in self.feed.parent.iterdir()), ["appcast.xml"])
        self.assertEqual(result.stdout.splitlines()[-1], str(self.feed))

    def test_an_unstapled_archive_is_refused_before_signing(self):
        self.build_archive(stapled=False)
        result = self.run_script()
        self.check_refused_before_signing(result)
        self.assertIn("no ticket is stapled", result.stderr)

    def test_another_app_identity_is_refused_before_signing(self):
        self.build_archive(CFBundleIdentifier="fixture.Other")
        result = self.run_script()
        self.check_refused_before_signing(result)
        self.assertIn("failed to satisfy", result.stderr)

    def test_another_team_is_refused_before_signing(self):
        self.build_archive(team="ZYXWV98765")
        result = self.run_script()
        self.check_refused_before_signing(result)
        self.assertIn("failed to satisfy", result.stderr)

    def test_a_signing_key_or_updater_setting_that_differs_is_refused_before_signing(self):
        cases = (({"FIXTURE_KEYCHAIN_KEY": "another-key"}, {}, "Keychain signing key does not match"),
                 ({}, {"SUPublicEDKey": "another-key"}, "SUPublicEDKey differs"),
                 ({}, {"SUFeedURL": "https://example.invalid/appcast.xml"}, "SUFeedURL differs"))
        for env, changes, message in cases:
            with self.subTest(message):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                self.build_archive(**changes)
                self.env.update(env)
                result = self.run_script()
                for name in env:
                    self.env.pop(name)
                self.check_refused_before_signing(result)
                self.assertIn(message, result.stderr)

    def test_a_failed_copy_leaves_the_previous_feed_intact(self):
        self.build_archive()
        self.env["FAIL_FEED_COPY"] = "1"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No space left on device", result.stderr)
        self.assertEqual(self.feed.read_text(), "<rss><!-- the feed already published --></rss>\n")
        self.assertEqual(sorted(path.name for path in self.feed.parent.iterdir()), ["appcast.xml"])

    def test_a_failed_feed_verification_leaves_the_repository_feed_untouched(self):
        self.build_archive()
        self.env["FAIL_FEED_VERIFY"] = "1"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generate_appcast", [call[0] for call in self.calls()])
        self.assertIn("feed signature is invalid", result.stderr)
        self.assertEqual(self.feed.read_text(), "<rss><!-- the feed already published --></rss>\n")

    def test_publication_guard_precedes_everything(self):
        self.build_archive()
        self.env.pop("RELAYBAR_PUBLICATION_APPROVED")
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
