# MachOView — native Apple Silicon build

MachOView is a Cocoa viewer for Mach-O executables, object files, universal binaries, and static archives. This modernization replaces the Intel-only build inputs with source-built disassembly code and a native LLVM backend, and adds tested-build packaging and GitHub Releases.

## Requirements and compatibility

- **Apple Silicon, macOS 15 or later** for the baseline CI build.
- The separate **macOS 26** build uses that runner's Xcode/SDK and requires macOS 26 or later.
- **No Rosetta:** CI builds the application as `arm64`, verifies the architecture of every bundled Mach-O binary, and runs the built executable on an ARM64 runner.
- Local development needs full Xcode (not only Command Line Tools), with the selected toolchain providing an ARM64-capable `libLTO.dylib`.

The Xcode project uses the selected `macosx` SDK, C++17/libc++, and standard architectures. CI deliberately distributes ARM64-only apps. Intel/universal builds are not part of the release test matrix.

## Interface, SDK, and Dark Mode

**A modern SDK does not automatically redesign the interface.** This fork focuses on native Apple Silicon support, build compatibility, performance, and reliability while retaining MachOView's classic interface.

- **Layout:** the existing navigation tree, detail tables, hex view, and disassembly presentation remain. This is not a complete visual redesign.
- **Native controls:** standard AppKit windows, menus, and controls can adopt the styling provided by the macOS version running the app. Their exact appearance also depends on the control styles and interface files; not every element automatically gains the newest visual effects.
- **SDK selection:** `SDKROOT = macosx` uses the SDK in the selected Xcode installation, not necessarily the newest Xcode available. Building with a newer SDK does not give macOS 15 the appearance or features of macOS 26. The deployment target separately controls the minimum supported OS.
- **Dark Mode is partial and not visually verified:** standard controls using system colors are expected to follow the system appearance, but custom table highlights, separators, and colored text still include fixed colors that may have poor contrast. There is no in-app Light / Dark / System selector.

A full appearance update would require adaptive custom colors, contrast and selection checks in both themes, and deliberate sidebar, toolbar, spacing, and typography changes. Those UI changes are **not included in this modernization**. Hands-on testing on macOS is still needed before claiming complete Dark Mode support.

## Downloading a build

After a successful run, the **Actions → Native macOS build → Artifacts** section contains an app ZIP for each macOS baseline, plus checksums and build logs. Version-tagged runs also attach both ZIPs and a combined `SHA256SUMS.txt` to **GitHub Releases**.

1. Choose the `macos-15-arm64` ZIP for macOS 15 or later, or `macos-26-arm64` for macOS 26 or later.
2. Extract `MachOView.app` and move it to Applications.
3. The builds are **ad-hoc signed, not Developer ID signed or Apple notarized**. macOS can display a security warning. Only if you trust the source and have verified the download, use the app-specific **System Settings → Privacy & Security → Open Anyway** option, if offered. Do not disable Gatekeeper globally.

Ad-hoc signing provides local code-signature integrity, not publisher verification. Uninterrupted public distribution needs a Developer ID signing/notarization setup; no Apple credentials are required or used by this workflow.

## Build locally on a Mac

Select a full Xcode installation first, then:

```sh
xcodebuild -project machoview.xcodeproj -scheme MachOView \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build

bash scripts/verify-app.sh build/DerivedData/Build/Products/Release/MachOView.app arm64
build/DerivedData/Build/Products/Release/MachOView.app/Contents/MacOS/MachOView --self-test
```

The build compiles `otool_disasm/*.c` (excluding the duplicate `symbol.c`) directly into the app. It copies `libLTO.dylib` from the **selected Xcode toolchain** into `Contents/Frameworks`, rejects missing architecture slices or non-system dependencies, and signs the nested library before the app. The distributed app loads only its bundled library; the recipient does not need Xcode or Homebrew.

The historical root `libdisasm.a` and `lib/libLTO.dylib` remain in the repository for provenance, but **neither is used or packaged**. Use the root project/shared scheme, not the historical disassembler subproject or `createdmg` script.

The default deployment target is 15.0. If using a newer toolchain whose bundled LLVM requires a newer OS, raise `MACOSX_DEPLOYMENT_TARGET` accordingly and test on that OS. CI keeps separate macOS 15 and 26 builds so each baseline is actually exercised.

## GitHub builds and Releases

`.github/workflows/macos.yml` runs on pushes, pull requests, and manual dispatches. Each Apple Silicon job:

1. Verifies the runner is native ARM64 and records Xcode, SDK, and macOS versions.
2. Checks project structure and runs portable decoder loader/output tests.
3. Compiles an optimized **Release (`-O2`)** build with dead-code stripping.
4. Checks all bundle architectures, dependency paths, and signatures.
5. Runs headless decoder and data-controller regression tests with a timeout.
6. Packages the app with macOS metadata preserved and uploads checksums and logs.

When ready to publish, commit and push the changes, then create and push a version tag:

```sh
git tag v2.5.0
git push origin v2.5.0
```

Tags must use `vMAJOR.MINOR.PATCH`. The tag supplies the application version; the workflow run number supplies the build number. Only a **tag push with both Mac jobs successful** can create a GitHub Release. Ordinary branch pushes and pull requests do not publish releases. The release job alone receives repository write permission. Creating a release for an already-published tag fails rather than silently replacing its assets; publish a new version tag for a new build.

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
bash otool_disasm/tests/run-tests.sh
bash -n scripts/embed-llvm.sh scripts/verify-app.sh
```

On macOS, build first and run `MachOView --self-test` as above. It checks the bundled LLVM on ARM64, pointer-authentication, and x86_64 instructions, plus data-controller regression tests. A successful compile alone is not the release gate.

Cross-compiling source files against a macOS SDK on Linux can catch architecture/compiler errors, but cannot validate Interface Builder compilation, code signing, GUI behavior, or native execution. **The first green GitHub run and a hands-on Mac smoke test remain necessary.** In particular, open an ARM64 executable, an Intel Mach-O, a universal binary, and a static archive; browse/filter large tables, cancel parsing, and close/reopen documents.

## Known limitations

- This is a modernization of a legacy parser, not complete coverage of every new Mach-O feature. Chained-fixup payloads and pointer-authenticated Objective-C metadata are not fully decoded; some modern binaries can show incomplete symbol/ObjC detail.
- FAT64 containers are not supported. Ordinary FAT/universal containers remain supported.
- Wait for background parsing to finish before editing bytes. Parser-wide synchronization is not complete; concurrent editing and parsing can still race. Very large filters or node-index writes can also temporarily block table access.
- Process attachment remains subject to macOS permissions, entitlements, SIP, and hardened-runtime restrictions. Building natively does not bypass them.
- This is not a comprehensive hostile-input security audit; use caution with untrusted binaries.

Historical changelog and icon attribution are in [`README`](README). Bundled cctools/LLVM interface sources retain their upstream license notices.
