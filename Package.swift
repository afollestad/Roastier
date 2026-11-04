// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "roastier",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Roastier", targets: ["Roastier"])
    ],
    targets: [
        .target(
            name: "RoastierKit",
            exclude: ["AGENTS.md", "CLAUDE.md", "Updates/AGENTS.md", "Updates/CLAUDE.md"]
        ),
        .executableTarget(
            name: "Roastier",
            dependencies: ["RoastierKit"],
            exclude: ["AGENTS.md", "CLAUDE.md"]
        ),
        .testTarget(
            name: "RoastierKitTests",
            dependencies: ["RoastierKit"]
        )
    ]
)
