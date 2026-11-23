# SPDX-License-Identifier: MPL-2.0

"""Validate the release selected by either Homebrew workflow trigger."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def find_release(repo, tag, zip_name):
    response = subprocess.check_output(["gh", "api", f"repos/{repo}/releases/tags/{tag}"])
    release = json.loads(response)
    if (not isinstance(release, dict) or release.get("tag_name") != tag or release.get("draft") is not False
            or release.get("prerelease") is not False or not release.get("published_at")):
        raise ValueError(f"{tag} must be a published stable GitHub release.")

    for name in (zip_name, "SHA256SUMS", "appcast.xml"):
        matching = [asset for asset in release["assets"] if asset["name"] == name]
        if len(matching) != 1 or matching[0]["state"] != "uploaded" or matching[0]["size"] <= 0:
            raise ValueError(f"{tag} needs an uploaded {name} asset.")


def verified_checksum(directory, zip_name):
    manifest = (directory / "SHA256SUMS").read_text(encoding="ascii")
    rows = [line.split() for line in manifest.splitlines() if line.strip()]
    matches = [row for row in rows if row[-1].removeprefix("*") == zip_name]
    if len(matches) != 1 or len(matches[0]) != 2 or not re.fullmatch(r"[0-9a-fA-F]{64}", matches[0][0]):
        raise ValueError(f"SHA256SUMS must contain exactly one valid checksum for {zip_name}.")
    expected = matches[0][0].lower()

    digest = hashlib.sha256()
    with (directory / zip_name).open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError(f"The checksum for {zip_name} does not match the published ZIP.")
    return expected


def main():
    try:
        tag = os.environ["GITHUB_REF_NAME"]
        repo = os.environ["GITHUB_REPOSITORY"]
        if os.environ["GITHUB_REF_TYPE"] != "tag" or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
            raise ValueError("Choose a stable release tag such as v1.2.3.")
        version = tag[1:]
        zip_name = f"Early-{version}.zip"
        find_release(repo, tag, zip_name)
        with tempfile.TemporaryDirectory(prefix="early-release-") as directory:
            subprocess.run(["gh", "release", "download", tag, "--repo", repo, "--dir", directory,
                            "--pattern", "SHA256SUMS", "--pattern", zip_name], check=True, stdout=sys.stderr)
            checksum = verified_checksum(Path(directory), zip_name)
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release validation failed. {error}", file=sys.stderr)
        return 1

    print(f"version={version}")
    print(f"sha256={checksum}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
