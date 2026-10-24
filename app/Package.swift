// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CosmosMediaDownloader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CosmosMediaDownloader", path: "Sources/CosmosMediaDownloader")
    ]
)
