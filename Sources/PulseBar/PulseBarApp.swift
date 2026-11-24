import SwiftUI
import PulseKit

@main
struct PulseBarApp: App {
    @StateObject private var model = PulseModel()
    @StateObject private var updates = UpdateChecker()

    init() {
        // `PulseBar --screenshot out.png [--dark]` renders the panel with sample data and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            Screenshot.render(to: args[i + 1], dark: args.contains("--dark"))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PulsePanel()
                .environmentObject(model)
                .environmentObject(updates)
                .onAppear { if !model.keepLightsOff { model.connect() } }
        } label: {
            Image(systemName: model.isConnected
                  ? (model.allOn ? "lightbulb.fill" : "lightbulb")
                  : "lightbulb.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PulsePanel: View {
    @EnvironmentObject var model: PulseModel
    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isConnected {
                Divider()
                LightRow(title: "All lights", id: PulseAddress.all,
                         on: model.allOn, level: model.allLevel, online: true)
                ForEach(model.nodes) { n in
                    LightRow(title: n.title, id: n.id, on: n.on, level: n.level, online: n.online)
                }
                Divider()
                speaker
                Divider()
                settings
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep lights off", isOn: $model.keepLightsOff)
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
                if let e = model.loginItemError {
                    Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text(model.keepLightsOff
                     ? (model.guardNote.isEmpty ? "Watching for the bulb…" : model.guardNote)
                     : "Whenever the bulb is free, switch its lights off and hand it back to the Echo.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = updates.available {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("Version \(r.version) is available").font(.callout)
                    Spacer()
                    Button("Download") { NSWorkspace.shared.open(r.url) }
                }
            }
            HStack(spacing: 14) {
                Button { NSWorkspace.shared.open(Links.project) } label: {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { NSWorkspace.shared.open(Links.support) } label: {
                    Label("Support this app", systemImage: "cup.and.saucer.fill")
                }
                Spacer()
            }
            .buttonStyle(.link).font(.callout)
            HStack {
                Toggle("Check for updates automatically", isOn: $updates.automatic)
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("Check now") { Task { await updates.check(manual: true) } }
                    .buttonStyle(.link).font(.caption)
            }
            if !updates.note.isEmpty {
                Text(updates.note).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") { Task { await model.refresh() } }.disabled(!model.isConnected)
                Spacer()
                Text("v\(updates.current)").font(.caption).foregroundStyle(.tertiary)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "speaker.wave.2.bubble.left").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("Sengled Pulse").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            if model.busy || model.status == .connecting { ProgressView().controlSize(.small) }
            switch model.status {
            case .connected: Button("Disconnect") { model.disconnect() }
            case .connecting: EmptyView()
            default: Button("Connect") { model.connect() }
                    .help("Takes the bulb from the Echo while connected. Disconnect to give it back.")
            }
        }
    }

    private var statusText: String {
        switch model.status {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected:
            let on = model.nodes.filter(\.online).count
            return "Connected · \(on) of \(model.nodes.count) bulbs reachable"
        case .failed(let m): return m
        }
    }

    private var speaker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound").font(.subheadline.bold())
            if let master = model.nodes.first(where: { $0.id == PulseAddress.master }) {
                HStack {
                    Button { model.setMuted(PulseAddress.all, !master.muted) } label: {
                        Image(systemName: master.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }.buttonStyle(.borderless)
                    CommitSlider(value: master.volume) { model.setVolume(PulseAddress.all, $0) }
                    Text("\(master.volume)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Picker("Equalizer", selection: Binding(get: { model.equalizer }, set: model.setEqualizer)) {
                ForEach(Equalizer.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Channel", selection: Binding(get: { model.channel }, set: model.setChannel)) {
                ForEach(SoundChannel.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Remember brightness after power cut",
                   isOn: Binding(get: { model.brightnessRecord }, set: model.setBrightnessRecord))
            Button("Sound-only mode (lights \(soundOnlyLevel)%, remembered)") { model.soundOnlyMode() }
                .disabled(!model.isConnected)
            Text("The bulbs only remember levels of \(soundOnlyLevel)% or more. Off and lower levels come back at 100% after the wall switch.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LightRow: View {
    @EnvironmentObject var model: PulseModel
    let title: String
    let id: UInt32
    let on: Bool
    let level: Int
    let online: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).fontWeight(id == PulseAddress.all ? .semibold : .regular)
                if !online { Text("offline").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if id != PulseAddress.all && online {
                    Button { model.identify(id) } label: { Image(systemName: "sparkle") }
                        .buttonStyle(.borderless).help("Blink this bulb")
                }
                Toggle("", isOn: Binding(get: { on }, set: { model.setPower(id, $0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            HStack {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                CommitSlider(value: level) { model.setLevel(id, $0) }
                Text("\(level)%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
        .disabled(!online)
        .opacity(online ? 1 : 0.5)
    }
}

/// A 0–100 slider that only reports when the drag ends, so we don't flood the slow bulb.
/// (Uses an ObservableObject rather than @State: the Command Line Tools lack SwiftUI's macro plugin.)
final class SliderDraft: ObservableObject { @Published var value: Double? }

struct CommitSlider: View {
    let value: Int
    let commit: (Int) -> Void
    @StateObject private var draft = SliderDraft()

    var body: some View {
        Slider(value: Binding(get: { draft.value ?? Double(value) }, set: { draft.value = $0 }),
               in: 0...100) { editing in   // no `step:`, which draws 101 tick marks on macOS
            if !editing, let d = draft.value {
                commit(Int(d.rounded()))
                draft.value = nil
            }
        }
    }
}
