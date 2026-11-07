#!/usr/bin/env python3
"""Exercise bundle verification with fake macOS tools; no native execution.

Only absolute tool paths are substituted in a temporary copy of the real script.
Fixtures describe slices/dependencies; these tests do not claim to sign or parse
real Mach-O files. CI performs those checks with Apple's tools on both CPUs.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["VERIFY_TOOL_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if name in ("codesign", "plutil"):
    sys.exit(0)
path = pathlib.Path(args[0] if name == "lipo" else args[-1])
try:
    fixture = json.loads(path.read_text())
except (ValueError, OSError):
    fixture = {}
if name == "file":
    print("Mach-O universal binary" if "archs" in fixture else "ASCII text")
elif name == "lipo":
    assert args[1] == "-verify_arch", args
    missing = set(args[2:]) - set(fixture.get("archs", []))
    if missing:
        print("Missing slices: " + ", ".join(sorted(missing)), file=sys.stderr)
        sys.exit(1)
elif name == "otool":
    assert args[:3] == ["-arch", "all", "-L"], args
    if fixture.get("otool_error"):
        sys.exit(9)
    for arch in fixture["archs"]:
        print(str(path) + " (architecture " + arch + "):")
        for library in fixture.get("dependencies", {}).get(arch, ["/usr/lib/libSystem.B.dylib"]):
            print("\\t" + library + " (compatibility version 1.0.0)")
else:
    raise AssertionError(name)
'''


class VerifyAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="machoview-verify-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "MachOView.app"
        self.executable = self.app / "Contents/MacOS/MachOView"
        self.backend = self.app / "Contents/Frameworks/libLTO.dylib"
        self.helper = self.app / "Contents/Helpers/helper"
        for binary in (self.executable, self.backend, self.helper):
            binary.parent.mkdir(parents=True, exist_ok=True)
            self.fixture(binary)
        (self.app / "Contents/Info.plist").write_text("fixture")
        self.log = self.root / "tools.jsonl"
        tools = self.root / "tools"
        tools.mkdir()
        script = (ROOT / "scripts/verify-app.sh").read_text()
        for name in ("lipo", "otool", "codesign", "plutil", "file"):
            tool = tools / name
            tool.write_text(TOOL)
            tool.chmod(0o755)
            script = script.replace("/usr/bin/" + name, str(tool))
        self.script = self.root / "verify-app.sh"
        self.script.write_text(script)

    def fixture(self, path, archs=("arm64", "x86_64"), **extra):
        path.write_text(json.dumps({"archs": list(archs), **extra}))

    def verify(self, *arguments):
        return subprocess.run(["/bin/bash", str(self.script), str(self.app), *arguments],
                              env={**os.environ, "VERIFY_TOOL_LOG": str(self.log)},
                              capture_output=True, text=True, check=False)

    def test_default_requires_both_slices_for_every_binary(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        lipo = [call for call in calls if call[0] == "lipo"]
        for path in (self.executable, self.backend, self.helper):
            self.assertIn(["lipo", str(path), "-verify_arch", "arm64", "x86_64"], lipo)
        inspected = [call[-1] for call in calls if call[0] == "otool"]
        self.assertEqual(set(inspected), {str(self.executable), str(self.backend), str(self.helper)})
        self.assertIn("Verified universal", result.stdout)

    def test_arm64_only_app_rejected_as_universal(self):
        self.fixture(self.executable, ("arm64",))
        result = self.verify("universal")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("x86_64", result.stderr)

    def test_intel_only_app_rejected_as_universal(self):
        self.fixture(self.executable, ("x86_64",))
        result = self.verify("universal")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("arm64", result.stderr)

    def test_thin_backend_rejected(self):
        self.fixture(self.backend, ("arm64",))
        self.assertNotEqual(self.verify().returncode, 0)

    def test_hidden_thin_helper_rejected(self):
        self.fixture(self.helper, ("arm64",))
        self.assertNotEqual(self.verify().returncode, 0)

    def test_unbundled_intel_dependency_rejected(self):
        self.fixture(self.backend, dependencies={"x86_64": ["/opt/builder/libMissing.dylib"]})
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unbundled dependency", result.stderr)

    def test_otool_failure_not_silently_ignored(self):
        self.fixture(self.backend, otool_error=True)
        self.assertNotEqual(self.verify().returncode, 0)

    def test_single_arch_local_builds_remain_supported(self):
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch):
                for binary in (self.executable, self.backend, self.helper):
                    self.fixture(binary, (arch,))
                result = self.verify(arch)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_architecture_rejected_before_tools(self):
        result = self.verify("not-an-architecture")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
