#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0

"""Prepare one version's Markdown highlights for GitHub or Sparkle."""

import argparse
from pathlib import Path
import re
from xml.sax.saxutils import escape


ROOT = Path(__file__).resolve().parent.parent
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?")
RELEASES = "https://github.com/earlybrowser/early-browser/releases/tag"


def release_notes(version, output_format):
    if not VERSION.fullmatch(version):
        raise ValueError("The version must look like 1.2.3 or 1.2.3-beta.1.")
    source = ROOT / "Packaging" / "ReleaseNotes" / f"{version}.md"
    if not source.is_file():
        raise ValueError(f"Add release highlights to {source} before releasing {version}.")
    highlights = source.read_text(encoding="utf-8").strip()
    if not highlights:
        raise ValueError(f"Release highlights are empty: {source}")
    if any((ord(char) < 32 and char not in "\n\r\t") or char in "\ufffe\uffff" for char in highlights):
        raise ValueError(f"Release highlights contain characters that XML cannot represent: {source}")

    if output_format == "appcast":
        # XML text, not CDATA: even notes containing ']]>' remain valid. Sparkle
        # decodes the text and renders Markdown with its native appearance.
        return escape(f"{highlights}\n\n[Full release notes]({RELEASES}/v{version})\n")

    install = (ROOT / "Packaging" / "install-notes.md").read_text(encoding="utf-8").strip()
    return f"{highlights}\n\n{install.replace('@VERSION@', version)}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--format", choices=["github", "appcast"], default="github")
    args = parser.parse_args()
    try:
        notes = release_notes(args.version, args.format)
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))
    print(notes, end="")


if __name__ == "__main__":
    main()
