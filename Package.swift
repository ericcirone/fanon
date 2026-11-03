// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Fanon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PixmaKit", targets: ["PixmaKit"]),
        .library(name: "ESCLKit", targets: ["ESCLKit"]),
        .library(name: "ScanProcessing", targets: ["ScanProcessing"]),
        .executable(name: "fanon", targets: ["fanon"]),
        .executable(name: "FanonBridge", targets: ["FanonBridge"]),
        .executable(name: "FanonApp", targets: ["FanonApp"]),
    ],
    targets: [
        // Native Canon BJNP network transport + PIXMA (MX920 series) scan protocol.
        .target(name: "PixmaKit"),
        // eSCL (AirScan) server that exposes a PixmaKit scanner to macOS.
        .target(name: "ESCLKit", dependencies: ["PixmaKit"]),
        // Canon-style image corrections, auto-crop and searchable PDF output.
        .target(name: "ScanProcessing", dependencies: ["PixmaKit"]),
        // Command-line tool: discover, query status and scan to a file.
        .executableTarget(name: "fanon", dependencies: ["PixmaKit", "ESCLKit", "ScanProcessing"]),
        // Menu-bar agent that runs the eSCL bridge.
        .executableTarget(name: "FanonBridge", dependencies: ["PixmaKit", "ESCLKit"]),
        // Companion scanning app with preview and the full set of corrections.
        .executableTarget(name: "FanonApp", dependencies: ["PixmaKit", "ESCLKit", "ScanProcessing"]),
        .testTarget(name: "PixmaKitTests", dependencies: ["PixmaKit", "ESCLKit", "ScanProcessing"]),
    ]
)
