// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "socktainer-probe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SocktainerProbeCore",
            path: "Sources/SocktainerProbeCore"
        ),
        .executableTarget(
            name: "SocktainerProbeCli",
            dependencies: ["SocktainerProbeCore"],
            path: "Sources/SocktainerProbeCli"
        ),
        .executableTarget(
            name: "SocktainerProbe",
            dependencies: ["SocktainerProbeCore"],
            path: "Sources/SocktainerProbe",
            resources: [.process("Assets.xcassets"), .copy("AppIcon.icns")]
        ),
    ]
)
