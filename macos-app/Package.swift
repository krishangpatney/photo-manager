// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhotoTransferMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoTransferMac", targets: ["PhotoTransferMac"])
    ],
    targets: [
        .executableTarget(
            name: "PhotoTransferMac",
            path: "Sources/PhotoTransferMac"
        ),
        .testTarget(
            name: "PhotoTransferMacTests",
            dependencies: ["PhotoTransferMac"],
            path: "Tests/PhotoTransferMacTests"
        )
    ]
)
