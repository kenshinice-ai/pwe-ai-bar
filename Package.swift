// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PWEAIBar",
    // Required before SwiftPM will treat `Resources/<lang>.lproj` as localized resources rather
    // than as two directories it copies verbatim.
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PWEAIBar",
            path: "Sources/PWEAIBar",
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(name: "PWEAIBarTests", dependencies: ["PWEAIBar"], path: "Tests/PWEAIBarTests")
    ]
)
