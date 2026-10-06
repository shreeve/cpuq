// swift-tools-version: 6.2

import PackageDescription

// A warning is a build failure.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]
let app: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Cpuq",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Cpuq", targets: ["Cpuq"])
    ],
    targets: [
        // What the app knows about cpuq: `cpuq status --json`, the meter rule, where cpuq lives.
        .target(name: "CpuqCore", swiftSettings: strict),
        // The menu-bar app.
        .executableTarget(name: "Cpuq", dependencies: ["CpuqCore"], swiftSettings: app),
        .testTarget(name: "CpuqCoreTests", dependencies: ["CpuqCore"], swiftSettings: strict),
    ]
)
