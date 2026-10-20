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
            name: "Workspace",
            dependencies: [.target(name: "WorkspacePOSIX", condition: .when(platforms: [.linux]))]
        ),
        .target(name: "WorkspacePOSIX"),
        .testTarget(
            name: "WorkspaceTests",
            dependencies: ["Workspace"]
        ),
    ]
)
