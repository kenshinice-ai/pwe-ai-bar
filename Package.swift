// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PWEAIBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PWEAIBar",
            path: "Sources/PWEAIBar",
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
