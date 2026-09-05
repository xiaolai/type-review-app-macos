import Foundation

/// JavaScript's numeric semantics, where they differ from Swift's.
///
/// These are not stylistic differences. Each one changes a persisted metric,
/// and none of them is visible in review.
public enum JSMath {
    /// `Math.round`: ties break toward +∞, not away from zero.
    ///
    /// Swift's `.toNearestOrAwayFromZero` rounds −2.5 to −3; JavaScript gives
    /// −2. The engine rounds metrics that can be negative, so the difference
    /// is not theoretical. `floor(x + 0.5)` is the exact rule.
    public static func round(_ x: Double) -> Double {
        (x + 0.5).rounded(.down)
    }

    /// `x ** y` is `Math.pow`, not repeated multiplication. `0.3 ** 3` is
    /// 0.026999999999999996 while `0.3 * 0.3 * 0.3` is 0.027 — different
    /// doubles, and the difference survives into a consistency score.
    public static func pow(_ base: Double, _ exponent: Double) -> Double {
        Foundation.pow(base, exponent)
    }
}

/// Pure numeric primitives shared by the metrics layer.
public enum Stats {
    public static func roundTo2(_ n: Double) -> Double {
        JSMath.round(n * 100) / 100
    }

    public static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        // Summed in order, deliberately. Floating addition is not associative,
        // so a different traversal order is a different answer in the last
        // bits — and those bits are what the golden vectors compare.
        var sum = 0.0
        for x in xs { sum += x }
        return sum / Double(xs.count)
    }

    /// Population standard deviation.
    public static func stdDev(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let m = mean(xs)
        var acc = 0.0
        for x in xs { acc += JSMath.pow(x - m, 2) }
        return (acc / Double(xs.count)).squareRoot()
    }

    /// Maps a coefficient of variation to a consistency percentage in (0, 100].
    public static func kogasa(_ cov: Double) -> Double {
        100 * (1 - tanh(cov + JSMath.pow(cov, 3) / 3 + JSMath.pow(cov, 5) / 5))
    }
}
