// swift-tools-version:5.9
// Test harness for the real-time DSP code. The app itself is built with build.sh.
//   swift test
import PackageDescription

let package = Package(
    name: "BlackHoleMonitorApp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AudioCore", path: "BlackHoleMonitorApp/DSP"),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"], path: "Tests/AudioCoreTests"),
    ]
)
