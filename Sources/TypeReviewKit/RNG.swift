import Foundation

/// Mulberry32 — the deterministic PRNG the whole engine seeds from.
///
/// Ported bit-for-bit, and the bits are the point. The natural Swift
/// transliteration uses `Int32`, whose `>>` is an *arithmetic* shift that
/// propagates the sign bit; JavaScript's `>>>` is logical. The two agree on
/// every value below 2³¹ and diverge on the first draw above it — which means
/// the wrong port passes any test that only checks "in [0,1)", "deterministic
/// per seed" and "different seeds differ". All three of those are exactly what
/// the TypeScript suite asserted.
///
/// So: `UInt32` throughout, wrapping arithmetic (`&+`, `&*`) for JavaScript's
/// `| 0` and `Math.imul`, and `Vectors/rng.json` as the arbiter.
public struct Mulberry32 {
    private var state: UInt32

    public init(seed: UInt32) {
        state = seed
    }

    /// A value in [0, 1), matching the TypeScript generator draw for draw.
    public mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (1 | state)
        t = t &+ ((t ^ (t >> 7)) &* (61 | t)) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296.0
    }
}
