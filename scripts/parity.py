#!/usr/bin/env python3
"""Report the source inventory and test wiring documented in the UX parity ledger."""

import re
import sys
from pathlib import Path

LEDGER = Path(__file__).resolve().parents[1] / "docs/system-specs/shared/ux-parity.md"


def selected_cases(source, loop):
    """Read the quoted case names in the test's literal Swift array."""
    match = re.search(re.escape(loop) + r"\s*\[([^\]]*)\]", source)
    if not match:
        print(f"Fixture loop missing: {loop}", file=sys.stderr)
        return set()
    return set(re.findall(r'"([^"]+)"', match[1]))


def main():
    ledger = LEDGER.read_text()
    sources = {}
    paths = {}
    missing = False
    for label, relative in re.findall(r"^\[([^\]]+)\]: (.+)$", ledger, re.MULTILINE):
        path = LEDGER.parent / relative
        paths[label] = path
        if path.is_file():
            sources[label] = path.read_text()
        else:
            print(f"Missing ledger file: {relative}", file=sys.stderr)
            sources[label] = ""
            missing = True

    definitions = outstanding = 0
    for line in ledger.splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) == 7 and cells[5] == "To fix":
            outstanding += 1
        if cells[0] in {"Table", "Palette", "PNG", "Limit"}:
            label = cells[1].strip("[]")
            for excerpt in re.findall(r"`([^`]+)`", cells[2]):
                if excerpt in sources[label]:
                    definitions += 1
                else:
                    print(f"Missing definition in {label}: {excerpt}", file=sys.stderr)

    groups = re.findall(r'\.init\(\s*name:\s*"([^"]+)"', sources["Grouping fixtures"])
    wired = ("in CompanionGroupingFixture.all" in sources["Mac grouping test"]
             and "arguments: CompanionGroupingFixture.all" in sources["Mobile grouping test"])
    pages = {p.stem for p in paths["ordinary"].parent.glob("*.html")}
    mac = selected_cases(sources["Mac Markdown test"], "for (name, source) in")
    mobile = selected_cases(sources["Mobile Markdown test"], "for name in")
    covered = (len(groups) if wired else 0) + len(pages & mac & mobile)
    fixtures = f"{covered}/{len(groups) + len(pages)}"
    print(f"Definitions outside AppComposition: {definitions}")
    print(f"Shared fixture cases covered: {fixtures}")
    print(f"Ledger rows to fix: {outstanding}")
    print(f"Total: {definitions} definitions, {fixtures} fixture cases, {outstanding} rows to fix")
    return int(missing)


if __name__ == "__main__":
    sys.exit(main())
