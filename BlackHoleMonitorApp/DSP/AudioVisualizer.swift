import Foundation
import Accelerate
import os.lock

/// Lock-protected hand-off of visualization frames from the audio thread to the UI.
/// The audio thread only uses `trylock` (a frame is skipped if the UI holds the lock);
/// the UI polls with a timer instead of the audio thread dispatching blocks to main.
final class VisualizationTap {
    static let bandCount = 16
    static let scopeCount = 256

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let bands: UnsafeMutablePointer<Float>
    private let scope: UnsafeMutablePointer<Float>
    private var bandsVersion: UInt64 = 0
    private var scopeVersion: UInt64 = 0

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        bands = UnsafeMutablePointer<Float>.allocate(capacity: Self.bandCount)
        bands.initialize(repeating: 0, count: Self.bandCount)
        scope = UnsafeMutablePointer<Float>.allocate(capacity: Self.scopeCount)
        scope.initialize(repeating: 0, count: Self.scopeCount)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        bands.deallocate()
        scope.deallocate()
    }

    // Audio thread
    func publishBands(_ values: UnsafePointer<Float>) {
        guard os_unfair_lock_trylock(lock) else { return }
        bands.update(from: values, count: Self.bandCount)
        bandsVersion &+= 1
        os_unfair_lock_unlock(lock)
    }

    func publishScope(_ values: UnsafePointer<Float>) {
        guard os_unfair_lock_trylock(lock) else { return }
        scope.update(from: values, count: Self.scopeCount)
        scopeVersion &+= 1
        os_unfair_lock_unlock(lock)
    }

    // Main thread
    func readBands(lastVersion: inout UInt64) -> [Float]? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard bandsVersion != lastVersion else { return nil }
        lastVersion = bandsVersion
        return Array(UnsafeBufferPointer(start: bands, count: Self.bandCount))
    }

    func readScope(lastVersion: inout UInt64) -> [Float]? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard scopeVersion != lastVersion else { return nil }
        lastVersion = scopeVersion
        return Array(UnsafeBufferPointer(start: scope, count: Self.scopeCount))
    }
}

/// Computes the 16-band spectrum (20 fps) and the oscilloscope trace (60 fps)
/// from the output signal. Audio thread only; no allocation after `init`.
///
/// Updates are scheduled by sample count, so the FFT runs 20 times per second
/// whatever the hardware buffer size, always over the latest 1024 samples.
final class AudioVisualizer {
    static let fftSize = 1024
    private static let scopeWindow = 512  // decimated by 2 to 256 points
    private static let bandEdgesHz: [Double] = [32, 45, 63, 90, 125, 180, 250, 355, 500, 710,
                                                1000, 1400, 2000, 4000, 8000, 12000, 16000]
    // Bars fall to half their height per spectrum frame (20 fps)
    private static let decayRate: Float = 0.5

    private let tap: VisualizationTap
    private let spectrumInterval: Int
    private let scopeInterval: Int

    private let fftSetup: vDSP_DFT_Setup
    private let history: UnsafeMutablePointer<Float>  // mono, circular, fftSize
    private var historyIndex = 0
    private let window: UnsafeMutablePointer<Float>
    private let realIn: UnsafeMutablePointer<Float>
    private let imagIn: UnsafeMutablePointer<Float>
    private let realOut: UnsafeMutablePointer<Float>
    private let imagOut: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let bands: UnsafeMutablePointer<Float>
    private let scope: UnsafeMutablePointer<Float>
    private let binRanges: [(start: Int, end: Int)]  // read-only after init

    private var samplesSinceSpectrum = 0
    private var samplesSinceScope = 0
    private var scopeAutoGain: Float = 4.0

