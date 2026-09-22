import AppKit

extension NSWindow {
    /// Backs the window's layers in sRGB, at 8 bits a channel.
    ///
    /// A window is backed in its screen's colour space unless told otherwise,
    /// and on a wide-gamut display that space is the display's own profile.
    /// Under it AppKit gives any layer whose drawing has colour in it — not
    /// colour outside sRGB, *any* colour — a 16-bit float backing store, twice
    /// the memory of the 8-bit one a layer drawn in greys gets. Measured on a
    /// Studio Display in September 2026 with a 1000-point view drawn into a
    /// borderless window: a grey square cost 2.4 bytes a pixel, a red square
    /// 8.4, and the same red at an alpha of 0.2, or made from sRGB components
    /// well inside the gamut, still 8.4. `depthLimit` and the layer's own
    /// `contentsFormat` changed nothing; the window's colour space brought it
    /// to 4.4. The typing surface draws mistakes in red and the caret in the
    /// accent colour, and the keyboard glazes its keys in both, so both
    /// paid double for every pixel — 8.9 MB for the passage alone.
    ///
    /// The price is that a colour outside sRGB is clipped to its edge. The
    /// system red and the accent colour are a little more vivid than sRGB on
    /// a P3 display, and here they are drawn at sRGB's red instead. For a
    /// mark on a mistyped letter that is the right trade.
    ///
    /// Every window this app makes calls this, and `--selftest` fails one
    /// that does not.
    func useSRGBBacking() {
        colorSpace = .sRGB
    }

    /// Whether `useSRGBBacking` has been applied, for the self-test.
    var isBackedInSRGB: Bool {
        colorSpace?.cgColorSpace?.name == CGColorSpace.sRGB
    }
}
