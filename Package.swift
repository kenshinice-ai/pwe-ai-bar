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
            // The two `.lproj` directories sit at the target root, not under `Resources/`: SwiftPM only
            // treats a localization directory as one when it is not nested inside another processed
            // resource directory — nested, they were copied nowhere and every lookup fell through to
            // the English written at the call site, so the app rendered identically in both languages.
            resources: [.process("Resources"), .process("en.lproj"), .process("zh-Hans.lproj")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(name: "PWEAIBarTests", dependencies: ["PWEAIBar"], path: "Tests/PWEAIBarTests")
    ]
)
