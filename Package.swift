// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DisplayPilot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DisplayPilot",
            path: "Sources/DisplayPilot"
        )
    ],
    // Mode Swift 5 : la concurrence stricte de Swift 6 donne des avertissements au lieu d'erreurs
    swiftLanguageModes: [.v5]
)
