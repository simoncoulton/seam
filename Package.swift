// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Seam",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Seam", path: "Sources/Seam")
    ]
)
