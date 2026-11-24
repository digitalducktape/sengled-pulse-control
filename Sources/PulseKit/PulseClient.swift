import Foundation
import IOBluetooth

public enum PulseError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case connectFailed(String)
    case notConnected
    case timeout(String)

    public var description: String {
        switch self {
        case .deviceNotFound(let s): return "No paired Bluetooth device matches \"\(s)\". Pair the master bulb in System Settings → Bluetooth first."
        case .connectFailed(let s): return "Could not open the bulb's serial channel: \(s)"
        case .notConnected: return "Not connected to the bulb."
        case .timeout(let s): return "The bulb did not answer (\(s))."
        }
    }
}

/// Talks to a Pulse master bulb over its classic-Bluetooth SPP (RFCOMM) channel.
///
/// All IOBluetooth callbacks arrive on the main run loop, so the client is main-actor bound.
@MainActor
public final class PulseClient: NSObject {
    public private(set) var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var reader = PulseFrameReader()
    private var waiters: [(id: UUID, match: (PulseFrame) -> Bool, cont: CheckedContinuation<PulseFrame?, Never>)] = []
    private var sdpContinuation: CheckedContinuation<Void, Never>?
    private var basebandContinuation: CheckedContinuation<IOReturn, Never>?
    private var lastWrite = Date.distantPast

    /// Called for every frame sent ("TX") and received ("RX").
    public var log: ((String, PulseFrame) -> Void)?
    public var onDisconnect: (() -> Void)?
    /// Diagnostic messages (SDP results, reconnects).
    public var debugLog: ((String) -> Void)?
    /// Default reply timeout, seconds (3 s, as in kernelorg/sengled-pulse-link).
    public var replyTimeout: TimeInterval = 3
    /// Debug override for the RFCOMM channel (skips SDP).
    public var forcedChannel: BluetoothRFCOMMChannelID?

    public override init() { super.init() }

    public var isConnected: Bool { channel?.isOpen() ?? false }

    /// Paired devices that look like Pulse bulbs (name starts with C01- or contains "Pulse").
    public static func pairedPulseDevices() -> [IOBluetoothDevice] {
        let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return all.filter {
            let n = ($0.name ?? "").lowercased()
            return n.hasPrefix("c01-") || n.contains("pulse")
        }
    }

