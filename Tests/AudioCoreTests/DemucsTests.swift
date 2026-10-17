import XCTest
@testable import AudioCore

final class DemucsProtocolTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        let data = DemucsProtocol.encodeHeader(.result, value: 66150)
        XCTAssertEqual(data.count, DemucsProtocol.headerSize)
        XCTAssertEqual(Array(data.prefix(4)), Array("BHMD".utf8))
        let header = try DemucsProtocol.decodeHeader(data)
        XCTAssertEqual(header, DemucsProtocol.Header(type: .result, value: 66150))
        XCTAssertEqual(DemucsProtocol.payloadSize(of: header), 66150 * 4 * 4)
    }

    func testRejectsGarbage() {
        // Old v1 servers start their replies with a bare sample count
        var legacy = Data([0x00, 0x02, 0x00, 0x00])
        legacy.append(contentsOf: [UInt8](repeating: 0, count: 8))
        XCTAssertThrowsError(try DemucsProtocol.decodeHeader(legacy)) {
            XCTAssertEqual($0 as? DemucsProtocol.DecodeError, .badMagic)
        }
        var badType = DemucsProtocol.encodeHeader(.hello, value: 0)
        badType[4] = 99
        XCTAssertThrowsError(try DemucsProtocol.decodeHeader(badType))
        let huge = DemucsProtocol.encodeHeader(.audio, value: UInt32.max)
        XCTAssertThrowsError(try DemucsProtocol.decodeHeader(huge)) {
            XCTAssertEqual($0 as? DemucsProtocol.DecodeError, .tooLarge(UInt32.max))
        }
    }

    func testDecodeHeaderFromSlice() throws {
        // Data received from the network can be a slice with a non-zero startIndex
        let full = Data([1, 2, 3]) + DemucsProtocol.encodeHeader(.helloAck, value: 2)
        let slice = full[3...]
        XCTAssertEqual(try DemucsProtocol.decodeHeader(slice), DemucsProtocol.Header(type: .helloAck, value: 2))
    }

    func testAudioMessageLayout() throws {
        let samples: [Float] = [0.5, -0.5, 1, -1]
        let message = samples.withUnsafeBufferPointer { DemucsProtocol.encodeAudio($0.baseAddress!, frames: 2) }
        let header = try DemucsProtocol.decodeHeader(message)
        XCTAssertEqual(header, DemucsProtocol.Header(type: .audio, value: 2))
        XCTAssertEqual(message.count, DemucsProtocol.headerSize + DemucsProtocol.payloadSize(of: header))
        let payload = message[(message.startIndex + DemucsProtocol.headerSize)...]
        XCTAssertEqual(DemucsProtocol.decodeFloats(payload), samples)
    }

    func testDecodeFloatsFromUnalignedData() {
        let floats: [Float] = [1.5, -2.25, 3]
        var bytes = Data([0xFF])
        floats.withUnsafeBufferPointer { bytes.append($0) }
        XCTAssertEqual(DemucsProtocol.decodeFloats(bytes.dropFirst()), floats)
    }
}

final class DemucsBridgeTests: XCTestCase {
    func testInputIsForwardedAndOutputSilentUntilResults() {
        let bridge = DemucsBridge(sampleRate: 1000)
        var data: [Float] = [0.1, 0.2, 0.3, 0.4]
        data.withUnsafeMutableBufferPointer { bridge.process($0.baseAddress!, frameCount: 2, channels: 2, intensity: 1) }
        XCTAssertEqual(data, [0, 0, 0, 0], "No live signal mixed with the delayed stream")

        var sent = [Float](repeating: 0, count: 4)
        let n = sent.withUnsafeMutableBufferPointer { bridge.toServer.readAvailable(into: $0.baseAddress!, maxFrames: 2) }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(sent, [0.1, 0.2, 0.3, 0.4])
    }

    func testResultMixesAlignedDryAndWet() {
        let sampleRate = 1000.0
        let bridge = DemucsBridge(sampleRate: sampleRate)
        let frames = 200
        // wet = 1, dry = 0.5 on both channels
        let result = [[Float]](repeating: [1, 1, 0.5, 0.5], count: frames).flatMap { $0 }
        result.withUnsafeBufferPointer { bridge.receiveResult($0.baseAddress!, frames: frames) }

        let leadIn = Int(sampleRate * DemucsBridge.leadInSeconds)
        XCTAssertEqual(bridge.fromServer.availableFrames, leadIn + frames)

        var out = [Float](repeating: 0, count: (leadIn + frames) * 2)
        out.withUnsafeMutableBufferPointer { bridge.process($0.baseAddress!, frameCount: leadIn + frames, channels: 2, intensity: 0.25) }
        XCTAssertEqual(out[0], 0, "Lead-in silence first")
        // 0.25 * wet + 0.75 * dry = 0.625
        XCTAssertEqual(out[(leadIn + 150) * 2], 0.625, accuracy: 1e-6)
        XCTAssertEqual(out[(leadIn + 150) * 2 + 1], 0.625, accuracy: 1e-6)
    }

    func testMultichannelUsesFirstTwoChannels() {
        let bridge = DemucsBridge(sampleRate: 1000)
        var data: [Float] = [1, 2, 3, 4, 5, 6]  // 2 frames x 3 channels
        data.withUnsafeMutableBufferPointer { bridge.process($0.baseAddress!, frameCount: 2, channels: 3, intensity: 1) }
        var sent = [Float](repeating: 0, count: 4)
        _ = sent.withUnsafeMutableBufferPointer { bridge.toServer.readAvailable(into: $0.baseAddress!, maxFrames: 2) }
        XCTAssertEqual(sent, [1, 2, 4, 5])
        XCTAssertEqual(data[2], 3, "Extra channels untouched")
    }
}
