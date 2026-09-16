// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "tg-granola-autorecord",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tg-granola-autorecord", targets: ["tg-granola-autorecord"]),
    ],
    targets: [
        .target(name: "AutorecordCore"),
        .executableTarget(
            name: "tg-granola-autorecord",
            dependencies: ["AutorecordCore"]
        ),
        .testTarget(
            name: "AutorecordCoreTests",
            dependencies: ["AutorecordCore"]
        ),
    ]
)
