// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "AgentActivity",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "AgentActivity", targets: ["AgentActivity"]),
    .executable(name: "AgentActivityHook", targets: ["AgentActivityHook"]),
  ],
  targets: [
    .target(
      name: "AgentActivityHookCore",
      path: "Sources/AgentActivityHookCore"
    ),
    .executableTarget(
      name: "AgentActivityHook",
      dependencies: ["AgentActivityHookCore"],
      path: "Sources/AgentActivityHook"
    ),
    .executableTarget(
      name: "AgentActivity",
      path: "Sources/AgentActivity"
    ),
    .testTarget(
      name: "AgentActivityTests",
      dependencies: ["AgentActivity"],
      path: "Tests/AgentActivityTests"
    ),
    .testTarget(
      name: "AgentActivityHookCoreTests",
      dependencies: ["AgentActivityHookCore"],
      path: "Tests/AgentActivityHookCoreTests"
    ),
  ]
)
