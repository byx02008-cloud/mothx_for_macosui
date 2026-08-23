# Vendored SwiftTerm

SwiftTerm vendored from the upstream **main** branch (2026-08-23 snapshot,
post-v1.19.0) under the MIT license.

Source: https://github.com/migueldeicaza/SwiftTerm

Why vendored:
- `github.com` is unreachable from this build environment (api/raw/codeload
  subdomains work), so SPM remote clones fail. Implemented as an
  `XCLocalSwiftPackageReference` in mothxOS.xcodeproj (`relativePath =
  Vendor/SwiftTerm`).
- v1.19.0 (latest release) had a CALayer-delegate-based macOS caret that did
  not draw reliably in an embedded `LocalProcessTerminalView`, leaving the TUI
  cursor invisible regardless of focus. Upstream rewrote the caret rendering
  (CaretRenderData + explicit `@MainActor CALayerDelegate`) on main after the
  release; we track main to pick that up.

Local patches applied to `Package.swift` (offline-build only):
1. Removed the always-declared remote dependencies (apple/swift-argument-parser,
   apple/swift-docc-plugin), which only feed optional executables and doc
   generation.
2. Removed the `Termcast` executable target (it referenced swift-argument-parser).
3. Removed the `.metal` shader resource and added `Apple/Metal/Shaders.metal`
   to the library target's `exclude`, because the Metal toolchain component is
   not installed. Metal is a runtime-optional accelerated renderer, off by
   default; the default CoreGraphics renderer does not reference it.

To switch back to the upstream remote package (when github.com is reachable),
replace the XCLocalSwiftPackageReference with an XCRemoteSwiftPackageReference
pointing at https://github.com/migueldeicaza/SwiftTerm and delete this directory.