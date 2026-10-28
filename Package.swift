// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SignFlowCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SignFlowCore", targets: ["SignFlowCore"]),
               .executable(name: "SignFlowProbe", targets: ["SignFlowProbe"])],
    targets: [
        .target(name: "SignFlowCore", path: "SignFlow", exclude: ["Views", "Assets.xcassets", "SignFlowApp.swift"], sources: ["Core", "Services", "ViewModels"]),
        .executableTarget(name: "SignFlowProbe", dependencies: ["SignFlowCore"], path: "Tools/Probe"),
        .testTarget(name: "SignFlowCoreTests", dependencies: ["SignFlowCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
