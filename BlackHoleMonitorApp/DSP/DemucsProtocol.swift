import Foundation

/// Wire protocol between the app and `ML/demucs_server.py` (version 2).
///
/// Every message starts with a 12-byte little-endian header:
///   magic (UInt32 "BHMD") | type (UInt32) | value (UInt32)
/// followed by an optional float32 little-endian payload:
///
///   HELLO      app -> server  value = sample rate (Hz)          no payload
///   HELLO_ACK  server -> app  value = protocol version          no payload
///   AUDIO      app -> server  value = frames   payload = frames x [L, R]
///   RESULT     server -> app  value = frames   payload = frames x [wetL, wetR, dryL, dryR]
///
/// RESULT carries the dry signal aligned with the separated one, so the app can
/// mix them with the current intensity without any time offset.
/// A new HELLO on the same connection resets the server stream (e.g. new sample rate).
enum DemucsProtocol {
    static let magic: UInt32 = 0x444D_4842  // "BHMD"
    static let version: UInt32 = 2
    static let headerSize = 12
    static let inputChannels = 2
    static let resultChannels = 4
    /// Sanity limit for a single message (about 10 s at 192 kHz)
    static let maxFramesPerMessage: UInt32 = 2_000_000

    enum MessageType: UInt32 {
        case hello = 1
        case helloAck = 2
        case audio = 3
        case result = 4
    }

    struct Header: Equatable {
        let type: MessageType
        let value: UInt32
    }

    enum DecodeError: Error, Equatable {
        case badMagic
        case unknownType(UInt32)
        case tooLarge(UInt32)
    }

    static func encodeHeader(_ type: MessageType, value: UInt32) -> Data {
        var data = Data(capacity: headerSize)
        for word in [magic, type.rawValue, value] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeHeader(_ data: Data) throws -> Header {
        precondition(data.count >= headerSize)
        func word(_ index: Int) -> UInt32 {
            let start = data.startIndex + index * 4
            return data[start..<start + 4].enumerated().reduce(UInt32(0)) { acc, byte in
                acc | UInt32(byte.element) << (8 * UInt32(byte.offset))
            }
        }
        guard word(0) == magic else { throw DecodeError.badMagic }
        guard let type = MessageType(rawValue: word(1)) else { throw DecodeError.unknownType(word(1)) }
        let value = word(2)
        if type == .audio || type == .result, value > maxFramesPerMessage {
            throw DecodeError.tooLarge(value)
        }
        return Header(type: type, value: value)
    }

    /// Payload size in bytes that follows `header`.
    static func payloadSize(of header: Header) -> Int {
        switch header.type {
        case .audio: return Int(header.value) * inputChannels * MemoryLayout<Float>.size
        case .result: return Int(header.value) * resultChannels * MemoryLayout<Float>.size
        case .hello, .helloAck: return 0
        }
    }

    /// Complete AUDIO message for interleaved stereo frames.
    static func encodeAudio(_ samples: UnsafePointer<Float>, frames: Int) -> Data {
        var data = encodeHeader(.audio, value: UInt32(frames))
        // Apple platforms are little-endian, so float bytes are already in wire order.
        data.append(UnsafeBufferPointer(start: samples, count: frames * inputChannels))
        return data
    }

    /// Decodes a payload into floats (copy, so alignment of `payload` does not matter).
    static func decodeFloats(_ payload: Data) -> [Float] {
        var floats = [Float](repeating: 0, count: payload.count / MemoryLayout<Float>.size)
        floats.withUnsafeMutableBytes { _ = payload.copyBytes(to: $0) }
        return floats
    }
}
