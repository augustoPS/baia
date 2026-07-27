import Foundation

/// A colour in CIELAB, and the CIEDE2000 difference between two of them.
///
/// Internal, and reached through ``RGB/perceptualDistance(to:)``. Nothing outside
/// this package needs a Lab value: the package's whole vocabulary is sRGB because
/// that is what the terminal composites in, and Lab exists here only because
/// "these two colours look different" cannot be answered in sRGB.
///
/// Split out of `RGB.swift` rather than nested in it because it is checked
/// against published data rather than against itself. Sharma, Wu and Dalal
/// published a test set with the CIEDE2000 paper precisely because the formula's
/// discontinuities, the hue-angle mean across 0/360 and the arctangent of a zero
/// chroma, are wrong in a great many implementations of it. `PerceptualDistanceTests`
/// runs eight of those rows.
struct Lab: Sendable, Equatable {
    var lightness: Double
    var a: Double
    var b: Double

    /// The CIEDE2000 colour difference, with all three weighting factors at 1.
    ///
    /// `kL`, `kC` and `kH` are the parametric factors for viewing conditions,
    /// which for the textile industry are 2, 1 and 1. They stay at 1 here: the
    /// colours being compared are self-luminous patches on a screen, which is the
    /// condition the formula was fitted under.
    static func deltaE2000(_ first: Lab, _ second: Lab) -> Double {
        let chroma1 = (first.a * first.a + first.b * first.b).squareRoot()
        let chroma2 = (second.a * second.a + second.b * second.b).squareRoot()
        let chromaMean = (chroma1 + chroma2) / 2

        // The `a` axis is stretched in the low-chroma region, which is what makes
        // near-neutral pairs read as further apart than raw CIELAB says. `25^7` is
        // the constant from the paper, not a tuning knob.
        let seventh = pow(chromaMean, 7)
        let stretch = 0.5 * (1 - (seventh / (seventh + pow(25, 7))).squareRoot())

        let a1 = (1 + stretch) * first.a
        let a2 = (1 + stretch) * second.a
        let primeChroma1 = (a1 * a1 + first.b * first.b).squareRoot()
        let primeChroma2 = (a2 * a2 + second.b * second.b).squareRoot()

        let hue1 = hueAngle(a: a1, b: first.b)
        let hue2 = hueAngle(a: a2, b: second.b)

        let deltaLightness = second.lightness - first.lightness
        let deltaChroma = primeChroma2 - primeChroma1

        // A hue difference is meaningless when either colour is neutral, since a
        // neutral has no hue to differ in. Returning 0 rather than whatever
        // `atan2(0, 0)` produced is the first of the two discontinuities the
        // reference data exists to catch.
        let chromaProduct = primeChroma1 * primeChroma2
        var deltaHueAngle = 0.0
        if chromaProduct != 0 {
            deltaHueAngle = hue2 - hue1
            if deltaHueAngle > 180 { deltaHueAngle -= 360 }
            if deltaHueAngle < -180 { deltaHueAngle += 360 }
        }
        let deltaHue = 2 * chromaProduct.squareRoot() * sin(radians(deltaHueAngle / 2))

        let lightnessMean = (first.lightness + second.lightness) / 2
        let primeChromaMean = (primeChroma1 + primeChroma2) / 2

        // The second discontinuity: the mean of two hue angles either side of the
        // 0/360 seam. Averaging 350 and 10 naively gives 180, the opposite hue, and
        // an implementation that does it scores the blue rows of the reference data
        // a long way out.
        var hueMean = hue1 + hue2
        if chromaProduct != 0 {
            if abs(hue1 - hue2) <= 180 {
                hueMean = (hue1 + hue2) / 2
            } else if hue1 + hue2 < 360 {
                hueMean = (hue1 + hue2 + 360) / 2
            } else {
                hueMean = (hue1 + hue2 - 360) / 2
            }
        }

        let weighting = 1
            - 0.17 * cos(radians(hueMean - 30))
            + 0.24 * cos(radians(2 * hueMean))
            + 0.32 * cos(radians(3 * hueMean + 6))
            - 0.20 * cos(radians(4 * hueMean - 63))

        let lightnessScale = 1
            + (0.015 * pow(lightnessMean - 50, 2))
            / (20 + pow(lightnessMean - 50, 2)).squareRoot()
        let chromaScale = 1 + 0.045 * primeChromaMean
        let hueScale = 1 + 0.015 * primeChromaMean * weighting

        // The rotation term, which only bites in the blue region around 275°. It is
        // what makes a pair differing solely in the sign of `a` score 7.18 rather
        // than 4.51, and an implementation that drops it looks right everywhere
        // else.
        let meanSeventh = pow(primeChromaMean, 7)
        let rotationChroma = 2 * (meanSeventh / (meanSeventh + pow(25, 7))).squareRoot()
        let rotationAngle = 30 * exp(-pow((hueMean - 275) / 25, 2))
        let rotation = -sin(radians(2 * rotationAngle)) * rotationChroma

        let lightnessTerm = deltaLightness / lightnessScale
        let chromaTerm = deltaChroma / chromaScale
        let hueTerm = deltaHue / hueScale
        return (
            lightnessTerm * lightnessTerm
                + chromaTerm * chromaTerm
                + hueTerm * hueTerm
                + rotation * chromaTerm * hueTerm
        ).squareRoot()
    }

    /// The hue angle in degrees on 0..<360, and 0 for a neutral.
    private static func hueAngle(a: Double, b: Double) -> Double {
        guard a != 0 || b != 0 else { return 0 }
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
