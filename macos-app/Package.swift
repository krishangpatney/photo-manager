// swift-tools-version: 6.0
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
        )
    ]
)
