import Foundation
import Testing

@testable import PaneChrome

/// The measure `derive` states its separation in.
///
/// Two colours one 8-bit step apart are unequal, and a rule that separated them
/// by inequality would report success for a difference nobody can see. So the
/// separation is graded in CIEDE2000, and CIEDE2000 has published test data, so
/// it is checked against that rather than against itself.
@Suite struct PerceptualDistanceTests {
    /// sRGB to CIELAB, against the values every colour tool publishes for the
    /// primaries.
    ///
    /// Checked separately from the metric below, because a wrong white point or a
    /// wrong transfer function is invisible in a ΔE00 test built from Lab inputs:
    /// those pairs never touch the conversion at all.
    @Test func theLabConversionAgreesWithThePublishedPrimaries() {
        let cases: [(String, Double, Double, Double)] = [
            ("#000000", 0, 0, 0),
            ("#ffffff", 100, 0, 0),
            ("#ff0000", 53.2408, 80.0925, 67.2032),
            ("#00ff00", 87.7347, -86.1827, 83.1793),
            ("#0000ff", 32.2970, 79.1875, -107.8602),
        ]
        for (hex, lightness, a, b) in cases {
            let lab = RGB(hex: hex)!.lab
            #expect(abs(lab.lightness - lightness) < 0.01, "L for \(hex)")
            #expect(abs(lab.a - a) < 0.01, "a for \(hex)")
            #expect(abs(lab.b - b) < 0.01, "b for \(hex)")
        }
    }

    /// Rows from Sharma, Wu and Dalal's CIEDE2000 test set, the data the formula's
    /// own authors published to catch the implementations that get it wrong.
    ///
    /// These are the rows that break a naive reading: the hue-angle mean across the
    /// 0/360 discontinuity (rows 1 and 4), the arctangent of a zero chroma (row 7),
    /// the rotation term in the blue region (row 21), and a pair that differs only
    /// in the sign of `a` (row 9), which a formula missing `RT` reports as 4.5
    /// rather than 7.2.
    @Test func theMetricMatchesTheReferenceDataForCIEDE2000() {
        let cases: [(Lab, Lab, Double)] = [
            (Lab(lightness: 50, a: 2.6772, b: -79.7751), Lab(lightness: 50, a: 0, b: -82.7485), 2.0425),
            (Lab(lightness: 50, a: -1.3802, b: -84.2814), Lab(lightness: 50, a: 0, b: -82.7485), 1.0000),
            (Lab(lightness: 50, a: 0, b: 0), Lab(lightness: 50, a: -1, b: 2), 2.3669),
            (Lab(lightness: 50, a: 2.49, b: -0.001), Lab(lightness: 50, a: -2.49, b: 0.0009), 7.1792),
            (
                Lab(lightness: 60.2574, a: -34.0099, b: 36.2677),
                Lab(lightness: 60.4626, a: -34.1751, b: 39.4387),
                1.2644
            ),
            (
                Lab(lightness: 61.2901, a: 3.7196, b: -5.3901),
                Lab(lightness: 61.4292, a: 2.2480, b: -4.9620),
                1.8731
            ),
            (
                Lab(lightness: 22.7233, a: 20.0904, b: -46.6940),
                Lab(lightness: 23.0331, a: 14.9730, b: -42.5619),
                2.0373
            ),
            (
                Lab(lightness: 6.7747, a: -0.2908, b: -2.4247),
                Lab(lightness: 5.8714, a: -0.0985, b: -2.2286),
                0.6377
            ),
        ]
        for (first, second, expected) in cases {
            #expect(abs(Lab.deltaE2000(first, second) - expected) < 0.0001)
            // Symmetric, which CIEDE2000 is and a mis-signed `RT` is not.
            #expect(abs(Lab.deltaE2000(second, first) - expected) < 0.0001)
        }
    }

    @Test func aColourIsZeroDistanceFromItself() {
        for hex in ["#141414", "#ff5555", "#b5d5ff", "#ffffff"] {
            let colour = RGB(hex: hex)!
            #expect(colour.perceptualDistance(to: colour) == 0)
        }
    }

    @Test func oneEightBitStepIsFarBelowTheAttentionFloor() {
        // The reason the floor is not spelled as inequality. These two differ, and
        // nothing about looking at them says so.
        let first = RGB.eightBit(0xB5, 0xD5, 0xFF)
        let second = RGB.eightBit(0xB5, 0xD5, 0xFE)
        #expect(first != second)
        #expect(first.perceptualDistance(to: second) < 1)
        #expect(first.perceptualDistance(to: second) < PaneTheme.minimumAttentionSeparation)
    }
}
