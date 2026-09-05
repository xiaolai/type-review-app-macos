import Foundation

/// What the settings surface offers, described once.
///
/// The website has its own copy of this in TypeScript, and the two cannot be
/// shared at build time now that they live in separate repositories. So the
/// values are pinned by a golden vector instead: a word count one side allows
/// and the other refuses, or a default that moves on one side only, is the
/// failure that makes "the same app" untrue — and it stays invisible until a
/// user's profile bounces between them.
public enum SettingsSchema {
    /// The narrower ranges a control may *produce*. Never the range it may
    /// display: a loaded value outside these is shown as it is, because a
    /// bounded control rewrites what it merely displays and the next unrelated
    /// edit persists the rewrite.
    public enum UIBounds {
        public static let targetWpm = (lo: 10.0, hi: 250.0)
        public static let wordCount = (lo: 5.0, hi: 200.0)
        public static let testDurationSec = (lo: 10.0, hi: 300.0)
    }

    public static let wordCountPresets: [Double] = [10, 25, 30, 50]
    public static let durationPresets: [Double] = [15, 30, 60, 120]
    public static let modes: [Mode] = [.adaptive, .benchmark]
    public static let testModes: [TestMode] = [.words, .time]
    public static let passageLengths: [PassageLength] = [.any, .short, .medium, .long]
}
