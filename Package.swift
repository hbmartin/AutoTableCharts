// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Test-only hooks (`#if ATC_TEST_HOOKS`) compile into debug builds and stay
/// out of the release binaries consumers ship. Release test runs opt back in
/// with `swift test -c release -Xswiftc -DATC_TEST_HOOKS`.
let testHookSettings: [SwiftSetting] = [
    .define("ATC_TEST_HOOKS", .when(configuration: .debug))
]

let package = Package(
    name: "AutoTableCharts",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
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
            name: "AutoTableCharts",
            swiftSettings: testHookSettings
        ),
        .testTarget(
            name: "AutoTableChartsTests",
            dependencies: ["AutoTableCharts"],
            swiftSettings: testHookSettings
        ),
    ]
)
