#!/usr/bin/env python3
"""Portable regression tests for Xcode's compiler/Metal toolchain selection."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/find-llvm.sh"


class FindLLVMTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="machoview-xcode-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.developer = self.root / "Xcode 26.app/Contents/Developer"
        self.compiler = self.developer / "Toolchains/XcodeDefault.xctoolchain"
        self.metal = self.root / "Metal.xctoolchain"
        self.environment = {key: value for key, value in os.environ.items()
                            if key not in ("DT_TOOLCHAIN_DIR", "TOOLCHAIN_DIR", "DEVELOPER_DIR", "TOOLCHAINS")}

    def library(self, toolchain):
        library = toolchain / "usr/lib/libLTO.dylib"
        library.parent.mkdir(parents=True, exist_ok=True)
        library.write_bytes(b"test fixture, not an executable")
        return library

    def run_resolver(self, **settings):
        return subprocess.run(["bash", str(SCRIPT)], env={**self.environment, **settings},
                              text=True, capture_output=True, check=False)

    def test_xcode_26_metal_first(self):
        expected = self.library(self.compiler)
        self.library(self.metal)  # Never choose Metal, even if it gains a libLTO.
        result = self.run_resolver(DT_TOOLCHAIN_DIR=str(self.compiler),
                                   TOOLCHAIN_DIR=str(self.metal), DEVELOPER_DIR=str(self.developer),
                                   TOOLCHAINS="com.apple.dt.toolchain.Metal com.apple.dt.toolchain.XcodeDefault")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(expected))

    def test_older_xcode(self):
        expected = self.library(self.compiler)
        result = self.run_resolver(DT_TOOLCHAIN_DIR=str(self.compiler), TOOLCHAIN_DIR=str(self.compiler))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(expected))

    def test_selected_xcode_fallback(self):
        expected = self.library(self.compiler)
        for override in ({}, {"DT_TOOLCHAIN_DIR": str(self.metal)}):
            with self.subTest(override=override):
                result = self.run_resolver(DEVELOPER_DIR=str(self.developer), **override)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(expected))

    def test_missing_compiler_library_fails_without_metal_fallback(self):
        self.library(self.metal)
        result = self.run_resolver(DT_TOOLCHAIN_DIR=str(self.compiler),
                                   DEVELOPER_DIR=str(self.developer), TOOLCHAIN_DIR=str(self.metal))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("No libLTO", result.stderr)

    def test_unset_environment_fails_clearly(self):
        result = self.run_resolver()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Select a full Xcode", result.stderr)


if __name__ == "__main__":
    unittest.main()
