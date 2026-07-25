import Foundation

/// A colour in sRGB, with components on 0...1 and no alpha.
///
/// No alpha because the bar is opaque over the terminal's own background, and a
/// translucent chrome was rejected upstream of this package: `macos-glass-*` is
/// desaturated by macOS while the window is inactive, which is precisely when
/// the owner is scanning other panes' bars.
///
/// Not `NSColor`, and not `CGColor`, because this package must not import AppKit
/// or CoreGraphics. That boundary is what keeps the whole suite running in
/// milliseconds with no Metal, no linking, and no signing.
public struct RGB: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Components are clamped to 0...1 on the way in, in the same spirit as
    /// `Anchor.init` canonicalizing its URL: two colours the app cannot tell
    /// apart must not compare unequal, and a component above 1 read out of a
    /// config file would push ``relativeLuminance`` above 1, which drives
    /// ``contrastRatio(against:)`` below 1 and makes
    /// ``PaneTheme/readable(_:on:minimumRatio:)`` reject every candidate it is
    /// given.
    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    /// Accepts `#RRGGBB` and `#RGB`, with or without the leading hash, in either
    /// case. Nil otherwise.
    ///
    /// Case insensitive and hash optional because the values that reach this come
    /// from the owner's ghostty config (`background #141414`) and from pasted
    /// palette tables, which are inconsistent about both.
    public init?(hex: String) {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let digits = body.lowercased()
        guard digits.allSatisfy(Self.hexDigits.contains) else { return nil }

        let sixDigits: String
        switch digits.count {
        // `#RGB` is `#RRGGBB` with every digit doubled, which is the CSS rule.
        // Padding with zeroes instead would turn `#fff` into `#f0f0f0`, a colour
        // the author did not ask for.
        case 3: sixDigits = digits.map { "\($0)\($0)" }.joined()
        case 6: sixDigits = digits
        default: return nil
        }

        let characters = Array(sixDigits)
        guard let red = UInt8(String(characters[0 ... 1]), radix: 16),
              let green = UInt8(String(characters[2 ... 3]), radix: 16),
              let blue = UInt8(String(characters[4 ... 5]), radix: 16)
        else { return nil }
        self.init(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    /// A colour from 8-bit components, which is the form theme palettes are
    /// published in.
    ///
    /// ``PaneTheme/darkPastel`` is built from this rather than from `#rrggbb`
    /// literals, because a literal would need to force unwrap ``init(hex:)``, and
    /// a force unwrap inside a `static let` turns a one-character typo into a
    /// crash on the first paint instead of a compile error.
    public static func eightBit(_ red: Int, _ green: Int, _ blue: Int) -> RGB {
        RGB(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    /// `#rrggbb`, lowercase, spelled the way the owner's ghostty config spells it
    /// so a value read out of baia can be pasted straight back into it.
    public var hexString: String {
        let (red, green, blue) = clampedComponents
        return String(
            format: "#%02x%02x%02x",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    /// Linear interpolation towards `other`, in sRGB rather than in a perceptual
    /// space.
    ///
    /// sRGB is the right space here because the results are drawn over ghostty's
    /// own output, which the GPU also composites in sRGB. A perceptually even
    /// blend would produce a bar background that disagrees with the terminal
    /// background it is derived from by a visible step.
    public func blended(with other: RGB, fraction: Double) -> RGB {
        // Clamped so a caller's out-of-range fraction cannot overshoot past
        // `other` and come back as a colour on the far side of it, which reads as
        // the blend running backwards.
        let amount = Self.clamped(fraction)
        let (red, green, blue) = clampedComponents
        let (otherRed, otherGreen, otherBlue) = other.clampedComponents
        return RGB(
            red: red + (otherRed - red) * amount,
            green: green + (otherGreen - green) * amount,
            blue: blue + (otherBlue - blue) * amount
        )
    }

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        let (red, green, blue) = clampedComponents
        return 0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    /// The WCAG contrast ratio, 1 for a colour against itself and 21 for black
    /// against white. Symmetric, since the lighter of the pair always goes on
    /// top.
    public func contrastRatio(against other: RGB) -> Double {
        let mine = relativeLuminance
        let theirs = other.relativeLuminance
        return (max(mine, theirs) + 0.05) / (min(mine, theirs) + 0.05)
    }

    /// Mirrors libghostty's own dark test, `0.299r + 0.587g + 0.114b < 128` on
    /// 0...255.
    ///
    /// Deliberately not ``relativeLuminance``, so baia agrees with the terminal
    /// about which theme it is in. The two disagree across a wide band of mid
    /// greys, and disagreeing means baia would draw light-theme chrome around a
    /// surface ghostty is rendering as dark.
    public var isDark: Bool {
        let (red, green, blue) = clampedComponents
        return (0.299 * red + 0.587 * green + 0.114 * blue) * 255 < 128
    }

    /// The components with any out-of-range value repaired.
    ///
    /// ``init(red:green:blue:)`` already clamps, but the three properties are
    /// `var`, so the app can assign to one afterwards. Every piece of maths in
    /// this type reads through here rather than through the stored properties,
    /// which is what keeps a mutated colour from producing a luminance outside
    /// 0...1.
    private var clampedComponents: (red: Double, green: Double, blue: Double) {
        (Self.clamped(red), Self.clamped(green), Self.clamped(blue))
    }

    /// The sRGB transfer function's inverse, one component at a time.
    ///
    /// The threshold is 0.04045, where the curve and the linear toe actually
    /// meet. WCAG's own text carried 0.03928 for years, and the difference is a
    /// third of one 8-bit step, so no colour pair either value is used on changes
    /// verdict. Using the value that matches the sRGB spec avoids having to
    /// explain that every time this is read.
    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    /// Clamps to 0...1.
    private static func clamped(_ value: Double) -> Double {
        // `min(max(...))` rather than `value.clamped(to:)`, which the standard
        // library does not have, and rather than a `switch` on ranges, which
        // silently accepts a NaN by falling through to the default.
        min(max(0, value), 1)
    }

    /// The only characters a hex colour may be spelled with, after lowercasing.
    ///
    /// An explicit set rather than `Character.isHexDigit`, which is true for a
    /// wider alphabet than `UInt8(_:radix: 16)` accepts, the fullwidth forms `０`
    /// through `Ｆ` among them. A validator looser than the parser it guards
    /// leaves the real rejection to a `guard let` three lines further down whose
    /// `else` every reader takes for unreachable.
    private static let hexDigits = Set("0123456789abcdef")
}
