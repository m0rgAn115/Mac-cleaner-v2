// swift-tools-version: 6.0
import PackageDescription
import Foundation

let engineDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("engine/target/release").path

let package = Package(
    name: "CleanMyMacLocal",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "CleanMyMacLocal", targets: ["CleanMyMacLocal"]), .executable(name: "CleanerHelper", targets: ["CleanerHelper"])],
    targets: [
        .target(name: "PrivilegedProtocol"),
        .executableTarget(name: "CleanerHelper", dependencies: ["PrivilegedProtocol"]),
        .target(name: "CleanerBridge", publicHeadersPath: "include"),
        .target(name: "CleanerCore", dependencies: ["CleanerBridge", "PrivilegedProtocol"], resources: [.process("Resources")],
                linkerSettings: [.unsafeFlags(["-L\(engineDirectory)", "-lcleaner_engine"])]),
        .executableTarget(name: "CleanMyMacLocal", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"])
    ]
)
