// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeReview",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeReviewKit", targets: ["TypeReviewKit"]),
        .executable(name: "TypeReviewApp", targets: ["TypeReviewApp"]),
    ],
    targets: [
        // The domain layer: typing loop, metrics, adaptive planner, corpus,
        // profile codec. Pure Swift, no AppKit — the same separation the
        // TypeScript original enforces, and for the same reason: it is the
        // part that must be exhaustively testable.
        .target(name: "TypeReviewKit"),
        .executableTarget(name: "TypeReviewApp", dependencies: ["TypeReviewKit"]),
        .testTarget(
            name: "TypeReviewKitTests",
            dependencies: ["TypeReviewKit"],
            // Golden vectors generated from the TypeScript engine. They are
            // the contract between the two implementations.
            resources: [.copy("Vectors")]
        ),
    ]
)
