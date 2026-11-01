// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceIDUnlock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FaceIDUnlock", targets: ["FaceIDUnlock"])],
    targets: [
        .target(name: "FaceIDCore"),
        .executableTarget(name: "FaceIDUnlock", dependencies: ["FaceIDCore"]),
        .testTarget(name: "FaceIDCoreTests", dependencies: ["FaceIDCore"]),
        .testTarget(name: "FaceIDUnlockTests", dependencies: ["FaceIDUnlock"], exclude: ["Fixtures"])
    ],
    swiftLanguageModes: [.v5]
)
