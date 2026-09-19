// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DocklingAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DocklingAgent",
            resources: [.copy("Resources")]
        )
    ]
)
