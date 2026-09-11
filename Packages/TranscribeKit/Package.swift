// swift-tools-version: 6.1
import PackageDescription

// Two layers:
//
//   TranscribeCore  Foundation only: chunking, transcript assembly, meeting
//                   classification, Markdown. Builds and tests on Linux, which
//                   is what lets CI run it on the org's self-hosted runners.
//   TranscribeKit   Everything that needs a Mac: Core Audio capture, meeting
//                   detection, Voz and Gist (Core ML), and Title (MLX).
//                   Re-exports TranscribeCore.
//
// The manifest is evaluated on the host, so on Linux the Apple-only targets
// and the Desert Ant dependency are simply absent and `swift test` runs the core.

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
    // The MLX trait is what gives Title a working model. Without it the
    // module builds as a stub with no way to create one.
    .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0",
             traits: ["MLX"]),
]
targets += [
    .target(
        name: "TranscribeKit",
        dependencies: [
            "TranscribeCore",
            .product(name: "Voz", package: "desert-ant-core"),
            .product(name: "Gist", package: "desert-ant-core"),
            .product(name: "Title", package: "desert-ant-core"),
            // For `ModelDistribution.resolving(_:)` and `RevisionRequirement`,
            // used to ask the Hub whether a newer compatible model revision
            // exists.
            .product(name: "DesertAnt", package: "desert-ant-core"),
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
