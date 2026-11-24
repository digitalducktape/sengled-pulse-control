import Foundation

/// Well-known node addresses on the Pulse network.
public enum PulseAddress {
    /// The computer/phone side of the link.
    public static let client: UInt32 = 0xFFFF_FFFE
    /// Every node (master and all satellites).
    public static let all: UInt32 = 0xFFFF_FFFF
    /// The master bulb itself.
    public static let master: UInt32 = 0x0000_0000

    public static func describe(_ a: UInt32) -> String {
        switch a {
        case client: return "client"
        case all: return "all"
        case master: return "master"
        default: return String(format: "%08X", a)
        }
    }
}

/// One Pulse protocol frame.
///
/// Layout (unescaped, multi-byte fields little-endian):
///
///     [0]      7E flag
///     [1..4]   source address
///     [5..8]   destination address
///     [9]      subsystem (0 mgmt, 1 lamp, 2 sound, 4 audio source / network)
///     [10]     00
///     [11]     command id
///     [12]     00
///     [13..]   body
///     [n-3]    checksum = sum(bytes[1 ..< n-3]) mod 256
///     [n-2]    00
///     [n-1]    7E flag
///
/// On the wire, bytes between the flags are HDLC-escaped
/// (7D -> 7D 5D, 7E -> 7D 5E).
public struct PulseFrame: Equatable, CustomStringConvertible {
    public var source: UInt32
    public var destination: UInt32
    public var subsystem: UInt8
    public var command: UInt8
    public var body: [UInt8]

    public init(source: UInt32 = PulseAddress.client, destination: UInt32,
                subsystem: UInt8, command: UInt8, body: [UInt8] = []) {
        self.source = source
        self.destination = destination
        self.subsystem = subsystem
        self.command = command
        self.body = body
    }

    /// Unescaped bytes including both flags.
    public var rawBytes: [UInt8] {
        var f = [UInt8](repeating: 0, count: 16 + body.count)
        f[0] = 0x7E
        f.replaceSubrange(1..<5, with: le32(source))
        f.replaceSubrange(5..<9, with: le32(destination))
        f[9] = subsystem
        f[11] = command
        f.replaceSubrange(13..<(13 + body.count), with: body)
        f[f.count - 3] = PulseFrame.checksum(f)
        f[f.count - 1] = 0x7E
        return f
    }

    /// Escaped bytes, ready to write to the RFCOMM channel.
    public var wireBytes: [UInt8] { PulseFrame.escape(rawBytes) }

    public static func checksum(_ raw: [UInt8]) -> UInt8 {
        var sum: UInt32 = 0
        for b in raw[1..<(raw.count - 3)] { sum &+= UInt32(b) }
        return UInt8(sum & 0xFF)
    }

    /// Parse an unescaped frame (flags included). Returns nil when malformed or the checksum fails.
    public static func parse(_ raw: [UInt8]) -> PulseFrame? {
        guard raw.count >= 16, raw.first == 0x7E, raw.last == 0x7E,
              checksum(raw) == raw[raw.count - 3] else { return nil }
        return PulseFrame(source: u32(raw, 1), destination: u32(raw, 5),
                          subsystem: raw[9], command: raw[11],
                          body: Array(raw[13..<(raw.count - 3)]))
    }

    public static func escape(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x7E]
        for b in raw[1..<(raw.count - 1)] {
            if b == 0x7D || b == 0x7E { out += [0x7D, b ^ 0x20] } else { out.append(b) }
        }
        out.append(0x7E)
        return out
    }

    public static func unescape<S: Sequence>(_ bytes: S) -> [UInt8] where S.Element == UInt8 {
        var out: [UInt8] = []
        var esc = false
        for b in bytes {
            if esc { out.append(b ^ 0x20); esc = false }
            else if b == 0x7D { esc = true }
            else { out.append(b) }
        }
        return out
    }

    public func `is`(_ subsystem: UInt8, _ command: UInt8) -> Bool {
        self.subsystem == subsystem && self.command == command
    }

    public var description: String {
        "\(PulseAddress.describe(source)) -> \(PulseAddress.describe(destination)) "
            + "\(subsystem)/\(command) [\(body.hex)]"
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
}

extension Sequence where Element == UInt8 {
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Splits an RFCOMM byte stream into frames. Bytes outside 7E…7E
/// (e.g. the module's "\r\nSS=01,<addr>\r\n" status lines) are dropped.
public struct PulseFrameReader {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func feed(_ data: [UInt8]) -> [PulseFrame] {
        buffer += data
        var frames: [PulseFrame] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x7E) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            guard let stop = buffer[1...].firstIndex(of: 0x7E) else { break }
            if stop == 1 { buffer.removeFirst(); continue }   // 7E 7E: end + new start
            let raw = [0x7E] + PulseFrame.unescape(buffer[1..<stop]) + [0x7E]
            buffer.removeFirst(stop + 1)
            if let f = PulseFrame.parse(raw) { frames.append(f) }
        }
        return frames
    }
}
