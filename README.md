# MachOView — universal macOS build

MachOView is a Cocoa viewer for Mach-O executables, object files, universal binaries, and static archives. This modernization replaces the Intel-only build inputs with source-built disassembly code and a native LLVM backend, and adds tested-build packaging and GitHub Releases.

## Requirements and compatibility

- **Apple Silicon or Intel, macOS 15 or later** for the baseline CI build.
- Each download contains one **Universal 2 app** with both `arm64` and `x86_64` slices, including its bundled LLVM backend. The same app runs natively on either CPU.
- The separate **macOS 26** build uses that runner's Xcode/SDK and requires macOS 26 or later. Your Intel Mac must support the chosen macOS version; universal packaging does not lower the OS requirement.
- **No Rosetta:** Apple Silicon runs the ARM64 slice, while Intel runs the x86_64 slice. CI tests both on native hardware, not through translation.
- Local development needs full Xcode (not only Command Line Tools), with the selected compiler toolchain providing both slices in `libLTO.dylib`.

The Xcode project uses the selected `macosx` SDK, C++17/libc++, and standard architectures. CI explicitly builds `ARCHS="arm64 x86_64"` with `ONLY_ACTIVE_ARCH=NO` and rejects any bundled Mach-O that lacks either slice. It will not silently publish an ARM-only app as universal.

## Interface, SDK, and Dark Mode

**A modern SDK does not automatically redesign the interface.** This fork focuses on native Apple Silicon support, build compatibility, performance, and reliability while retaining MachOView's classic interface.

- **Layout:** the existing navigation tree, detail tables, hex view, and disassembly presentation remain. This is not a complete visual redesign.
- **Native controls:** standard AppKit windows, menus, and controls can adopt the styling provided by the macOS version running the app. Their exact appearance also depends on the control styles and interface files; not every element automatically gains the newest visual effects.
- **SDK selection:** `SDKROOT = macosx` uses the SDK in the selected Xcode installation, not necessarily the newest Xcode available. Building with a newer SDK does not give macOS 15 the appearance or features of macOS 26. The deployment target separately controls the minimum supported OS.
- **Dark Mode is partial and not visually verified:** standard controls using system colors are expected to follow the system appearance, but custom table highlights, separators, and colored text still include fixed colors that may have poor contrast. There is no in-app Light / Dark / System selector.

A full appearance update would require adaptive custom colors, contrast and selection checks in both themes, and deliberate sidebar, toolbar, spacing, and typography changes. Those UI changes are **not included in this modernization**. Hands-on testing on macOS is still needed before claiming complete Dark Mode support.

## Downloading a build

