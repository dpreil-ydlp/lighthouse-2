// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LighthouseCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LighthouseCore", targets: ["LighthouseCore"]),
        // The app target is normally built by xcodebuild (App/Lighthouse.xcodeproj); this product lets
        // scripts/build-app.sh build the same sources with SwiftPM when Xcode is unavailable. Named
        // LighthouseApp so it does not shadow the Xcode app target's `Lighthouse` scheme.
        .executable(name: "LighthouseApp", targets: ["LighthouseApp"]),
    ],
    targets: [
        .target(
            name: "LighthouseCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LighthouseApp",
            dependencies: ["LighthouseCore"],
            path: "App/Lighthouse",
            exclude: ["Info.plist", "Assets.xcassets"]
        ),
        // App-target logic that must be tested headless (M2-01 capture folder). No UI is created.
        .testTarget(
            name: "LighthouseAppTests",
            dependencies: ["LighthouseApp"]
        ),
        .testTarget(
            name: "LighthouseCoreTests",
            dependencies: ["LighthouseCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
