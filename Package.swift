// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ActorLink",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "ActorLink", targets: ["ActorLink"]),
        .library(name: "ActorLinkSocket", targets: ["ActorLinkSocket"]),
    ],
    targets: [
        .target(name: "ActorLink"),
        .target(
            name: "ActorLinkSocket",
            dependencies: ["ActorLink"]
        ),
        .testTarget(
            name: "ActorLinkTests",
            dependencies: ["ActorLink"]
        ),
        .testTarget(
            name: "ActorLinkSocketTests",
            dependencies: ["ActorLinkSocket"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
