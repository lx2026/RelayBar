#!/usr/bin/env python3
"""Describe one app's release locally. This command never tags, uploads or publishes."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent.parent
APPS = {
    "relaybar": ("RelayBar", "Apps/RelayBar/Packaging/Info.plist", "v"),
    "frame": ("Frame", "Apps/Frame/AppBundle/Info.plist", "frame-v"),
}


def plan(app, archive=None):
    name, relative_plist, prefix = APPS[app]
    metadata = plistlib.loads((ROOT / relative_plist).read_bytes())
    version = metadata["CFBundleShortVersionString"]
    tag = prefix + version
    result = {
        "app": name,
        "version": version,
        "build": metadata["CFBundleVersion"],
        "bundle_id": metadata["CFBundleIdentifier"],
        "repository": "lx2026/RelayBar",
        "tag": tag,
        "archive": name + ".zip",
        "download_url": f"https://github.com/lx2026/RelayBar/releases/download/{tag}/{name}.zip",
        "make_latest": app == "relaybar",
        "publication_authorized": False,
    }
    if app == "relaybar":
        result.update(
            feed=metadata["SUFeedURL"],
            install="brew install --cask lx2026/tap/relaybar",
            upgrade="brew upgrade --cask lx2026/tap/relaybar",
            tap="lx2026/homebrew-tap",
        )
    if archive is not None:
        archive = Path(archive)
        with zipfile.ZipFile(archive) as bundle:
            candidates = [n for n in bundle.namelist() if n.count("/") == 2 and n.endswith(".app/Contents/Info.plist")]
            if candidates != [f"{name}.app/Contents/Info.plist"]:
                raise ValueError("Archive must contain only the selected app at its root.")
            installed = plistlib.loads(bundle.read(candidates[0]))
            for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
                if installed[key] != metadata[key]:
                    raise ValueError(f"Archive {key} differs from the selected source metadata.")
        result["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        result["signing_verification_required"] = True
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", choices=APPS)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(plan(args.app, args.archive), indent=2))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Release plan rejected: {error}\n")
