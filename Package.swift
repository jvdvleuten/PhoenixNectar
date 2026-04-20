// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PhoenixNectar",
    platforms: [
        .iOS(.v16),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PhoenixNectar",
            targets: ["PhoenixNectar"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PhoenixNectar"
        ),
        .testTarget(
            name: "PhoenixNectarTests",
            dependencies: ["PhoenixNectar"]
        ),
    ]
    ,
    swiftLanguageModes: [.v6]
)
