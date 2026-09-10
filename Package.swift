// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchIslandCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NotchIslandCore", targets: ["NotchIslandCore"])],
    targets: [
        .target(name: "NotchIslandCore", path: "boringNotch/components/Island/Core"),
        .testTarget(name: "NotchIslandCoreTests", dependencies: ["NotchIslandCore"], path: "Tests/CoreTests"),
        .target(name: "NotchInteractionCore", path: "boringNotch/Interaction/Core"),
        .testTarget(name: "NotchInteractionTests", dependencies: ["NotchInteractionCore"], path: "Tests/NotchInteractionTests")
    ],
    swiftLanguageVersions: [.v5]
)
