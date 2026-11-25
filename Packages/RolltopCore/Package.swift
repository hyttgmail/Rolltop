// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RolltopCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RolltopCore", targets: ["RolltopCore"]),
    ],
    targets: [
        .target(name: "RolltopCore"),
        .testTarget(name: "RolltopCoreTests", dependencies: ["RolltopCore"]),
    ]
)
