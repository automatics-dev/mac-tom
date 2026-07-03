// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TOM",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.54.0"),
    ],
    targets: [
        .executableTarget(
            name: "TOM",
            dependencies: [],
            path: "Sources/TOM",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
                // Embed Info.plist into the binary so TCC tracks permissions by bundle ID
                // without requiring a full .app bundle structure.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/TOM/Info.plist",
                ]),
            ]
        ),
    ]
)
