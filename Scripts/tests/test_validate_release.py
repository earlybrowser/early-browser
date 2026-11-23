# SPDX-License-Identifier: MPL-2.0

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "validate-release.py"


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="Early release validation ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.repo, self.tag, self.version = "owner/early-fixture", "v9.8.7", "9.8.7"
        self.zip_name = f"Early-{self.version}.zip"
        self.zip_bytes = b"fixture release archive"
        self.checksum = hashlib.sha256(self.zip_bytes).hexdigest()
        self.metadata = {
            "tag_name": self.tag, "draft": False, "prerelease": False, "published_at": "2026-11-22T00:00:00Z",
            "assets": [{"name": name, "state": "uploaded", "size": 20}
                       for name in (self.zip_name, "SHA256SUMS", "appcast.xml")],
        }
        (self.directory / self.zip_name).write_bytes(self.zip_bytes)
        (self.directory / "SHA256SUMS").write_text(f"{self.checksum}  {self.zip_name}\n", encoding="ascii")
        gh = self.directory / "gh"
        gh.write_text("#!/usr/bin/env python3\n" + textwrap.dedent("""\
            import os
            from pathlib import Path
            import shutil
            import sys

            root = Path(os.environ["EARLY_RELEASE_FIXTURE"])
            args = sys.argv[1:]
            repo, tag = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_REF_NAME"]
            if args == ["api", f"repos/{repo}/releases/tags/{tag}"]:
                metadata = root / "release.json"
                if not metadata.exists():
                    sys.exit("release not found")
                print(metadata.read_text())
            elif args[:3] == ["release", "download", tag] and args[args.index("--repo") + 1] == repo:
                destination = Path(args[args.index("--dir") + 1])
                for index, arg in enumerate(args):
                    if arg == "--pattern":
                        shutil.copyfile(root / args[index + 1], destination / args[index + 1])
                (root / "downloaded").touch()
            else:
                sys.exit("unexpected gh call")
            """))
        gh.chmod(0o700)

    def validate(self, event="workflow_dispatch", ref_type="tag", tag=None):
        metadata = self.directory / "release.json"
        if self.metadata is not None:
            metadata.write_text(json.dumps(self.metadata))
        else:
            metadata.unlink(missing_ok=True)
        (self.directory / "downloaded").unlink(missing_ok=True)
        env = {"PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}",
               "GITHUB_REPOSITORY": self.repo, "GITHUB_REF_NAME": tag or self.tag,
               "GITHUB_REF_TYPE": ref_type, "GITHUB_EVENT_NAME": event, "EARLY_RELEASE_FIXTURE": str(self.directory)}
        return subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True)

    def assert_rejected(self, result, reason):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn(reason, result.stderr)

    def test_both_triggers_validate_the_same_stable_release(self):
        for event in ("release", "workflow_dispatch", "workflow_dispatch"):
            with self.subTest(event=event):
                result = self.validate(event=event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"version={self.version}\nsha256={self.checksum}\n")

    def test_rejects_draft_prerelease_unpublished_and_wrong_tag_before_downloading(self):
        for field, invalid in (("draft", True), ("prerelease", True), ("published_at", None), ("tag_name", "v9.8.6")):
            with self.subTest(field=field):
                original = self.metadata[field]
                self.metadata[field] = invalid
                self.assert_rejected(self.validate(), "published stable")
                self.assertFalse((self.directory / "downloaded").exists())
                self.metadata[field] = original

    def test_requires_a_published_release_for_the_exact_tag(self):
        self.metadata = None
        self.assert_rejected(self.validate(), "release not found")
        self.assert_rejected(self.validate(ref_type="branch"), "Choose a stable release tag")
        self.assert_rejected(self.validate(tag="v9.8.7-beta.1"), "Choose a stable release tag")

    def test_requires_all_uploaded_assets_for_the_selected_version(self):
        assets = self.metadata["assets"]
        for asset in assets:
            with self.subTest(asset=asset["name"]):
                self.metadata["assets"] = [entry for entry in assets if entry is not asset]
                self.assert_rejected(self.validate(), asset["name"])
                self.assertFalse((self.directory / "downloaded").exists())
        self.metadata["assets"] = [{**assets[0], "name": "Early-9.8.6.zip"}, *assets[1:]]
        self.assert_rejected(self.validate(), self.zip_name)

    def test_rejects_missing_malformed_duplicate_and_mismatched_checksums(self):
        for text in ("", f"invalid  {self.zip_name}\n", f"{self.checksum}  {self.zip_name}\n" * 2,
                     f"{self.checksum}  Early-9.8.6.zip\n"):
            with self.subTest(text=text):
                (self.directory / "SHA256SUMS").write_text(text, encoding="ascii")
                self.assert_rejected(self.validate(), "exactly one valid checksum")
        (self.directory / "SHA256SUMS").write_text(f"{'0' * 64}  {self.zip_name}\n", encoding="ascii")
        self.assert_rejected(self.validate(), "does not match the published ZIP")
