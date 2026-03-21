// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Workspace",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "Workspace",
            targets: ["Workspace"]
        ),
    ],
    targets: [
        .target(
            name: "Workspace"
        ),
        .testTarget(
            name: "WorkspaceTests",
            dependencies: ["Workspace"]
        ),
    ]
)
