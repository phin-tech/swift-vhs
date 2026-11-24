// swift-tools-version: 6.0
import PackageDescription

// VHS drives a Mac app from outside and records it, for demoreel's clip scenes and for agents that need to see the
// real app. VHSCore is the line protocol and events.json (no AppKit, tested headless); VHS is the app side, linked
// into a Debug build; vhs-drive is the client, with typecase-drive's commands, so demoreel's `record` runs either.
let package = Package(
    name: "swift-vhs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VHS", targets: ["VHS"]),
        .library(name: "VHSCore", targets: ["VHSCore"]),
        .executable(name: "vhs-drive", targets: ["vhs-drive"]),
    ],
    targets: [
        .target(name: "VHSCore"),
        .target(name: "VHS", dependencies: ["VHSCore"]),
        .executableTarget(name: "vhs-drive", dependencies: ["VHSCore"]),
        .testTarget(name: "VHSCoreTests", dependencies: ["VHSCore"]),
    ]
)
