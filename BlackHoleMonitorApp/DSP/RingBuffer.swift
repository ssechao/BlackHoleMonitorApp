import Foundation
import os.lock

/// Interleaved multi-channel FIFO shared between two threads.
///
/// All storage is allocated once in `init`; `write`/`read` never allocate and
/// only hold the lock for a bounded `memcpy`. `os_unfair_lock` donates priority
/// to its owner, so a lower-priority writer cannot starve an audio thread.
///
/// Playback behaviour (`read`):
/// - **Priming**: after start or after an underrun, output stays silent until
///   `targetFrames` are buffered. Under CPU overload this produces one clean gap
///   instead of a burst of tiny dropouts (crackles).
/// - **Adaptive latency**: if `latencyStepFrames` > 0, each underrun (after the
///   first priming) raises the target by that amount, up to `maxTargetFrames`.
///   The audio session uses a step of 0 so visio echo cancellation keeps a short delay.
/// - **Fades**: short fade-out on underrun and fade-in on resume, to avoid clicks.
final class RingBuffer {
    static let fadeFrames = 64

    let channels: Int
    let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let lastFrame: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private var readFrame = 0
    private var writeFrame = 0
    private var available = 0

    private var target: Int
    private let maxTarget: Int
    private let latencyStep: Int
    private var primed = false
    private var silent = true
    private var underruns = 0
    private var emergencyDropEnabled = false

    init(capacityFrames: Int, channels: Int, targetFrames: Int = 0, maxTargetFrames: Int? = nil, latencyStepFrames: Int = 0) {
        precondition(capacityFrames > 0 && channels > 0)
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.target = min(targetFrames, capacityFrames)
        self.maxTarget = max(self.target, min(maxTargetFrames ?? targetFrames, capacityFrames / 2))
        self.latencyStep = latencyStepFrames

        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0, count: capacityFrames * channels)
        lastFrame = UnsafeMutablePointer<Float>.allocate(capacity: channels)
        lastFrame.initialize(repeating: 0, count: channels)
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lastFrame.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - State

    var availableFrames: Int { withLock { available } }
    var targetFrames: Int { withLock { target } }
    /// Underruns that happened after playback had started.
    var underrunCount: Int { withLock { underruns } }

    /// When enabled, a buffer more than 2× the target is drained 64 frames per write
    /// (last-resort drift handling when input and output clocks diverge).
    func setEmergencyDropEnabled(_ enabled: Bool) {
        withLock { emergencyDropEnabled = enabled }
    }

    func reset() {
        withLock {
            readFrame = 0
            writeFrame = 0
            available = 0
            primed = false
            silent = true
            lastFrame.update(repeating: 0, count: channels)
        }
    }

    // MARK: - Write

    /// Appends `frames` interleaved frames. When full, the oldest frames are overwritten.
    func write(_ data: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        if emergencyDropEnabled && target > 0 && available > target * 2 {
            skip(min(64, available - target))
        }

        var source = data
        var count = frames
        if count > capacityFrames {
            source += (count - capacityFrames) * channels
            count = capacityFrames
        }
        let overflow = available + count - capacityFrames
        if overflow > 0 {
            skip(overflow)
        }

        let firstPart = min(count, capacityFrames - writeFrame)
        (storage + writeFrame * channels).update(from: source, count: firstPart * channels)
        if count > firstPart {
            storage.update(from: source + firstPart * channels, count: (count - firstPart) * channels)
        }
        writeFrame = (writeFrame + count) % capacityFrames
        available += count
    }

    // MARK: - Read

    /// Reads up to `maxFrames` frames without any priming, fading or padding.
    /// - Returns: number of frames copied.
    func readAvailable(into out: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let count = min(maxFrames, available)
        copyOut(out, frames: count)
        return count
    }

    /// Fills exactly `frames` frames for playback (see type documentation).
    /// - Returns: number of frames that came from the buffer; the rest is fade/silence.
    @discardableResult
    func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        if !primed && available > 0 && available >= target {
            primed = true
        }

        var got = 0
        if primed {
            got = min(frames, available)
            copyOut(out, frames: got)
            if got < frames {
                primed = false
                underruns += 1
                if latencyStep > 0 {
                    target = min(target + latencyStep, maxTarget)
                }
            }
        }

        if got > 0 && silent {
            let fade = min(Self.fadeFrames, got)
            for frame in 0..<fade {
                let gain = Float(frame) / Float(fade)
                for channel in 0..<channels {
                    out[frame * channels + channel] *= gain
                }
            }
        }
        if got > 0 {
            lastFrame.update(from: out + (got - 1) * channels, count: channels)
        }

        if got < frames {
            let remaining = frames - got
            let fade = silent && got == 0 ? 0 : min(Self.fadeFrames, remaining)
            for frame in 0..<remaining {
                let gain = frame < fade ? 1.0 - Float(frame) / Float(fade) : 0
                for channel in 0..<channels {
                    out[(got + frame) * channels + channel] = lastFrame[channel] * gain
                }
            }
            lastFrame.update(repeating: 0, count: channels)
            silent = true
        } else {
            silent = false
        }
        return got
    }

    // MARK: - Private (lock held)

    private func copyOut(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let firstPart = min(frames, capacityFrames - readFrame)
        out.update(from: storage + readFrame * channels, count: firstPart * channels)
        if frames > firstPart {
            (out + firstPart * channels).update(from: storage, count: (frames - firstPart) * channels)
        }
        skip(frames)
    }

    private func skip(_ frames: Int) {
        readFrame = (readFrame + frames) % capacityFrames
        available -= frames
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }
}
