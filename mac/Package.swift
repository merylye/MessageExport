// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DownloadMyMessages",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DownloadMyMessages", targets: ["DownloadMyMessages"]),
        .executable(name: "SelfTest", targets: ["SelfTest"]),
    ],
    targets: [
        .target(
            name: "MessagesCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "DownloadMyMessages",
            dependencies: ["MessagesCore"]
        ),
        // Command-line check that builds a fake Messages database and exports it.
        // Run with: swift run SelfTest
        .executableTarget(
            name: "SelfTest",
            dependencies: ["MessagesCore"]
        ),
    ]
)
