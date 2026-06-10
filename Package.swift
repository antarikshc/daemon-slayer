// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DaemonSlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "daemonslayer",
            path: "Sources/DaemonSlayer"
        ),
        .executableTarget(
            name: "fakedaemon",
            path: "Sources/FakeDaemon"
        ),
        .testTarget(
            name: "DaemonSlayerTests",
            dependencies: ["daemonslayer"],
            path: "Tests/DaemonSlayerTests"
        ),
    ]
)
