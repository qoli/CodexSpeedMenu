// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CodexSpeedMenu", platforms: [.macOS(.v14)], products: [.executable(name: "CodexSpeedMenu", targets: ["CodexSpeedMenu"]), .executable(name: "SpeedBench", targets: ["SpeedBench"])], targets: [.target(name: "SpeedCore"), .executableTarget(name: "CodexSpeedMenu", dependencies: ["SpeedCore"]), .executableTarget(name: "SpeedBench", dependencies: ["SpeedCore"]), .testTarget(name: "SpeedCoreTests", dependencies: ["SpeedCore"])])
