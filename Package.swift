// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AgentActivity",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AgentActivity", targets: ["AgentActivity"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentActivity",
            path: "Sources/AgentActivity"
        ),
        .testTarget(
            name: "AgentActivityTests",
            dependencies: ["AgentActivity"],
            path: "Tests/AgentActivityTests"
        ),
    ]
)
