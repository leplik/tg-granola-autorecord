// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "granola-autorecord",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "granola-autorecord", targets: ["granola-autorecord"]),
    ],
    targets: [
        .target(name: "AutorecordCore"),
        .executableTarget(
            name: "granola-autorecord",
            dependencies: ["AutorecordCore"]
        ),
        .testTarget(
            name: "AutorecordCoreTests",
            dependencies: ["AutorecordCore"]
        ),
    ]
)
