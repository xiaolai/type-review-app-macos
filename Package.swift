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
        .target(
            name: "TypeReviewKit",
            // The bundled corpus travels with the Kit: quotes and code
            // snippets are domain data, not app chrome, and the same bytes
            // ship in the website.
            resources: [.copy("Resources")]
        ),
        .executableTarget(name: "TypeReviewApp", dependencies: ["TypeReviewKit"]),
        // Builds the starter shelf from public-domain texts: `make shelf`.
        // Never linked into the app.
        .executableTarget(name: "make-shelf", dependencies: ["TypeReviewKit"], path: "Tools/MakeShelf"),
        // `make epub-corpus`: the EPUB reader measured over the books on
        // this Mac. Local only, never in CI; not part of the app.
        .executableTarget(name: "EpubCorpus", dependencies: ["TypeReviewKit"]),
        .testTarget(
            name: "TypeReviewKitTests",
            dependencies: ["TypeReviewKit"],
            // Golden vectors generated from the TypeScript engine. They are
            // the contract between the two implementations. Fixtures are the
            // books the import tests read, all public domain or hand-made.
            resources: [.copy("Vectors"), .copy("Fixtures")]
        ),
    ]
)
