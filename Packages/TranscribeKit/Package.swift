// swift-tools-version: 6.0
import PackageDescription

// Two layers:
//
//   TranscribeCore  Foundation only: chunking, transcript assembly, meeting
//                   classification, Markdown. Builds and tests on Linux, which
//                   is what lets CI run it on the org's self-hosted runners.
//   TranscribeKit   Everything that needs a Mac: Core Audio capture, meeting
//                   detection, and Voz (Core ML). Re-exports TranscribeCore.
//
// The manifest is evaluated on the host, so on Linux the Apple-only targets
// and the Voz dependency are simply absent and `swift test` runs the core.

var products: [Product] = [
    .library(name: "TranscribeCore", targets: ["TranscribeCore"]),
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "TranscribeCore"),
    .testTarget(name: "TranscribeCoreTests", dependencies: ["TranscribeCore"]),
]

#if os(macOS)
products += [
    .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
    .executable(name: "transcribe-cli", targets: ["TranscribeCLI"]),
]
dependencies += [
    .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0"),
]
targets += [
    .target(
        name: "TranscribeKit",
        dependencies: [
            "TranscribeCore",
            .product(name: "Voz", package: "desert-ant-core"),
        ]
    ),
    .executableTarget(name: "TranscribeCLI", dependencies: ["TranscribeKit"]),
]
#endif

let package = Package(
    name: "TranscribeKit",
    // Core Audio process taps (system audio capture) arrived in macOS 14.2.
    platforms: [.macOS("14.4")],
    products: products,
    dependencies: dependencies,
    targets: targets
)
