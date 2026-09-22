// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacHost", targets: ["MacHost"]),
        .executable(name: "MacHostTests", targets: ["MacHostTests"]),
        .library(name: "MacHostCore", targets: ["MacHostCore"])
    ],
    targets: [
        .executableTarget(name: "TransportRegressionTests", dependencies: ["MacHostCore"], path: "Tests/TransportRegressionTests"),
        .target(
            name: "MacHostCore",
            path: "Sources/MacHostCore"
        ),
        .executableTarget(
            name: "MacHost",
            dependencies: ["MacHostCore"],
            path: "Sources/MacHost"
        ),
        .executableTarget(
            name: "MacHostTests",
            dependencies: ["MacHostCore"],
            path: "Tests/MacHostTests"
        )
    ]
)
