// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Navi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Navi", targets: ["Navi"]),
        .library(name: "NaviCore", targets: ["NaviCore"]),
    ],
    dependencies: [
        // Swift Testing ships with the Swift 6 toolchain in Xcode.app, but the
        // Command Line Tools alone do not expose it to SPM. We depend on the
        // standalone package so `swift test` works on CLT-only setups.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "NaviCore",
            path: "Sources/NaviCore"
        ),
        .executableTarget(
            name: "Navi",
            dependencies: ["NaviCore"],
            path: "Sources/Navi"
        ),
        .testTarget(
            name: "NaviCoreTests",
            dependencies: [
                "NaviCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/NaviCoreTests"
        ),
    ]
)