    init?(sampleRate: Double, tap: VisualizationTap) {
        let n = Self.fftSize
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return nil }
        fftSetup = setup
        self.tap = tap
        spectrumInterval = max(1, Int(sampleRate / 20))
        scopeInterval = max(1, Int(sampleRate / 60))

        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        history = buffer(n)
        window = buffer(n)
        realIn = buffer(n)
        imagIn = buffer(n)
        realOut = buffer(n)
        imagOut = buffer(n)
        magnitudes = buffer(n / 2)
        bands = buffer(VisualizationTap.bandCount)
        scope = buffer(VisualizationTap.scopeCount)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        binRanges = Self.makeBinRanges(sampleRate: sampleRate, fftSize: n)
    }

    deinit {
        vDSP_DFT_DestroySetup(fftSetup)
        for p in [history, window, realIn, imagIn, realOut, imagOut, magnitudes, bands, scope] {
            p.deallocate()
        }
    }

    /// FFT bin range of each band at this sample rate (each band gets at least one bin).
    static func makeBinRanges(sampleRate: Double, fftSize: Int) -> [(start: Int, end: Int)] {
        let half = fftSize / 2
        var ranges: [(start: Int, end: Int)] = []
        var previousEnd = 1  // skip DC
        for band in 0..<VisualizationTap.bandCount {
            let lo = Int((bandEdgesHz[band] * Double(fftSize) / sampleRate).rounded())
            let hi = Int((bandEdgesHz[band + 1] * Double(fftSize) / sampleRate).rounded())
            let start = min(max(lo, previousEnd), half - 1)
            let end = min(max(hi, start + 1), half)
            ranges.append((start, end))
            previousEnd = end
        }
        return ranges
    }

    func process(_ data: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        let n = Self.fftSize
        for frame in 0..<frameCount {
            let left = data[frame * channels]
            let right = channels > 1 ? data[frame * channels + 1] : left
            history[historyIndex] = (left + right) * 0.5
            historyIndex = (historyIndex + 1) & (n - 1)
        }

        samplesSinceSpectrum += frameCount
        if samplesSinceSpectrum >= spectrumInterval {
            samplesSinceSpectrum = 0
            computeSpectrum()
        }
        samplesSinceScope += frameCount
        if samplesSinceScope >= scopeInterval {
            samplesSinceScope = 0
            computeScope()
        }
    }

    private func computeSpectrum() {
        let n = Self.fftSize
        // Unroll the circular history, oldest sample first
        let tail = n - historyIndex
        realIn.update(from: history + historyIndex, count: tail)
        (realIn + tail).update(from: history, count: historyIndex)
        vDSP_vmul(realIn, 1, window, 1, realIn, 1, vDSP_Length(n))
        imagIn.update(repeating: 0, count: n)

        vDSP_DFT_Execute(fftSetup, realIn, imagIn, realOut, imagOut)

        var split = DSPSplitComplex(realp: realOut, imagp: imagOut)
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(n / 2))

        for (band, range) in binRanges.enumerated() {
            var peak: Float = 0
            vDSP_maxv(magnitudes + range.start, 1, &peak, vDSP_Length(range.end - range.start))
            // -14 dB .. +46 dB -> 0 .. 1
            let db = 20.0 * log10f(max(peak, 1e-10))
            let level = max(0.0, min(1.0, (db + 14.0) / 60.0))
            bands[band] = level > bands[band] ? level : bands[band] * Self.decayRate
        }
        tap.publishBands(bands)
    }

    private func computeScope() {
        let n = Self.fftSize
        let count = VisualizationTap.scopeCount
        let start = (historyIndex - Self.scopeWindow + n) & (n - 1)
        var peak: Float = 0
        for i in 0..<count {
            let s = history[(start + i * 2) & (n - 1)]
            scope[i] = s
            peak = max(peak, abs(s))
        }

        // Auto-gain towards ~0.5 peak: fast attack (avoid clipping), slow release
        let targetGain: Float = peak > 0.001 ? (0.5 / peak) : scopeAutoGain
        let clampedGain = min(max(targetGain, 1.0), 8.0)
        if clampedGain < scopeAutoGain {
            scopeAutoGain = scopeAutoGain * 0.6 + clampedGain * 0.4
        } else {
            scopeAutoGain = scopeAutoGain * 0.95 + clampedGain * 0.05
        }
        var gain = scopeAutoGain
        vDSP_vsmul(scope, 1, &gain, scope, 1, vDSP_Length(count))
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(scope, 1, &lo, &hi, scope, 1, vDSP_Length(count))
        tap.publishScope(scope)
    }
}
