// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AutoTableCharts",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AutoTableCharts",
            targets: ["AutoTableCharts"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            exact: "1.5.0"
        ),
    ],
    targets: [
        .target(
            name: "AutoTableCharts"
        ),
        .testTarget(
            name: "AutoTableChartsTests",
            dependencies: ["AutoTableCharts"]
        ),
    ]
)
