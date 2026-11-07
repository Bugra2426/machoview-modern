#!/usr/bin/env python3
"""Test publication gates/asset selection with a local gh stub; no network calls."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/publish-release.sh"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="machoview-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "downloaded artifacts"
        self.dist = self.root / "release output"
        self.log = self.root / "gh-arguments.json"
        tools = self.root / "bin"
        tools.mkdir()
        gh = tools / "gh"
        gh.write_text("#!/usr/bin/env python3\n"
                      "import json, os, pathlib, sys\n"
                      "pathlib.Path(os.environ['GH_ARGUMENT_LOG']).write_text(json.dumps(sys.argv[1:]))\n"
                      "sys.exit(int(os.environ.get('FAKE_GH_EXIT', '0')))\n")
        gh.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "GH_ARGUMENT_LOG": str(self.log),
            "GH_REPO": "example/test",
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_NUMBER": "42",
            "DEFAULT_BRANCH": "main",
            "RELEASE_VERSION": "2.5.0",
        }
        self.names = []
        for baseline in ("macos-15", "macos-26"):
            directory = self.source / f"MachOView-{baseline}-universal"
            directory.mkdir(parents=True)
            for extension in ("dmg", "zip"):
                name = f"MachOView-2.5.0-{baseline}-universal.{extension}"
                (directory / name).write_bytes(name.encode())
                self.names.append(name)

    def shell_command(self):
        # Exercise Apple's system Bash on macOS, not a Homebrew shell from PATH.
        return ["/bin/bash", str(SCRIPT), str(self.source), str(self.dist)]

    def publish(self, **environment):
        return subprocess.run(self.shell_command(),
                              env={**self.environment, **environment},
                              capture_output=True, text=True, check=False)

    def arguments(self):
        return json.loads(self.log.read_text())

    def test_main_push_publishes_preview_with_four_assets_and_checksums(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.arguments()
        self.assertEqual(args[:3], ["release", "create", "build-42"])
        self.assertIn("--prerelease", args)
        self.assertIn("--latest=false", args)
        self.assertEqual(args[args.index("--target") + 1], "a" * 40)
        self.assertNotIn("--clobber", args)
        for name in self.names:
            self.assertIn(str(self.dist / name), args)
        checksums = (self.dist / "SHA256SUMS.txt").read_text().splitlines()
        self.assertEqual(len(checksums), 4)
        for line in checksums:
            digest, filename = line.split(maxsplit=1)
            self.assertEqual(digest, hashlib.sha256((self.dist / filename).read_bytes()).hexdigest())

    def test_version_tag_publishes_stable_release(self):
        result = self.publish(GITHUB_REF="refs/tags/v2.5.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.arguments()
        self.assertEqual(args[:3], ["release", "create", "v2.5.0"])
        self.assertIn("--verify-tag", args)
        self.assertNotIn("--prerelease", args)
        self.assertNotIn("--target", args)

    def test_other_default_branch_supported(self):
        result = self.publish(GITHUB_REF="refs/heads/trunk", DEFAULT_BRANCH="trunk")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_non_release_events_and_refs_rejected(self):
        cases = (
            {"GITHUB_EVENT_NAME": "pull_request"},
            {"GITHUB_EVENT_NAME": "workflow_dispatch"},
            {"GITHUB_REF": "refs/heads/feature"},
            {"GITHUB_REF": "refs/tags/arbitrary"},
            {"GITHUB_REF": "refs/tags/v2.5.0-extra"},
            {"GITHUB_REF": "refs/tags/v2.5.1"},
            {"RELEASE_VERSION": "2.5.0; echo unsafe"},
            {"GITHUB_SHA": "main"},
            {"GITHUB_RUN_NUMBER": "not-a-number"},
        )
        for index, case in enumerate(cases):
            with self.subTest(case=case):
                # Isolate failures: one accidentally accepted case must not leave
                # output/log files that make every later rejection look broken.
                self.dist = self.root / f"rejected-output-{index}"
                self.log = self.root / f"rejected-gh-{index}.json"
                self.environment["GH_ARGUMENT_LOG"] = str(self.log)
                result = self.publish(**case)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.log.exists())
                self.assertFalse(self.dist.exists())

    def test_invalid_version_rejected_before_asset_lookup(self):
        result = self.publish(RELEASE_VERSION="2.5.0-extra")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RELEASE_VERSION must use MAJOR.MINOR.PATCH", result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.dist.exists())

    def test_missing_source_directory_reports_error(self):
        self.source = self.root / "missing-artifacts"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Downloaded artifact directory does not exist", result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.dist.exists())

    def test_missing_one_os_dmg_prevents_publication(self):
        (self.source / "MachOView-macos-26-universal" / "MachOView-2.5.0-macos-26-universal.dmg").unlink()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing tested release asset", result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.dist.exists())

    def test_empty_asset_prevents_publication(self):
        (self.source / "MachOView-macos-15-universal" / "MachOView-2.5.0-macos-15-universal.zip").write_bytes(b"")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_existing_output_preserved(self):
        self.dist.mkdir()
        marker = self.dist / "keep.txt"
        marker.write_text("untouched")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertEqual(marker.read_text(), "untouched")
        self.assertFalse(self.log.exists())

    def test_github_failure_propagates(self):
        result = self.publish(FAKE_GH_EXIT="17")
        self.assertEqual(result.returncode, 17)
        self.assertNotIn("--clobber", self.arguments())


class ReleaseWithoutErrexitTests(ReleaseTests):
    """Validation must explicitly fail, independent of Bash's errexit rules.

    Bash 3.2 on macOS does not apply errexit to bare [[ ... ]] like modern
    Bash does. Sourcing in an if condition suppresses errexit on modern Bash
    too, exposing reliance on implicit exits without downloading an old shell.
    This is additional coverage, not a claim to emulate all Bash 3.2 behavior.
    """

    def shell_command(self):
        return ["/bin/bash", "-c",
                'if source "$1" "$2" "$3"; then exit 0; else exit "$?"; fi',
                "release-test", str(SCRIPT), str(self.source), str(self.dist)]


if __name__ == "__main__":
    unittest.main()
