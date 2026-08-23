// swift-tools-version:6.2

import PackageDescription
import Foundation

// A package manifest is compiled and run on the HOST, so `os(Linux)` is false
// when cross-compiling from macOS to Linux — and the Apple/Mac/iOS sources are
// then handed to the Linux target, which fails on `import CoreText`. There is
// no way for a manifest to see the destination, so allow the exclude to be
// forced explicitly.
let excludeAppleSources =
    ProcessInfo.processInfo.environment["SWIFTTERM_EXCLUDE_APPLE"] == "1"
#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = excludeAppleSources ? ["Apple", "Mac", "iOS"] : []
#endif

let buildInfoTargets: [Target] = [
    .executableTarget(
        name: "SwiftTermBuildInfoGenerator",
        path: "Sources/SwiftTermBuildInfoGenerator"
    ),
    .plugin(
        name: "SwiftTermBuildInfoPlugin",
        capability: .buildTool(),
        dependencies: ["SwiftTermBuildInfoGenerator"]
    )
]

#if os(Windows)
let products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .library(
        name: "SwiftTerm",
        targets: ["SwiftTerm"]
    ),
]

let targets: [Target] = [
    .target(
        name: "SwiftTerm",
        dependencies: [],
        path: "Sources/SwiftTerm",
        exclude: platformExcludes + ["Mac/README.md"],
        plugins: [
            .plugin(name: "SwiftTermBuildInfoPlugin")
        ]
//        swiftSettings: [
//            .unsafeFlags(["-enforce-exclusivity=none"])
//        ]
    ),
    .executableTarget (
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .testTarget(
        name: "SwiftTermTests",
        dependencies: ["SwiftTerm"],
        path: "Tests/SwiftTermTests",
        resources: [
            .copy("Fixtures/xterm-ghostty.infocmp"),
            .copy("Fixtures/swifterm-terminfo.infocmp")
        ]
    )
] + buildInfoTargets
#else
let products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .library(
        name: "SwiftTerm",
        targets: ["SwiftTerm"]
    ),
]

let targets: [Target] = [
    .target(
        name: "SwiftTerm",
        //
        // We can not use Swift Subprocess, because there is no way of configuring the child process to
        // be a controlling terminal, as it is posix-spawn based.
//        dependencies: [
//            .product(name: "Subprocess", package: "swift-subprocess", condition: .when(platforms: [.macOS, .linux]))
//        ],
        path: "Sources/SwiftTerm",
        exclude: platformExcludes + ["Mac/README.md", "Apple/Metal/Shaders.metal"],
        // Vendored build: the .metal shader is excluded because this
        // environment lacks the Metal toolchain. Metal rendering is a
        // runtime-optional accelerated path, off by default; the default
        // CoreGraphics renderer does not reference it.
        plugins: [
            .plugin(name: "SwiftTermBuildInfoPlugin")
        ]
        // Left off deliberately: this is item 5 of Docs/io-cpu-profile.md and
        // wants its own before/after, not a free ride on another change.
//        ,swiftSettings: [
//            .unsafeFlags(["-enforce-exclusivity=none"])
//        ]
    ),
    .executableTarget (
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .testTarget(
        name: "SwiftTermTests",
        dependencies: ["SwiftTerm"],
        path: "Tests/SwiftTermTests",
        resources: [
            .copy("Fixtures/xterm-ghostty.infocmp"),
            .copy("Fixtures/swifterm-terminfo.infocmp")
        ]
    )
] + buildInfoTargets
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: products,
    // Vendored build: remote package declarations trimmed. The SwiftTerm
    // library target has no external dependencies; the removed packages only
    // feed optional executables (SwiftTermFuzz/Termcast) and doc generation.
    dependencies: [],
//        .package(url: "https://github.com/swiftlang/swift-subprocess", revision: "426790f3f24afa60b418450da0afaa20a8b3bdd4")
    targets: targets,
    swiftLanguageModes: [.v6]
)
