// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacHost", targets: ["MacHost"]),
        .executable(name: "MacHostTests", targets: ["MacHostTests"]),
        .executable(name: "PhoneTrashTests", targets: ["PhoneTrashTests"]),
        .executable(name: "ContentToolsTests", targets: ["ContentToolsTests"]),
        .executable(name: "ArchiveInteractionTests", targets: ["ArchiveInteractionTests"]),
        .library(name: "MacHostCore", targets: ["MacHostCore"])
    ],
    targets: [
        .executableTarget(name: "TransportRegressionTests", dependencies: ["MacHostCore"], path: "Tests/TransportRegressionTests"),
        .target(
            name: "MacHostCore",
            dependencies: ["CLibArchive"],
            path: "Sources/MacHostCore"
        ),
        .systemLibrary(
            name: "CLibArchive",
            path: "Sources/CLibArchive"
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
        ),
        .executableTarget(
            name: "PhoneTrashTests",
            dependencies: ["MacHostCore"],
            path: "Tests/PhoneTrashTests"
        ),
        .executableTarget(
            name: "ContentToolsTests",
            dependencies: ["MacHostCore"],
            path: "Tests/ContentToolsTests"
        ),
        .executableTarget(
            name: "ArchiveInteractionTests",
            dependencies: ["MacHostCore"],
            path: "Tests/ArchiveInteractionTests"
        )
    ]
)
