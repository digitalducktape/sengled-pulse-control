import Foundation

/// Command builders for the Sengled Pulse protocol.
///
/// The command set is documented by the open-source projects
/// amchen/sengled-pulse-classic and kernelorg/sengled-pulse-link; behavior on a real
/// Classic was verified separately (see README).
public enum PulseCommand {
    // Subsystems
    public static let mgmt: UInt8 = 0
    public static let lamp: UInt8 = 1
    public static let sound: UInt8 = 2
    public static let network: UInt8 = 4

    /// Keep this brightness slot unchanged.
    public static let keep: UInt8 = 0xFF

    // MARK: management

    public static func deviceInfo(_ dst: UInt32 = PulseAddress.master) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: mgmt, command: 0)
    }
    public static func handshake(_ dst: UInt32 = PulseAddress.master) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: mgmt, command: 1)
    }
    /// Lists the nodes the master knows (itself plus satellites).
    public static func listNodes() -> PulseFrame {
        PulseFrame(destination: PulseAddress.master, subsystem: mgmt, command: 2)
    }
    public static func nodeName(_ dst: UInt32) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: mgmt, command: 5)
    }
    public static func setName(_ name: String, _ dst: UInt32) -> PulseFrame {
        var body = [UInt8](repeating: 0, count: 16)
        let b = Array(name.utf8.prefix(13))
        body.replaceSubrange(0..<b.count, with: b)
        return PulseFrame(destination: dst, subsystem: mgmt, command: 4, body: body)
    }
    /// Makes the lamp blink ("config start" in sengled-pulse-link).
    public static func identify(_ dst: UInt32) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: mgmt, command: 7)
    }
    public static func identifyEnd(_ dst: UInt32) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: mgmt, command: 8)
    }
    /// Config item 0 = "Brightness Record" (light memory): 1 = restore the last
    /// brightness after a power cut, 0 = always come back at 100 %.
    public static func setConfig(item: UInt8, value: UInt8, _ dst: UInt32 = PulseAddress.all) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: mgmt, command: 11, body: [item, 0, value, 0])
    }
    public static func queryConfig(item: UInt8, _ dst: UInt32 = PulseAddress.master) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: mgmt, command: 12, body: [item, 0])
    }

    // MARK: lamp

    /// Note the protocol's inverted flag: 0 = on, 1 = off.
    public static func lampPower(_ on: Bool, _ dst: UInt32 = PulseAddress.all) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: lamp, command: 0, body: [0, 0, on ? 0 : 1, 0])
    }
    /// Two brightness slots, 0…100, 0xFF = keep. The app uses (value, keep) for
    /// broadcast "group" brightness and (keep, value) for one node.
    public static func brightness(group: UInt8, own: UInt8, _ dst: UInt32) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: lamp, command: 1, body: [0, 0, group, own])
    }
    public static func queryLamp(_ dst: UInt32 = PulseAddress.master) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: lamp, command: 3, body: [0, 0])
    }

    // MARK: sound

    public static func channel(_ ch: UInt8, _ dst: UInt32 = PulseAddress.all) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: sound, command: 0, body: [0, 0, ch])
    }
    public static func equalizer(_ eq: UInt8, _ dst: UInt32 = PulseAddress.all) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: sound, command: 1, body: [0, 0, eq])
    }
    public static func mute(_ muted: Bool, _ dst: UInt32 = PulseAddress.all) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: sound, command: 2, body: [0, 0, muted ? 1 : 0])
    }
    public static func volume(_ v: UInt8, _ dst: UInt32 = PulseAddress.all) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: sound, command: 3, body: [0, 0, min(v, 100), 0xFF])
    }
    public static func querySpeaker(_ dst: UInt32 = PulseAddress.master) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: sound, command: 4, body: [0, 0])
    }

    // MARK: audio source

    /// 0 = 3.5 mm AUX, 1 = Bluetooth.
    public static func audioSource(_ src: UInt8, _ dst: UInt32 = PulseAddress.all) -> PulseFrame {
        PulseFrame(destination: dst, subsystem: network, command: 6, body: [0, 0, src])
    }
    public static func queryAudioSource() -> PulseFrame {
        PulseFrame(destination: PulseAddress.master, subsystem: network, command: 7)
    }
}

// MARK: - Decoded replies

public struct LampState: Equatable, Sendable {
    public var on: Bool
    public var group: UInt8
    public var own: UInt8
    /// Effective brightness 0…100: the lower of the group level and the bulb's own
    /// level (verified on real bulbs: 30/100 shows 30 %, 10/10 looks like 10 %).
    /// nil if the node has no lamp.
    public var level: Int? {
        let vals = [group, own].filter { $0 <= 100 }.map(Int.init)
        return vals.min()
    }
    public init?(_ f: PulseFrame) {
        guard f.is(1, 3), f.body.count >= 5 else { return nil }
        on = f.body[2] == 0
        group = f.body[3]
        own = f.body[4]
    }
}

public enum Equalizer: UInt8, CaseIterable, Sendable {
    case normal, pop, jazz, classic, rock, movie
    public var label: String { String(describing: self).capitalized }
}

public enum SoundChannel: UInt8, CaseIterable, Sendable {
    // The two reference projects disagree on 0/1 (left vs right). Labels follow the
    // Classic app; swap here if your bulbs turn out the other way round.
    case left = 0, right = 1, stereo = 2
    public var label: String { String(describing: self).capitalized }
}

public struct SpeakerState: Equatable, Sendable {
    public var channel: UInt8
    public var equalizer: UInt8
    public var muted: Bool
    public var volume: UInt8
    public init?(_ f: PulseFrame) {
        guard f.is(2, 4), f.body.count >= 6 else { return nil }
        channel = f.body[2]
        equalizer = f.body[3]
        muted = f.body[4] != 0
        volume = f.body[5]
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public var name: String
    public var productID: UInt32?
    public init?(_ f: PulseFrame) {
        guard f.is(0, 0) else { return nil }
        let p = f.body
        name = String(decoding: p.prefix(32).prefix { $0 != 0 }, as: UTF8.self)
        productID = p.count >= 36 ? PulseFrame.u32(p, 32) : nil
    }
}

public func decodeNodes(_ f: PulseFrame) -> [UInt32]? {
    guard f.is(0, 2), f.body.count >= 4 else { return nil }
    let p = f.body
    let count = Int(p[2]) | Int(p[3]) << 8
    return (0..<count).compactMap { i in
        let o = 4 + 4 * i
        return o + 4 <= p.count ? PulseFrame.u32(p, o) : nil
    }
}
