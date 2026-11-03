// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BackpackProtocol",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "BackpackProtocol", targets: ["BackpackProtocol"])],
    targets: [
        .target(name: "BackpackProtocol"),
        .testTarget(name: "BackpackProtocolTests", dependencies: ["BackpackProtocol"], resources: [.process("Fixtures")])
    ]
)