    /// Connect to a paired bulb by name or address (`00:18:96:03:0A:F0`). nil = first Pulse-looking device.
    public func connect(to nameOrAddress: String? = nil) async throws {
        if isConnected { return }
        let dev = try find(nameOrAddress)
        device = dev

        if !dev.isConnected() {
            let r = await openBaseband(dev)
            if r != kIOReturnSuccess {
                // Timeout here usually means another host (e.g. an Echo) holds the bulb:
                // it only accepts one Bluetooth host at a time.
                throw PulseError.connectFailed("baseband connection failed (\(hex(r))); is another device connected to the bulb?")
            }
        }

        let channelID: BluetoothRFCOMMChannelID
        if let forcedChannel {
            channelID = forcedChannel
        } else if let id = try? await sppChannel(dev) {
            channelID = id
        } else {
            // SDP sometimes comes back empty right after a power cycle; the Classic's
            // "SPP Dev" service has always been on channel 1.
            debugLog?("SDP found no SPP service, using channel 1")
            channelID = 1
        }

        var ch: IOBluetoothRFCOMMChannel?
        func open() -> IOReturn {
            ch = nil
            return dev.openRFCOMMChannelSync(&ch, withChannelID: channelID, delegate: self)
        }
        // The bulb refuses a new serial session for a few seconds after the previous
        // one closes: retry first, without touching the audio link.
        var r = open()
        for attempt in 1...3 where r != kIOReturnSuccess {
            debugLog?("RFCOMM refused (\(hex(r))), retry \(attempt)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            r = open()
        }
        // After a power cut the bulb reconnects to the Mac by itself, and on a link the
        // bulb started it refuses RFCOMM until the link is re-made from the Mac side.
        // (Verified Nov 2026.) This interrupts audio from the Mac for a few seconds.
        if r != kIOReturnSuccess {
            debugLog?("re-making the Bluetooth link from the Mac side")
            dev.closeConnection()
            for _ in 0..<20 where dev.isConnected() { try? await Task.sleep(nanoseconds: 500_000_000) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            _ = await openBaseband(dev)
            r = open()
            for attempt in 1...3 where r != kIOReturnSuccess {
                debugLog?("RFCOMM refused (\(hex(r))), retry \(attempt) after re-link")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                r = open()
            }
        }
        guard r == kIOReturnSuccess, let ch else {
            throw PulseError.connectFailed("RFCOMM channel \(channelID) refused (\(hex(r)))")
        }
        channel = ch
        reader = PulseFrameReader()
        // Handshake the master right after connecting (documented by amchen/sengled-pulse-classic).
        _ = try await request(PulseCommand.handshake())
    }

    public func disconnect() {
        channel?.close()
        channel = nil
        failWaiters()
    }

    /// Close the control channel and the Mac's whole Bluetooth link to the bulb, so
    /// another host (the Echo) can connect. The bulb accepts only one host at a time.
    public func release() async {
        disconnect()
        guard let dev = device ?? Self.pairedPulseDevices().first else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
        dev.closeConnection()
        for _ in 0..<20 where dev.isConnected() { try? await Task.sleep(nanoseconds: 500_000_000) }
    }

    /// Non-blocking baseband connect (the sync API freezes the UI for up to ~5 s).
    private func openBaseband(_ dev: IOBluetoothDevice) async -> IOReturn {
        await withCheckedContinuation { (c: CheckedContinuation<IOReturn, Never>) in
            basebandContinuation = c
            let r = dev.openConnection(self)
            if r != kIOReturnSuccess { finishBaseband(r) }
        }
    }

    fileprivate func finishBaseband(_ r: IOReturn) {
        basebandContinuation?.resume(returning: r)
        basebandContinuation = nil
    }

    // MARK: sending

    /// Fire and forget.
    public func send(_ frame: PulseFrame) async throws {
        guard let channel, channel.isOpen() else { throw PulseError.notConnected }
        // The bulb's CPU is slow: keep ~80 ms between frames like the reference tools.
        let gap = 0.08 - Date().timeIntervalSince(lastWrite)
        if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1e9)) }
        var bytes = frame.wireBytes
        let r = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        lastWrite = Date()
        log?("TX", frame)
        if r != kIOReturnSuccess { throw PulseError.connectFailed("write failed (\(hex(r)))") }
    }

    /// Send and wait for the reply with the same subsystem/command from the addressed node.
    /// Broadcast requests return the first reply.
    @discardableResult
    public func request(_ frame: PulseFrame, timeout: TimeInterval? = nil) async throws -> PulseFrame {
        let dst = frame.destination
        let match: (PulseFrame) -> Bool = { f in
            f.subsystem == frame.subsystem && f.command == frame.command
                && f.destination == PulseAddress.client
                && (dst == PulseAddress.all || f.source == dst)
        }
        let id = UUID()
        let t = timeout ?? replyTimeout
        let result: PulseFrame? = await withCheckedContinuation { cont in
            waiters.append((id, match, cont))
            Task { @MainActor in
                do { try await self.send(frame) } catch { self.resolve(id, nil) }
                try? await Task.sleep(nanoseconds: UInt64(t * 1e9))
                self.resolve(id, nil)
            }
        }
        guard let result else { throw PulseError.timeout("\(frame.subsystem)/\(frame.command)") }
        return result
    }

    private func resolve(_ id: UUID, _ f: PulseFrame?) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(returning: f)
    }

    private func failWaiters() {
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.cont.resume(returning: nil) }
    }

    private func received(_ bytes: [UInt8]) {
        for f in reader.feed(bytes) {
            log?("RX", f)
            if let i = waiters.firstIndex(where: { $0.match(f) }) {
                waiters.remove(at: i).cont.resume(returning: f)
            }
        }
    }

    // MARK: discovery

    private func find(_ query: String?) throws -> IOBluetoothDevice {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        if let q = query?.lowercased().replacingOccurrences(of: "-", with: ":") {
            if let d = paired.first(where: {
                ($0.addressString ?? "").lowercased().replacingOccurrences(of: "-", with: ":") == q
                    || ($0.name ?? "").lowercased() == q
            }) { return d }
            throw PulseError.deviceNotFound(query!)
        }
        guard let d = Self.pairedPulseDevices().first else { throw PulseError.deviceNotFound("C01-…") }
        return d
    }

    private func sppChannel(_ dev: IOBluetoothDevice) async throws -> BluetoothRFCOMMChannelID {
        let spp = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassSerialPort.rawValue))!
        // Always run a fresh SDP query: the cached record can be stale after the
        // bulb reboots.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sdpContinuation = c
            if dev.performSDPQuery(self) != kIOReturnSuccess { sdpDone() }
        }
        for case let rec as IOBluetoothSDPServiceRecord in dev.services ?? [] {
            debugLog?("SDP: \(rec.getServiceName() ?? "?") rfcomm=\(rfcommID(rec).map(String.init) ?? "-")")
        }
        if let id = rfcommID(dev.getServiceRecord(for: spp)) { return id }
        // Some modules publish SPP under a vendor UUID: take any RFCOMM service that isn't audio.
        for case let rec as IOBluetoothSDPServiceRecord in dev.services ?? [] {
            if let id = rfcommID(rec) { return id }
        }
        throw PulseError.connectFailed("the bulb advertises no serial (SPP) service")
    }

    private func rfcommID(_ rec: IOBluetoothSDPServiceRecord?) -> BluetoothRFCOMMChannelID? {
        guard let rec else { return nil }
        var id: BluetoothRFCOMMChannelID = 0
        return rec.getRFCOMMChannelID(&id) == kIOReturnSuccess ? id : nil
    }

    fileprivate func sdpDone() {
        sdpContinuation?.resume()
        sdpContinuation = nil
    }

    private func hex(_ r: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: r)) }
}

