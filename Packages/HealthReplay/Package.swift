// swift-tools-version: 5.9
// HealthReplay: runs an Apple Health export (Health app → profile → Export All Health Data) through
// PetCore's rules, day by day, so the app's judgement can be checked against a person's real data
// without installing the app. Runs on a Mac (or Linux); the data never leaves the computer.
import PackageDescription

let package = Package(
    name: "HealthReplay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "health-replay", targets: ["HealthReplay"])
    ],
    dependencies: [
        .package(path: "../PetCore")
    ],
    targets: [
        .target(name: "ReplayCore", dependencies: [.product(name: "PetCore", package: "PetCore")]),
        .executableTarget(name: "HealthReplay", dependencies: ["ReplayCore"]),
        .testTarget(name: "HealthReplayTests", dependencies: ["ReplayCore"])
    ]
)
