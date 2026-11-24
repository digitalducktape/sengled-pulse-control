import Foundation
import PulseKit
import ServiceManagement

struct NodeState: Identifiable, Equatable {
    let id: UInt32
    var online = false
    var on = false
    var level = 100
    var volume = 80
    var muted = false

    var title: String {
        id == PulseAddress.master ? "Master" : "Satellite \(String(format: "%04X", id & 0xFFFF))"
    }
}

/// The dimmest level the bulbs remember across a power cut (measured: 10 % sticks, 5 % does not).
let soundOnlyLevel = 10

@MainActor
final class PulseModel: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, failed(String) }

    @Published var status: Status = .disconnected
    @Published var nodes: [NodeState] = []
    @Published var brightnessRecord = false
    @Published var equalizer: Equalizer = .normal
    @Published var channel: SoundChannel = .stereo
    @Published var busy = false
    /// Guard: whenever the bulb is free, grab it, switch the lights off, let go.
    @Published var keepLightsOff = UserDefaults.standard.bool(forKey: "keepLightsOff") {
        didSet {
            UserDefaults.standard.set(keepLightsOff, forKey: "keepLightsOff")
            keepLightsOff ? startGuard() : stopGuard()
        }
    }
    @Published var guardNote = ""
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginItemError: String?

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "\(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
    private var guardTask: Task<Void, Never>?

    private let client = PulseClient()
    /// Sample-data model for the README screenshot: never touches Bluetooth.
    private var isPreview = false

    static func preview() -> PulseModel {
        let m = PulseModel(preview: true)
        m.status = .connected
        m.nodes = [
            NodeState(id: PulseAddress.master, online: true, on: true, level: 60, volume: 80),
            NodeState(id: 0x0000_B82D, online: true, on: true, level: 60, volume: 80),
            NodeState(id: 0x0003_6D80, online: false, on: false, level: 100, volume: 80),
        ]
        m.brightnessRecord = true
        m.equalizer = .classic
        m.isPreview = true
        m.keepLightsOff = true
        m.guardNote = "Lights already off (checked 9:41 PM)"
        return m
    }

    private init(preview: Bool) {}

    init() {
        client.onDisconnect = { [weak self] in
            self?.status = .disconnected
            self?.nodes = self?.nodes.map { var n = $0; n.online = false; return n } ?? []
        }
        client.debugLog = { NSLog("PulseBar: %@", $0) }
        if keepLightsOff { startGuard() }
    }

    var isConnected: Bool { status == .connected }
    var allOn: Bool { nodes.contains { $0.online && $0.on } }
    var allLevel: Int {
        let lit = nodes.filter { $0.online }
        return lit.isEmpty ? 100 : lit.map(\.level).reduce(0, +) / lit.count
    }

    // MARK: connection

    func connect() {
        guard status != .connecting, !isConnected else { return }
        status = .connecting
        Task {
            do {
                try await client.connect()
                status = .connected
                await refresh()
            } catch {
                status = .failed("\(error)")
            }
        }
    }

    /// Drops the Mac's whole Bluetooth link so the Echo can connect again.
    func disconnect() {
        status = .disconnected
        Task { await client.release() }
    }

    // MARK: keep-lights-off guard

    private func startGuard() {
        guard guardTask == nil, !isPreview else { return }
        guardNote = "Watching for the bulb…"
        guardTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await self.guardPass()
                try? await Task.sleep(nanoseconds: UInt64(pause * 1e9))
            }
        }
    }

    private func stopGuard() {
        guardTask?.cancel()
        guardTask = nil
        guardNote = ""
    }

    /// One attempt. Returns seconds to wait before the next one.
    private func guardPass() async -> TimeInterval {
        // Don't interfere while the panel is using the bulb.
        if status == .connected || status == .connecting { return 15 }
        guard !PulseClient.pairedPulseDevices().isEmpty else {
            guardNote = "No paired Pulse bulb"
            return 60
        }
        do {
            try await client.connect()
            let wasOn = ((try? await client.lampState(PulseAddress.master))?.on) ?? true
            if wasOn {
                try await client.setPower(PulseAddress.all, on: false)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await client.release()   // hand the bulb back so the Echo can connect
            let t = Date().formatted(date: .omitted, time: .shortened)
            guardNote = wasOn ? "Switched the lights off at \(t)" : "Lights already off (checked \(t))"
            // Lights off: check rarely, every check briefly takes the bulb.
            return wasOn ? 60 : 180
        } catch {
            NSLog("PulseBar guard: %@", "\(error)")
            client.disconnect()
            // Usually the Echo has the bulb; it accepts only one host at a time.
            guardNote = "Waiting: the bulb is busy with another device"
            return 10
        }
    }

    func refresh() async {
        guard isConnected else { return }
        busy = true
        defer { busy = false }
        let ids = (try? await client.nodes()).flatMap { $0.isEmpty ? nil : $0 } ?? [PulseAddress.master]
        var fresh: [NodeState] = []
        for id in ids {
            var n = nodes.first { $0.id == id } ?? NodeState(id: id)
            if let l = try? await client.lampState(id) {
                n.online = true
                n.on = l.on
                if let v = l.level { n.level = v }
            } else {
                n.online = false
            }
            if n.online, let s = try? await client.speakerState(id) {
                n.volume = Int(s.volume)
                n.muted = s.muted
                if id == PulseAddress.master {
                    equalizer = Equalizer(rawValue: s.equalizer) ?? equalizer
                    channel = SoundChannel(rawValue: s.channel) ?? channel
                }
            }
            fresh.append(n)
        }
        nodes = fresh
        if let m = try? await client.lightMemory() { brightnessRecord = m }
    }

    // MARK: actions

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { status = .failed("\(error)") }
        }
    }

    private func update(_ id: UInt32, _ change: (inout NodeState) -> Void) {
        for i in nodes.indices where id == PulseAddress.all || nodes[i].id == id { change(&nodes[i]) }
    }

    func setPower(_ id: UInt32, _ on: Bool) {
        update(id) { $0.on = on }
        run { try await self.client.setPower(id, on: on) }
    }

    func setLevel(_ id: UInt32, _ level: Int) {
        update(id) { $0.level = level; $0.on = level > 0 }
        run { try await self.client.setLight(id, level: level) }
    }

    func setVolume(_ id: UInt32, _ v: Int) {
        update(id) { $0.volume = v }
        run { try await self.client.send(PulseCommand.volume(UInt8(v), id)) }
    }

    func setMuted(_ id: UInt32, _ m: Bool) {
        update(id) { $0.muted = m }
        run { try await self.client.send(PulseCommand.mute(m, id)) }
    }

    func setEqualizer(_ e: Equalizer) {
        equalizer = e
        run { try await self.client.send(PulseCommand.equalizer(e.rawValue)) }
    }

    func setChannel(_ c: SoundChannel) {
        channel = c
        run { try await self.client.send(PulseCommand.channel(c.rawValue)) }
    }

    func setBrightnessRecord(_ on: Bool) {
        brightnessRecord = on
        run { try await self.client.setLightMemory(on) }
    }

    func identify(_ id: UInt32) {
        run {
            try await self.client.send(PulseCommand.identify(id))
            try await Task.sleep(nanoseconds: 4_000_000_000)
            try await self.client.send(PulseCommand.identifyEnd(id))
        }
    }

    /// Brightness Record on + every bulb at the dimmest level that survives a power cut.
    func soundOnlyMode() {
        brightnessRecord = true
        update(PulseAddress.all) { $0.level = soundOnlyLevel; $0.on = true }
        run {
            try await self.client.setLightMemory(true)
            try await self.client.setLight(PulseAddress.all, level: soundOnlyLevel)
        }
    }
}