// MARK: - IOBluetooth delegates

extension PulseClient: IOBluetoothRFCOMMChannelDelegate {
    nonisolated public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                              data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { received(bytes) }
    }

    nonisolated public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            channel = nil
            failWaiters()
            onDisconnect?()
        }
    }

    // SDP completion (informal protocol on NSObject).
    @objc nonisolated public func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated { finishBaseband(status) }
    }

    @objc nonisolated public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated { sdpDone() }
    }
}

// MARK: - High-level API

extension PulseClient {
    public func nodes() async throws -> [UInt32] {
        decodeNodes(try await request(PulseCommand.listNodes())) ?? []
    }

    public func info(_ node: UInt32 = PulseAddress.master) async throws -> DeviceInfo? {
        DeviceInfo(try await request(PulseCommand.deviceInfo(node), timeout: 1.5))
    }

    public func lampState(_ node: UInt32 = PulseAddress.master) async throws -> LampState? {
        LampState(try await request(PulseCommand.queryLamp(node)))
    }

    public func speakerState(_ node: UInt32 = PulseAddress.master) async throws -> SpeakerState? {
        SpeakerState(try await request(PulseCommand.querySpeaker(node)))
    }

    /// level 0 switches the light off; 1…100 sets brightness and switches on.
    public func setLight(_ node: UInt32, level: Int) async throws {
        let v = UInt8(max(0, min(100, level)))
        if v == 0 { try await send(PulseCommand.lampPower(false, node)); return }
        if node == PulseAddress.all {
            // Classic app: broadcast sets the group level. (The Pulse Link's extra
            // "apply" frame (keep, 100) resets a Classic back to full brightness.)
            try await send(PulseCommand.brightness(group: v, own: PulseCommand.keep, node))
        } else {
            try await send(PulseCommand.brightness(group: PulseCommand.keep, own: v, node))
        }
        try await send(PulseCommand.lampPower(true, node))
    }

    public func setPower(_ node: UInt32, on: Bool) async throws {
        try await send(PulseCommand.lampPower(on, node))
    }

    /// "Brightness Record": true = restore the last brightness after a power cut.
    public func lightMemory(_ node: UInt32 = PulseAddress.master) async throws -> Bool? {
        let f = try await request(PulseCommand.queryConfig(item: 0, node))
        return f.body.count >= 3 ? f.body[2] != 0 : nil
    }

    public func setLightMemory(_ on: Bool) async throws {
        try await send(PulseCommand.setConfig(item: 0, value: on ? 1 : 0))
    }

    public func audioSource() async throws -> UInt8? {
        try await request(PulseCommand.queryAudioSource()).body.first
    }
}
