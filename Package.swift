// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompressionPlannerKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CompressionPlanner", targets: ["CompressionPlanner"])
    ],
    targets: [
        .target(
            name: "CompressionPlanner",
            path: "AwesomeApp/CompressionPlanner"
        ),
        .testTarget(
            name: "CompressionPlannerTests",
            dependencies: ["CompressionPlanner"],
            path: "CompressionPlannerTests"
        )
    ]
)
