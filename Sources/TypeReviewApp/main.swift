import TypeReviewKit

// Placeholder entry point. The app target exists so `swift build` covers the
// eventual AppKit surface; today the work is in TypeReviewKit, where the
// engine is being ported module by module against golden vectors.
var rng = Mulberry32(seed: 42)
print("TypeReview — kit online, first draw \(rng.next())")
