import Foundation

/// Keeps the playback ring buffer near its target fill level by nudging the
/// resampling ratio (input and output devices run on independent clocks).
///
/// Proportional control with a hysteresis dead zone and exponential smoothing,
/// so the ratio never jumps audibly. Used only from the input audio thread.
final class DriftController {
    let threshold: Int = 512          // Frames of error before correction kicks in
    let hysteresisZone: Int = 256     // Dead zone where the ratio returns to 1.0
    let maxAdjustment: Double = 0.001 // ±0.1%
    private let smoothingFactor: Double = 0.1

    private var currentRatio: Double = 1.0
    private var targetRatio: Double = 1.0

    /// - Returns: ratio adjustment (> 1.0 produces more output frames to fill the
    ///   buffer, < 1.0 produces fewer to drain it).
    func calculateRatio(availableFrames: Int, targetFrames: Int) -> Double {
        let diff = availableFrames - targetFrames
        let scale = Double(max(targetFrames, 1))

        if abs(diff) < hysteresisZone {
            targetRatio = 1.0
        } else if diff > threshold {
            // Buffer too full: produce fewer frames
            let overflow = Double(diff - threshold) / scale
            targetRatio = 1.0 - min(overflow * 0.0005, maxAdjustment)
        } else if diff < -threshold {
            // Buffer too empty: produce more frames
            let underflow = Double(-diff - threshold) / scale
            targetRatio = 1.0 + min(underflow * 0.0005, maxAdjustment)
        }

        currentRatio += smoothingFactor * (targetRatio - currentRatio)
        currentRatio = max(1.0 - maxAdjustment, min(1.0 + maxAdjustment, currentRatio))
        return currentRatio
    }

    func reset() {
        currentRatio = 1.0
        targetRatio = 1.0
    }
}
