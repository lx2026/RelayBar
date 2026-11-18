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
    assert (pathlib.Path(args[-1]) / "Contents/Info.plist").is_file()
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
    print("fixture-public-key")
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
        for name in ("ditto", "codesign", "xcrun", "spctl", "curl"):
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
        (self.root / "docs").mkdir()
        self.feed = self.root / "docs/appcast.xml"
        self.feed.write_text("<rss><!-- the feed already published --></rss>\n")
        (self.root / "published").mkdir()
        self.archive = self.root / "RelayBar.zip"
        self.env = {**os.environ, "PATH": str(bin_path) + os.pathsep + os.environ["PATH"],
                    "FIXTURE_ROOT": str(self.root), "SPARKLE_BIN": str(sparkle),
                    "RELAYBAR_PUBLICATION_APPROVED": "yes"}
        self.env.pop("FAIL_FEED_VERIFY", None)
        self.env.pop("SPARKLE_ACCOUNT", None)

    def build_archive(self, stapled=True, **changes):
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("RelayBar.app/Contents/Info.plist", plistlib.dumps({**self.metadata, **changes}))
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
        feed_checks = [call for call in calls if call[:2] == ["sign_update", "--account"] and len(call) == 5]
        self.assertEqual(len(feed_checks), 1)
        self.assertNotEqual(feed_checks[0][-1], str(self.feed), "The staged feed is verified, not the repository's")
        self.assertIn(f'url="{URL}"', self.feed.read_text())
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
        self.assertIn("CFBundleIdentifier", result.stderr)

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
