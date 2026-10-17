import Foundation

/// Instant vocal attenuation by 3-band Mid-Side processing.
///
/// Modern mixes spread vocals to the sides via reverb/delay/chorus, so plain
/// Mid-Side cancellation leaves the vocal effects. The signal is split into:
///   Bass  (< 120 Hz)        : untouched (kick, bass guitar)
///   Vocal (120 Hz - 5 kHz)  : center removed, sides partially attenuated
///   Air   (> 5 kHz)         : light center/side reduction (cymbals live here)
///
/// Audio thread only. `sampleRate` must be the rate of the processed signal
/// (the output rate, after resampling).
final class MidSideKaraoke {
    private let alphaLow: Float
    private let alphaHigh: Float

    private var lowL: Float = 0
    private var lowR: Float = 0
    private var belowAirL: Float = 0
    private var belowAirR: Float = 0

    init(sampleRate: Double) {
        let sr = Float(sampleRate)
        let bassFreq: Float = 120.0
        let airFreq: Float = 5000.0
        alphaLow = (2.0 * Float.pi * bassFreq) / (sr + 2.0 * Float.pi * bassFreq)
        alphaHigh = (2.0 * Float.pi * airFreq) / (sr + 2.0 * Float.pi * airFreq)
    }

    /// Interleaved, in place. Needs at least 2 channels (only the first 2 are processed).
    func process(_ data: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int, intensity: Float) {
        guard channels >= 2 else { return }

        let sideReduction = intensity * 0.4
        let airSideReduction = intensity * 0.15

        var lpfL = lowL, lpfR = lowR
        var hpfL = belowAirL, hpfR = belowAirR

        for frame in 0..<frameCount {
            let base = frame * channels
            let left = data[base]
            let right = data[base + 1]

            lpfL = alphaLow * left + (1.0 - alphaLow) * lpfL
            lpfR = alphaLow * right + (1.0 - alphaLow) * lpfR

            hpfL = alphaHigh * left + (1.0 - alphaHigh) * hpfL
            hpfR = alphaHigh * right + (1.0 - alphaHigh) * hpfR
            let airL = left - hpfL
            let airR = right - hpfR

            let vocalL = left - lpfL - airL
            let vocalR = right - lpfR - airR

            let vocalMid = (vocalL + vocalR) * 0.5 * (1.0 - intensity)
            let vocalSide = (vocalL - vocalR) * 0.5 * (1.0 - sideReduction)

            let airMid = (airL + airR) * 0.5 * (1.0 - intensity * 0.5)
            let airSide = (airL - airR) * 0.5 * (1.0 - airSideReduction)

            data[base]     = lpfL + (vocalMid + vocalSide) + (airMid + airSide)
            data[base + 1] = lpfR + (vocalMid - vocalSide) + (airMid - airSide)
        }

        lowL = lpfL; lowR = lpfR
        belowAirL = hpfL; belowAirR = hpfR
    }
}