Open **[GitHub Releases](https://github.com/Bugra2426/machoview-modern/releases)** for installable downloads. Successful pushes to `main` publish **preview releases** automatically; version tags publish **stable releases**. Both universal-build jobs and both native Intel-test jobs must pass before either kind of release is published.

Each release includes:

- `MachOView-VERSION-macos-15-universal.dmg` — for macOS 15 or later.
- `MachOView-VERSION-macos-26-universal.dmg` — for macOS 26 or later.
- Matching `.zip` alternatives and a combined `SHA256SUMS.txt` covering all four downloads.

The DMG uses a custom installation background, arranged icons, and an **Applications** shortcut. It installs no privileged helper and does not run an installer script.

1. Download the DMG for your macOS version and verify its SHA-256 against the release checksums.
2. Open the DMG and drag **MachOView** onto **Applications**. Eject the disk image, then launch the app from Applications. For a ZIP, extract `MachOView.app` and move it to Applications yourself.
3. The app is **ad-hoc signed, not Developer ID signed or Apple notarized**. A DMG does not remove Gatekeeper warnings or confer publisher verification. Only if you trust the source and have verified the download, use the app-specific **System Settings → Privacy & Security → Open Anyway** option, if offered. Do not disable Gatekeeper globally.

**Actions → Native macOS build → Artifacts** also contains the DMG/ZIP bundles and checksums, with separate build and packaging logs. Pull requests, non-default branches, and manual runs produce artifacts only; they do not publish releases.

Ad-hoc signing provides local code-signature integrity, not publisher verification. Uninterrupted public distribution needs a Developer ID signing/notarization setup; no Apple credentials are required or used by this workflow.

## Build locally on a Mac

Select a full Xcode installation first, then:

```sh
xcodebuild -project machoview.xcodeproj -scheme MachOView \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build

bash scripts/verify-app.sh build/DerivedData/Build/Products/Release/MachOView.app universal
build/DerivedData/Build/Products/Release/MachOView.app/Contents/MacOS/MachOView --self-test
```

The build compiles `otool_disasm/*.c` (excluding the duplicate `symbol.c`) directly into the app. It copies `libLTO.dylib` from the **selected Xcode compiler toolchain** into `Contents/Frameworks`, rejects missing architecture slices or non-system dependencies, and signs the nested library before the app. The distributed app loads only its bundled library; the recipient does not need Xcode or Homebrew.

**Xcode 26 toolchain selection:** Xcode can set `TOOLCHAIN_DIR` to its Metal toolchain, which does not contain the compiler's `libLTO.dylib`. `scripts/find-llvm.sh` instead checks `DT_TOOLCHAIN_DIR`, then `XcodeDefault.xctoolchain` under that build's `DEVELOPER_DIR`. It never falls back to the historical Intel library or an unrelated Xcode installation. Missing compiler LLVM still fails the build with a diagnostic.

The historical root `libdisasm.a` and `lib/libLTO.dylib` remain in the repository for provenance, but **neither is used or packaged**. Use the root project/shared scheme, not the historical disassembler subproject. `createdmg` now forwards to the new packaging script and requires an already-built app.

The default deployment target is 15.0. If using a newer toolchain whose bundled LLVM requires a newer OS, raise `MACOSX_DEPLOYMENT_TARGET` accordingly and test on that OS. CI keeps separate macOS 15 and 26 builds so each baseline is actually exercised.

### Create the DMG locally

After building and testing the app, use Python 3.10+ and install the build-only packaging dependency in a virtual environment (CI uses Python 3.12):

```sh
python3 -m venv build/packaging-venv
build/packaging-venv/bin/python -m pip install -r scripts/packaging-requirements.txt
PATH="$PWD/build/packaging-venv/bin:$PATH" bash scripts/package-dmg.sh \
  build/DerivedData/Build/Products/Release/MachOView.app \
  build/MachOView-local-universal.dmg universal
```

The pinned `dmgbuild` tool generates the Finder layout without automating Finder or needing an interactive desktop. Packaging preserves the signed app, verifies the finished image, and checks the copy mounted read-only, including the Applications shortcut. The tool and its Python dependencies are **not shipped inside the app or DMG**. Existing output files are not overwritten; choose a new filename for another build. The artwork changes the disk image's presentation, not the app's interface or Dark Mode support.

## GitHub builds and Releases

`.github/workflows/macos.yml` runs on pushes, pull requests, and manual dispatches. Each Apple Silicon job:

1. Verifies the runner is native ARM64 and records Xcode, SDK, and macOS versions.
2. Checks project structure and runs toolchain, release-policy, packaging-configuration, and portable decoder tests.
3. Compiles an optimized **universal Release (`-O2`)** build with dead-code stripping.
4. Requires both CPU slices in every bundled Mach-O and checks dependency paths in all slices, plus signatures.
5. Runs headless decoder and data-controller regression tests natively on ARM64 with a timeout.
6. Creates and verifies a custom universal DMG, packages a ZIP with macOS metadata preserved, and uploads both with checksums and logs.

Two additional jobs on **`macos-15-intel` and `macos-26-intel`** download the corresponding packaged universal app, verify the checksums and bundle, and run its `x86_64` slice natively. They test the actual ZIP being released, not a separately rebuilt Intel executable. They do not install or use Rosetta. The DMG contains the same verified app; packaging also compares the mounted app against the source bundle.

**Automatic previews:** a push to the repository's default branch (`main`) publishes a uniquely numbered `build-N` prerelease after all four jobs succeed. The preview tag points at the exact built commit and does not replace the latest stable release. No manual tag is needed to get downloadable releases from `main`.

**Stable releases:** when ready, create and push a version tag on the intended commit:

```sh
git tag v2.5.0
git push origin v2.5.0
```

Stable tags must use `vMAJOR.MINOR.PATCH`. The tag supplies the application version; the workflow run number supplies the build number. **Both universal builds, native tests on both CPU families and macOS baselines, and DMG checks must succeed**, and all four expected downloads must be present, before the release job publishes anything. Pull requests, non-default branches, and manual dispatches never publish. The release job alone receives repository write permission through `GITHUB_TOKEN`; no personal token is needed. Repository/organization policy must permit that write access.

Existing releases and their assets are not overwritten. To publish a changed build, push a new commit for a new preview run, or use a new version tag for a stable release.

## Performance and correctness work

- Disassembly captures output in a reusable, thread-local memory stream instead of redirecting the whole application's stdout into pipes. This removes per-instruction pipe reads and prevents unrelated output from corrupting the instruction listing.
- Temporary disassembly objects are drained per instruction; section-to-file offsets use direct arithmetic. Empty symbol vectors, oversized code sections, zero-progress decoding, and truncated string-table bounds are handled explicitly.
- Legacy decoder callback state remains serialized across sections; moving output to thread-local storage does **not** pretend that the old decoder is fully thread-safe.
- Archive writes use bounded shared background work and synchronized storage access rather than one polling writer thread per layout. Readers no longer seek the writer's FILE stream, and table display uses stable snapshots.
- File-format layouts no longer rely on the host's `BOOL`, x86 thread-state headers, or `sizeof(long double)`. ARM64 instruction and section addresses retain their full 64 bits.
- Modern SDK headers take precedence over historical copied system headers. Private cctools byte-swap helpers are namespaced to avoid overriding SDK functions with a different enum ABI.
- `LC_BUILD_VERSION`, ARM64 thread states, and ARM64e subtype labels are recognized. Export-trie and chained-fixup load commands show their link-edit metadata.

These changes remove concrete overhead and races; **no measured speedup percentage is claimed**. Benchmarking large files and exercising the graphical interface still require a Mac.

## Tests

Portable checks (Linux or macOS):

```sh
python3 -I scripts/check-project.py
python3 -I -m unittest discover -s tests -p 'test_*.py' -v
bash otool_disasm/tests/run-tests.sh
for script in scripts/*.sh; do bash -n "$script"; done
```

On macOS, build first and run `MachOView --self-test` as above. It checks the bundled LLVM on ARM64, pointer-authentication, and x86_64 instructions, plus data-controller regression tests. A successful compile alone is not the release gate.

The portable release tests use a local `gh` stub: they verify event gating, preview/stable flags, required assets, and checksums without publishing anything. Toolchain tests reproduce Xcode 26's Metal-first environment without needing Xcode.

Cross-compiling source files against a macOS SDK on Linux can catch architecture/compiler errors, but cannot validate Interface Builder compilation, code signing, DMG creation, GUI behavior, or native execution. **A green GitHub run for both macOS versions and a hands-on Mac smoke test remain necessary.** Mount the DMG, check its icon layout, copy the app to Applications, and launch it from there. Then open an ARM64 executable, an Intel Mach-O, a universal binary, and a static archive; browse/filter large tables, cancel parsing, and close/reopen documents. Check both light and dark system appearances.

## Known limitations

- This is a modernization of a legacy parser, not complete coverage of every new Mach-O feature. Chained-fixup payloads and pointer-authenticated Objective-C metadata are not fully decoded; some modern binaries can show incomplete symbol/ObjC detail.
- FAT64 containers are not supported. Ordinary FAT/universal containers remain supported.
- Wait for background parsing to finish before editing bytes. Parser-wide synchronization is not complete; concurrent editing and parsing can still race. Very large filters or node-index writes can also temporarily block table access.
- Process attachment remains subject to macOS permissions, entitlements, SIP, and hardened-runtime restrictions. Building natively does not bypass them.
- This is not a comprehensive hostile-input security audit; use caution with untrusted binaries.

Historical changelog and icon attribution are in [`README`](README). Bundled cctools/LLVM interface sources retain their upstream license notices.
