// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [
    .library(name: "MacSTTCore", targets: ["MacSTTCore"]),
]

var targets: [Target] = [
    .target(
        name: "MacSTTCore"
    ),
    .testTarget(
        name: "MacSTTCoreTests",
        dependencies: ["MacSTTCore"]
    ),
]

#if os(macOS)
products.append(.library(name: "MacSTTApple", targets: ["MacSTTApple"]))

targets.append(
    .target(
        name: "MacSTTApple",
        dependencies: ["MacSTTCore"],
        linkerSettings: [
            .linkedFramework("AVFoundation"),
            .linkedFramework("Speech"),
            .linkedFramework("CoreAudio"),
            .linkedFramework("AudioToolbox"),
            .linkedFramework("Accelerate"),
            .linkedFramework("CoreMedia"),
            .linkedFramework("OSLog"),
        ]
    )
)

targets.append(
    .testTarget(
        name: "MacSTTAppleTests",
        dependencies: ["MacSTTApple", "MacSTTCore"]
    )
)
#endif

let package = Package(
    name: "MacSTT",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
