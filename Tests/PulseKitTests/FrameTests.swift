import Testing
@testable import PulseKit

struct FrameTests {
    @Test func lampOnBroadcastMatchesDocumentedFrame() {
        // Example frame from the amchen/sengled-pulse-classic README.
        let expected: [UInt8] = [0x7E, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x00, 0x7E]
        #expect(PulseCommand.lampPower(true).wireBytes == expected)
    }

    @Test func handshakeIs16Bytes() {
        let f = PulseCommand.handshake().rawBytes
        #expect(f.count == 16)
        #expect(Array(f[1..<9]) == [0xFE, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])
    }

    @Test func frameLengthsMatchReferenceTool() {
        #expect(PulseCommand.setConfig(item: 0, value: 1).rawBytes.count == 20)
        #expect(PulseCommand.queryConfig(item: 0).rawBytes.count == 18)
        #expect(PulseCommand.queryLamp().rawBytes.count == 18)
        #expect(PulseCommand.channel(2).rawBytes.count == 19)
        #expect(PulseCommand.volume(40).rawBytes.count == 20)
        #expect(PulseCommand.setName("Kitchen", 0).rawBytes.count == 32)
    }

    @Test func escapingRoundTrips() {
        let f = PulseFrame(destination: 0x7E7D_0000, subsystem: 1, command: 1, body: [0, 0, 0x7E, 0x7D])
        let wire = f.wireBytes
        #expect(wire.count > f.rawBytes.count)
        var r = PulseFrameReader()
        #expect(r.feed(wire) == [f])
    }

    @Test func readerSkipsStatusTextAndSplitsFrames() {
        let a = PulseCommand.handshake(), b = PulseCommand.queryLamp()
        var r = PulseFrameReader()
        let stream = Array("\r\nSS=01,001896030AF0\r\n".utf8) + a.wireBytes + b.wireBytes
        // Feed in two arbitrary chunks.
        let first = r.feed(Array(stream[0..<30]))
        let rest = r.feed(Array(stream[30...]))
        #expect(first + rest == [a, b])
    }

    @Test func badChecksumIsDropped() {
        var raw = PulseCommand.handshake().rawBytes
        raw[13] ^= 1
        #expect(PulseFrame.parse(raw) == nil)
    }

    @Test func decodesLampAndNodes() {
        let lamp = PulseFrame(source: 0, destination: PulseAddress.client, subsystem: 1, command: 3,
                              body: [0, 0, 0, 255, 40])
        #expect(LampState(lamp)?.on == true)
        #expect(LampState(lamp)?.level == 40)
        let dimmed = PulseFrame(source: 0, destination: PulseAddress.client, subsystem: 1, command: 3,
                                body: [0, 0, 0, 0x1E, 0x64, 0, 0, 0, 0])   // captured from the real bulb
        #expect(LampState(dimmed)?.level == 30)
        let both = PulseFrame(source: 0, destination: PulseAddress.client, subsystem: 1, command: 3,
                              body: [0, 0, 0, 10, 10, 0, 0, 0, 0])
        #expect(LampState(both)?.level == 10)

        let nodes = PulseFrame(source: 0, destination: PulseAddress.client, subsystem: 0, command: 2,
                               body: [0, 0, 2, 0, 0, 0, 0, 0, 0x56, 0x00, 0x02, 0x00])
        #expect(decodeNodes(nodes) == [0, 0x0002_0056])
    }
}
