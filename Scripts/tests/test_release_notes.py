# SPDX-License-Identifier: MPL-2.0

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="Early release notes ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir(parents=True)
        self.packaging = self.root / "Packaging"
        (self.packaging / "ReleaseNotes").mkdir(parents=True)
        for name in ["release.sh", "release-notes.py"]:
            shutil.copyfile(ROOT / "Scripts" / name, self.scripts / name)
        shutil.copyfile(ROOT / "Packaging" / "install-notes.md", self.packaging / "install-notes.md")
        self.version = "9.8.7-beta.1"
        self.source = self.packaging / "ReleaseNotes" / f"{self.version}.md"
        self.highlights = (
            "## Improvements\n\n"
            "- **Themes** & <colors> stay smooth — even with café tabs.\n"
            "- Keep `]]>` and `$(touch notes-executed)` as text.\n"
            "- [Details](https://example.invalid/notes?a=1&b=2)\n"
        )
        self.source.write_text(self.highlights, encoding="utf-8")

    def generate(self, output_format="github", version=None):
        return subprocess.run(
            [sys.executable, str(self.scripts / "release-notes.py"),
             version or self.version, "--format", output_format],
            capture_output=True, text=True, cwd=self.root,
        )

    def test_github_contains_highlights_and_versioned_install_instructions(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith(self.highlights.strip()))
        self.assertIn("## Install", result.stdout)
        self.assertIn(f"Early-{self.version}.zip", result.stdout)
        self.assertNotIn("@VERSION@", result.stdout)

    def test_sparkle_preserves_markdown_unicode_and_xml_special_characters(self):
        result = self.generate("appcast")
        self.assertEqual(result.returncode, 0, result.stderr)
        element = ET.fromstring(f"<description>{result.stdout}</description>")
        self.assertTrue(element.text.startswith(self.highlights.strip()))
        self.assertIn(f"[Full release notes](https://github.com/earlybrowser/early-browser/releases/tag/v{self.version})", element.text)
        self.assertNotIn("## Install", element.text)

    def test_changing_the_single_source_updates_both_outputs(self):
        self.source.write_text("## Fixes\n\n- Improved startup.\n", encoding="utf-8")
        for output_format in ["github", "appcast"]:
            with self.subTest(output_format=output_format):
                result = self.generate(output_format)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Improved startup.", result.stdout)
                self.assertNotIn("**Themes**", result.stdout)

    def test_missing_and_empty_notes_fail_with_an_actionable_error(self):
        self.source.unlink()
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Add release highlights", result.stderr)
        self.source.write_text(" \n\t", encoding="utf-8")
        result = self.generate("appcast")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("empty", result.stderr)

    def test_invalid_versions_are_rejected_before_resolving_a_notes_path(self):
        for version in ["../9.8.7", "v9.8.7", "9.8.7/notes", "9.8.7\nextra"]:
            with self.subTest(version=version):
                result = self.generate(version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("version must look like", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_invalid_utf8_and_xml_characters_fail_before_publishing(self):
        for data in [b"- Invalid \xff", b"- Invalid \x00", "- Invalid \ufffe".encode("utf-8")]:
            with self.subTest(data=data):
                self.source.write_bytes(data)
                result = self.generate("appcast")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def prepare_release(self):
        subprocess.run(["git", "init", "--quiet", "--template=", str(self.root)], check=True, capture_output=True)
        subprocess.run(
            ["git", "-c", "user.name=Release Tests", "-c", "user.email=release-tests@example.invalid",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
             "commit", "--quiet", "--allow-empty", "-m", "Test fixture"],
            cwd=self.root, check=True, capture_output=True,
        )
        output = self.root / "release output"
        tools = output / "DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
        tools.mkdir(parents=True)
        (output / f"Early-{self.version}.zip").write_bytes(b"synthetic update archive")
        (output / "BUILD_NUMBER").write_text("321\n")
        signer = tools / "sign_update"
        signer.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
assert sys.argv[1:3] == ["--ed-key-file", "-"]
assert sys.stdin.read() == "synthetic-test-key"
path = Path(sys.argv[3])
entry = {"name": path.name}
if path.suffix == ".xml":
    entry["unsigned_feed"] = path.read_text()
    path.write_text(entry["unsigned_feed"] + "<!-- fixture signer completed -->")
else:
    print(f'sparkle:edSignature="fixture-signature" length="{path.stat().st_size}"')
with open(os.environ["TEST_SIGN_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\\n")
''')
        signer.chmod(0o755)
        guards = self.root / "guards"
        guards.mkdir()
        builder = guards / "xcodebuild"
        builder.write_text('#!/bin/sh\ntouch "$TEST_BUILD_MARKER"\nexit 99\n')
        builder.chmod(0o755)
        environment = dict(os.environ, SPARKLE_ED_PRIVATE_KEY="synthetic-test-key",
            TEST_SIGN_LOG=str(output / "signing.jsonl"), TEST_BUILD_MARKER=str(output / "build-started"))
        environment["PATH"] = str(guards) + os.pathsep + environment["PATH"]
        return output, environment

    def test_appcast_embeds_notes_before_signing_and_keeps_update_metadata(self):
        output, environment = self.prepare_release()
        result = subprocess.run(
            ["bash", str(self.scripts / "release.sh"), self.version, "--appcast", "--output", str(output)],
            cwd=self.root, env=environment, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (output / "signing.jsonl").read_text().splitlines()]
        self.assertEqual([call["name"] for call in calls], [f"Early-{self.version}.zip", "appcast.xml"])
        item = ET.fromstring(calls[1]["unsigned_feed"]).find("channel/item")
        description = item.find("description")
        self.assertEqual(description.get(SPARKLE + "format"), "markdown")
        self.assertTrue(description.text.startswith(self.highlights.strip()))
        self.assertIn("Full release notes", description.text)
        self.assertEqual(item.findtext(SPARKLE + "version"), "321")
        self.assertEqual(item.findtext(SPARKLE + "shortVersionString"), self.version)
        self.assertEqual(item.findtext(SPARKLE + "minimumSystemVersion"), "14.0")
        self.assertTrue(item.findtext(SPARKLE + "fullReleaseNotesLink").endswith(f"/v{self.version}"))
        self.assertEqual(item.find("enclosure").get(SPARKLE + "edSignature"), "fixture-signature")
        self.assertIn("fixture signer completed", (output / "appcast.xml").read_text())
        self.assertFalse((self.root / "notes-executed").exists())
        self.assertFalse((output / "build-started").exists())

    def test_missing_notes_stop_before_build_cleanup_or_signing(self):
        output, environment = self.prepare_release()
        self.source.unlink()
        archive = output / f"Early-{self.version}.zip"
        for flags in [[], ["--appcast"]]:
            with self.subTest(flags=flags):
                result = subprocess.run(
                    ["bash", str(self.scripts / "release.sh"), self.version,
                     "--output", str(output)] + flags,
                    cwd=self.root, env=environment, capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Add release highlights", result.stderr)
                self.assertEqual(archive.read_bytes(), b"synthetic update archive")
                self.assertFalse((output / "signing.jsonl").exists())
                self.assertFalse((output / "build-started").exists())


if __name__ == "__main__":
    unittest.main()
