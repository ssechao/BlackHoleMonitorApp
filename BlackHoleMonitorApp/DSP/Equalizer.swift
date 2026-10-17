import Foundation

/// 8-band peaking equalizer (RBJ biquads, Q = 1, transposed direct form II).
///
/// Gains are converted to coefficients on the main thread and published through
/// a `ParameterMailbox` as a plain SIMD struct. The audio thread swaps
/// coefficients without touching the filter state, so moving a slider no longer
/// resets the filters (which caused clicks) and no Swift array is ever shared
/// between threads.
final class Equalizer {
    static let frequencies: [Float] = [60, 120, 250, 500, 1000, 2000, 4000, 8000]
    static let bandCount = 8

    struct Coefficients {
        var b0 = SIMD8<Float>(repeating: 1)
        var b1 = SIMD8<Float>(repeating: 0)
        var b2 = SIMD8<Float>(repeating: 0)
        var a1 = SIMD8<Float>(repeating: 0)
        var a2 = SIMD8<Float>(repeating: 0)
        var isFlat = true
    }

    private static let antiDenormal: Float = 1e-25

    let sampleRate: Float
    private let mailbox = ParameterMailbox(Coefficients())

    // Audio-thread state
    private var coefficients = Coefficients()
    private var coefficientsVersion: UInt64 = 0
    private var z1L = SIMD8<Float>(repeating: 0)
    private var z2L = SIMD8<Float>(repeating: 0)
    private var z1R = SIMD8<Float>(repeating: 0)
    private var z2R = SIMD8<Float>(repeating: 0)

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
    }

    /// Main thread. `gains` in dB, one per band.
    func setGains(_ gains: [Float]) {
        mailbox.publish(Self.makeCoefficients(gains: gains, sampleRate: sampleRate))
    }

    static func makeCoefficients(gains: [Float], sampleRate: Float) -> Coefficients {
        var c = Coefficients()
        c.isFlat = true
        for band in 0..<bandCount {
            let gainDB = gains.indices.contains(band) ? gains[band] : 0
            if abs(gainDB) > 0.01 { c.isFlat = false }
            let A = powf(10.0, gainDB / 40.0)
            let w0 = 2.0 * Float.pi * frequencies[band] / sampleRate
            let alpha = sinf(w0) / 2.0  // Q = 1
            let cosw0 = cosf(w0)
            let a0 = 1 + alpha / A
            c.b0[band] = (1 + alpha * A) / a0
            c.b1[band] = (-2 * cosw0) / a0
            c.b2[band] = (1 - alpha * A) / a0
            c.a1[band] = (-2 * cosw0) / a0
            c.a2[band] = (1 - alpha / A) / a0
        }
        return c
    }

    /// Audio thread. Interleaved, in place. Channel 0 and 1 are filtered; other channels untouched.
    func process(_ data: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        mailbox.fetch(into: &coefficients, lastVersion: &coefficientsVersion)
        let c = coefficients
        if c.isFlat {
            // Bypass; clear state so re-enabling starts clean.
            z1L = .zero; z2L = .zero; z1R = .zero; z2R = .zero
            return
        }

        let stereo = channels > 1
        for frame in 0..<frameCount {
            let base = frame * channels
            data[base] = Self.cascade(data[base], c, &z1L, &z2L)
            if stereo {
                data[base + 1] = Self.cascade(data[base + 1], c, &z1R, &z2R)
            }
        }

        // Flush denormals in filter state once per buffer
        Self.flushDenormals(&z1L)
        Self.flushDenormals(&z2L)
        Self.flushDenormals(&z1R)
        Self.flushDenormals(&z2R)
    }

    @inline(__always)
    private static func flushDenormals(_ v: inout SIMD8<Float>) {
        let tiny = SIMD8<Float>(repeating: 1e-15)
        v.replace(with: 0, where: (v .< tiny) .& (v .> -tiny))
    }

    @inline(__always)
    private static func cascade(_ input: Float, _ c: Coefficients, _ z1: inout SIMD8<Float>, _ z2: inout SIMD8<Float>) -> Float {
        var x = input + antiDenormal
        for band in 0..<bandCount {
            let y = c.b0[band] * x + z1[band]
            z1[band] = c.b1[band] * x - c.a1[band] * y + z2[band]
            z2[band] = c.b2[band] * x - c.a2[band] * y
            x = y
        }
        return x
    }
}
