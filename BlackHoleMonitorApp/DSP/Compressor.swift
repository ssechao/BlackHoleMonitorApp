import Foundation
import Accelerate

/// Block-based peak compressor (32-frame blocks, attack/release envelope).
///
/// Parameters are set from the main thread with `setParameters` and handed to
/// the audio thread through a `ParameterMailbox`; `process` never blocks or allocates.
final class Compressor {
    struct Parameters {
        var thresholdLinear: Float = 0.1
        var ratio: Float = 4.0
        var attackCoeff: Float = 0.0
        var releaseCoeff: Float = 0.0
        var makeupGainLinear: Float = 1.0
    }

    static let blockSize = 32

    let sampleRate: Float
    let channels: Int

    private let mailbox = ParameterMailbox(Parameters())
    // Audio-thread state
    private var params = Parameters()
    private var paramsVersion: UInt64 = 0
    private(set) var envelope: Float = 0.0

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = Float(sampleRate)
        self.channels = channels
    }

    /// Main thread. Times in milliseconds, levels in dB.
    func setParameters(threshold: Float, ratio: Float, attack: Float, release: Float, makeupGain: Float) {
        // Coefficients are per block, since the envelope is updated once per block.
        let blockRate = sampleRate / Float(Self.blockSize)
        mailbox.publish(Parameters(
            thresholdLinear: powf(10.0, threshold / 20.0),
            ratio: max(ratio, 1.0),
            attackCoeff: expf(-1.0 / (max(attack, 0.01) * 0.001 * blockRate)),
            releaseCoeff: expf(-1.0 / (max(release, 0.01) * 0.001 * blockRate)),
            makeupGainLinear: powf(10.0, makeupGain / 20.0)
        ))
    }

    /// Audio thread. Interleaved, in place.
    func process(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        mailbox.fetch(into: &params, lastVersion: &paramsVersion)
        let p = params

        if p.thresholdLinear < 0.00001 {
            var gain = p.makeupGainLinear
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(frameCount * channels))
            return
        }

        let exponent = 1.0 - 1.0 / p.ratio
        var frameIndex = 0
        while frameIndex < frameCount {
            let framesThisBlock = min(Self.blockSize, frameCount - frameIndex)
            let block = data + frameIndex * channels
            let samples = vDSP_Length(framesThisBlock * channels)

            var blockPeak: Float = 0.0
            vDSP_maxmgv(block, 1, &blockPeak, samples)

            let coeff = blockPeak > envelope ? p.attackCoeff : p.releaseCoeff
            envelope = coeff * envelope + (1.0 - coeff) * blockPeak
            if envelope < 1e-15 { envelope = 0 }  // avoid denormals on silence

            var gain = p.makeupGainLinear
            if envelope > p.thresholdLinear {
                gain *= powf(p.thresholdLinear / envelope, exponent)
            }
            vDSP_vsmul(block, 1, &gain, block, 1, samples)
            frameIndex += framesThisBlock
        }
    }

    func reset() {
        envelope = 0
    }
}
