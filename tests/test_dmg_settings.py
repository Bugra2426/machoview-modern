#!/usr/bin/env python3
"""Standard-library-only checks; never import or execute dmgbuild or a macOS app.

Run on Linux or macOS: python3 -I tests/test_dmg_settings.py
These are authoring/configuration checks, not a substitute for a macOS DMG build.
"""
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "scripts/dmg-settings.py"
PACKAGE = ROOT / "scripts/package-dmg.sh"


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dmg settings ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "MachOView.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_text("fixture, not a real app")
        (self.app / "Contents/MacOS/MachOView").write_text("fixture, never executed")
        self.background = self.root / "background.tiff"
        self.background.write_bytes(b"fixture, no image decoder used")
        self.defines = {"app": str(self.app), "background": str(self.background)}

    def load_settings(self, defines=None):
        return runpy.run_path(str(SETTINGS), init_globals={
            "defines": self.defines if defines is None else defines,
        })

    def test_layout_and_compression(self):
        settings = self.load_settings()
        self.assertEqual(settings["format"], "UDZO")
        self.assertEqual(settings["filesystem"], "HFS+")
        self.assertEqual(settings["files"], [(str(self.app), "MachOView.app")])
        self.assertEqual(settings["symlinks"], {"Applications": "/Applications"})
        self.assertEqual(settings["background"], str(self.background))
        self.assertEqual(settings["default_view"], "icon-view")
        self.assertTrue(settings["include_icon_view_settings"])
        self.assertFalse(settings["include_list_view_settings"])
        self.assertIsNone(settings["arrange_by"])
        self.assertEqual(settings["icon_locations"], {
            "MachOView.app": (170, 208), "Applications": (510, 208),
        })
        for flag in ("show_toolbar", "show_status_bar", "show_tab_view",
                     "show_pathbar", "show_sidebar", "show_icon_preview"):
            self.assertFalse(settings[flag], flag)
        # No alternate icon, optional badge renderer, signing, or licensing hook.
        self.assertNotIn("icon", settings)
        self.assertNotIn("badge_icon", settings)
        self.assertNotIn("license", settings)

    def test_artwork_canvas_matches_finder_window(self):
        settings = self.load_settings()
        width, height = settings["window_rect"][1]
        artwork = (ROOT / "packaging/dmg-background.swift").read_text()
        self.assertIn(f"let canvasSize = NSSize(width: {width}, height: {height})", artwork)
        self.assertLess(settings["icon_locations"]["MachOView.app"][0], width / 2)
        self.assertGreater(settings["icon_locations"]["Applications"][0], width / 2)

    def test_explicit_swift_toolchain(self):
        script = PACKAGE.read_text()
        invocations = [line for line in script.splitlines() if "/usr/bin/xcrun " in line]
        self.assertEqual(len(invocations), 2)
        for invocation in invocations:
            self.assertIn("--toolchain com.apple.dt.toolchain.XcodeDefault", invocation)
            self.assertIn("--sdk macosx", invocation)

    def test_no_unsupported_dmgbuild_version_option(self):
        script = PACKAGE.read_text()
        commands = "\n".join(line for line in script.splitlines()
                             if not line.lstrip().startswith("#"))
        self.assertNotIn("--version", commands)

    def test_missing_defines(self):
        with self.assertRaisesRegex(ValueError, "Load these settings"):
            runpy.run_path(str(SETTINGS))

    def test_missing_parameters(self):
        for name in self.defines:
            with self.subTest(name=name):
                defines = dict(self.defines)
                del defines[name]
                with self.assertRaisesRegex(ValueError, "Missing -D"):
                    self.load_settings(defines)

    def test_nonstring_parameters(self):
        for value in (None, False, 42, Path("background.tiff")):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "Missing -D"):
                    self.load_settings(dict(self.defines, background=value))

    def test_relative_and_nonexistent_parameters(self):
        for value in ("relative.tiff", str(self.root / "missing.tiff")):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "existing absolute path"):
                    self.load_settings(dict(self.defines, background=value))

    def test_wrong_bundle_name(self):
        other = self.root / "Other.app"
        other.mkdir()
        with self.assertRaisesRegex(ValueError, "MachOView.app directory"):
            self.load_settings(dict(self.defines, app=str(other)))

    def test_directory_background(self):
        with self.assertRaisesRegex(ValueError, "image file"):
            self.load_settings(dict(self.defines, background=str(self.root)))

    def run_package(self, *args):
        # All tested branches return before macOS/dependency detection. Execute
        # only our shell code; never provide a valid build request in these tests.
        return subprocess.run(["/bin/bash", str(PACKAGE), *map(str, args)],
                              text=True, capture_output=True, check=False)

    def test_help_without_dependencies(self):
        result = self.run_package("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dmgbuild==1.6.7", result.stdout)
        self.assertIn("No notarization", result.stdout)

    def test_argument_count(self):
        for args in ((), ("only-one",), ("1", "2", "3", "4")):
            with self.subTest(args=args):
                result = self.run_package(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage:", result.stderr)

    def test_invalid_architecture(self):
        result = self.run_package(self.app, self.root / "test.dmg", "invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ARCH must be", result.stderr)

    def test_existing_output_is_not_changed(self):
        output = self.root / "existing.dmg"
        output.write_bytes(b"keep this")
        result = self.run_package(self.app, output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing existing output", result.stderr)
        self.assertEqual(output.read_bytes(), b"keep this")

    def test_dangling_output_symlink_is_not_changed(self):
        output = self.root / "existing.dmg"
        output.symlink_to(self.root / "absent-target")
        result = self.run_package(self.app, output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing existing output", result.stderr)
        self.assertTrue(output.is_symlink())

    def test_wrong_output_suffix(self):
        result = self.run_package(self.app, self.root / "test.zip")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OUTPUT must end in .dmg", result.stderr)

    def test_symlink_app_is_rejected(self):
        link = self.root / "Symlink.app"
        link.symlink_to(self.app, target_is_directory=True)
        result = self.run_package(link, self.root / "test.dmg")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a symlink", result.stderr)

    def test_newline_path_is_rejected(self):
        result = self.run_package(self.app, self.root / "bad\nname.dmg")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Paths must not contain newlines", result.stderr)


if __name__ == "__main__":
    unittest.main()
