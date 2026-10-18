import Foundation

/// Real-time side of the Demucs karaoke: two FIFOs between the output audio
/// thread and the network queue. One bridge exists per audio session (its
/// sample rate is fixed); the network client attaches to the current one.
///
/// The AI path outputs the *delayed* stream coming back from the server
/// (separated + aligned dry signal). It never mixes the live signal with the
/// delayed one, which would produce an echo.
final class DemucsBridge {
    static let maxBlockFrames = 4096
    /// Silence inserted before the stream (re)starts, absorbs server jitter.
    static let leadInSeconds = 0.4

    let sampleRate: Double
    /// Audio thread -> network: interleaved stereo input.
    let toServer: RingBuffer
    /// Network -> audio thread: interleaved [wetL, wetR, dryL, dryR].
    let fromServer: RingBuffer

    private let mixScratch: UnsafeMutablePointer<Float>
    private let zeros: UnsafeMutablePointer<Float>
    private static let zeroChunkFrames = 1024

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        toServer = RingBuffer(capacityFrames: Int(sampleRate * 2), channels: DemucsProtocol.inputChannels)
        fromServer = RingBuffer(capacityFrames: Int(sampleRate * 12), channels: DemucsProtocol.resultChannels)
        mixScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxBlockFrames * DemucsProtocol.resultChannels)
        mixScratch.initialize(repeating: 0, count: Self.maxBlockFrames * DemucsProtocol.resultChannels)
        zeros = UnsafeMutablePointer<Float>.allocate(capacity: Self.zeroChunkFrames * DemucsProtocol.resultChannels)
        zeros.initialize(repeating: 0, count: Self.zeroChunkFrames * DemucsProtocol.resultChannels)
    }

    deinit {
        mixScratch.deallocate()
        zeros.deallocate()
    }

    // MARK: - Audio thread

    /// Replaces `data` (interleaved, `channels` >= 2, only the first two are used)
    /// with the delayed karaoke stream, mixed with its aligned dry signal.
    func process(_ data: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int, intensity: Float) {
        guard channels >= 2 else { return }
        var offset = 0
        while offset < frameCount {
            let frames = min(Self.maxBlockFrames, frameCount - offset)
            let block = data + offset * channels
            processBlock(block, frames: frames, channels: channels, intensity: intensity)
            offset += frames
        }
    }

    private func processBlock(_ data: UnsafeMutablePointer<Float>, frames: Int, channels: Int, intensity: Float) {
        if channels == DemucsProtocol.inputChannels {
            toServer.write(data, frames: frames)
        } else {
            // Pack the first two channels (reuse mixScratch as temporary)
            for frame in 0..<frames {
                mixScratch[frame * 2] = data[frame * channels]
                mixScratch[frame * 2 + 1] = data[frame * channels + 1]
            }
            toServer.write(mixScratch, frames: frames)
        }

        fromServer.read(mixScratch, frames: frames)
        let wet = intensity
        let dry = 1.0 - intensity
        for frame in 0..<frames {
            let s = frame * DemucsProtocol.resultChannels
            data[frame * channels] = mixScratch[s] * wet + mixScratch[s + 2] * dry
            data[frame * channels + 1] = mixScratch[s + 1] * wet + mixScratch[s + 3] * dry
        }
    }

    // MARK: - Network queue

    /// Stores a RESULT payload. Inserts the lead-in silence when the stream (re)starts.
    func receiveResult(_ samples: UnsafePointer<Float>, frames: Int) {
        let channels = DemucsProtocol.resultChannels
        if fromServer.availableFrames == 0 {
            var leadIn = Int(sampleRate * Self.leadInSeconds)
            while leadIn > 0 {
                let n = min(leadIn, Self.zeroChunkFrames)
                fromServer.write(zeros, frames: n)
                leadIn -= n
            }
        }
        // Small chunks keep the lock hold time short for the audio thread
        var offset = 0
        while offset < frames {
            let n = min(1024, frames - offset)
            fromServer.write(samples + offset * channels, frames: n)
            offset += n
        }
    }

    func resetStreams() {
        toServer.reset()
        fromServer.reset()
    }
}
