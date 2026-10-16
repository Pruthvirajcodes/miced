// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "screen-dimmer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Archived: the LidDetection library and webcam-lid tool. See Sources/ScreenDimmer/Archive.swift.
        .executableTarget(
            name: "screen-dimmer",
            path: "Sources/ScreenDimmer"
        ),
    ]
)
