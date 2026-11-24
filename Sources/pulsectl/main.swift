import Foundation
import PulseKit

let usage = """
usage: pulsectl [--device NAME|ADDR] [--verbose] <command> [args]

  devices                 list paired Bluetooth devices that look like Pulse bulbs
  status                  master info, nodes, light and speaker state of every node
  on [NODE]               light on        (NODE: all (default), master, or 8-hex address)
  off [NODE]              light off
  light LEVEL [NODE]      brightness 0-100 (0 = off)
  volume LEVEL [NODE]     speaker volume 0-100
  mute | unmute [NODE]
  eq NAME [NODE]          normal pop jazz classic rock movie
  channel left|right|stereo [NODE]
  source aux|bluetooth
  memory [on|off]         "Brightness Record": restore last brightness after power loss
  identify NODE           make a bulb blink
  name NODE TEXT          rename a node (max 13 bytes)

debugging:
  --channel N             force an RFCOMM channel (skip SDP)
  scan-config [NODE]      read config items 0-31
  lamp-raw [NODE]         raw lamp-state reply
  raw-config ITEM VALUE NODE    write a raw config value and read it back
  raw-bright GROUP OWN [NODE]   send a raw brightness frame (255 = keep)
  release                 disconnect the Mac from the bulb so the Echo can connect
  reset-link              drop and reopen the Mac's Bluetooth link (interrupts audio)
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func node(_ s: String?) -> UInt32 {
    guard let s = s?.lowercased() else { return PulseAddress.all }
    switch s {
    case "all": return PulseAddress.all
    case "master": return PulseAddress.master
    default:
        guard let v = UInt32(s.replacingOccurrences(of: "0x", with: ""), radix: 16) else { fail("bad node \(s)") }
        return v
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var deviceQuery: String?
var verbose = false
var forcedChannel: UInt8?
while let a = args.first, a.hasPrefix("--") {
    args.removeFirst()
    switch a {
    case "--device": deviceQuery = args.isEmpty ? nil : args.removeFirst()
    case "--verbose", "--v": verbose = true
    case "--channel": forcedChannel = args.isEmpty ? nil : UInt8(args.removeFirst())
    default: fail(usage)
    }
}
guard let cmd = args.first else { print(usage); exit(0) }
let rest = Array(args.dropFirst())

if cmd == "devices" {
    for d in PulseClient.pairedPulseDevices() {
        print("\(d.name ?? "?")\t\(d.addressString ?? "?")\t\(d.isConnected() ? "connected" : "not connected")")
    }
    exit(0)
}

if cmd == "release" {
    // Disconnect the Mac from the bulb entirely so another host (the Echo) can take it.
    guard let d = PulseClient.pairedPulseDevices().first else { fail("no Pulse device paired") }
    print("closing: \(d.closeConnection())")
    for _ in 0..<20 where d.isConnected() { try? await Task.sleep(nanoseconds: 500_000_000) }
    print("disconnected: \(!d.isConnected())")
    exit(0)
}

if cmd == "reset-link" {
    // Drop the Mac's Bluetooth link to the bulb, wait until it is really gone, then
    // reconnect from the Mac side (interrupts audio briefly).
    guard let d = PulseClient.pairedPulseDevices().first else { fail("no Pulse device paired") }
    print("closing: \(d.closeConnection())")
    for _ in 0..<20 where d.isConnected() {
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    print("disconnected: \(!d.isConnected())")
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    print("opening: \(d.openConnection())")
    exit(0)
}

let client = PulseClient()
client.forcedChannel = forcedChannel
if verbose {
    client.log = { dir, f in print("  \(dir) \(f)  |  \(f.wireBytes.hex)") }
    client.debugLog = { print("  ·· \($0)") }
}

do {
    try await client.connect(to: deviceQuery)
    switch cmd {
    case "status":
        if let i = try? await client.info() {
            print("master: \(i.name)" + (i.productID.map { " (productID \($0))" } ?? ""))
        }
        let nodes = (try? await client.nodes()) ?? [PulseAddress.master]
        print("nodes: " + nodes.map(PulseAddress.describe).joined(separator: ", "))
        for n in nodes.isEmpty ? [PulseAddress.master] : nodes {
            let l = try? await client.lampState(n)
            let s = try? await client.speakerState(n)
            var line = "  \(PulseAddress.describe(n)):"
            if let l { line += " light \(l.on ? "on" : "off")" + (l.level.map { " \($0)%" } ?? " (no lamp)") }
            if let s {
                line += " | volume \(s.volume)%\(s.muted ? " muted" : "")"
                line += " eq \(Equalizer(rawValue: s.equalizer)?.label ?? "\(s.equalizer)")"
                line += " channel \(SoundChannel(rawValue: s.channel)?.label ?? "\(s.channel)")"
            }
            print(line)
        }
        if let m = try? await client.lightMemory() { print("brightness record: \(m ? "on" : "off")") }
        if let src = try? await client.audioSource() { print("audio source: \(src == 0 ? "AUX" : "Bluetooth")") }
    case "on": try await client.setPower(node(rest.first), on: true)
    case "off": try await client.setPower(node(rest.first), on: false)
    case "light":
        guard let v = rest.first.flatMap(Int.init) else { fail(usage) }
        try await client.setLight(node(rest.dropFirst().first), level: v)
    case "raw-bright":   // debugging: raw-bright GROUP OWN [NODE]
        guard rest.count >= 2, let g = UInt8(rest[0]), let o = UInt8(rest[1]) else { fail(usage) }
        try await client.send(PulseCommand.brightness(group: g, own: o, node(rest.dropFirst(2).first)))
    case "scan-config":  // read-only: query config items 0..31 on NODE (default master)
        let n = rest.first.map { node($0) } ?? PulseAddress.master
        for item in UInt8(0)...31 {
            if let f = try? await client.request(PulseCommand.queryConfig(item: item, n), timeout: 1.2) {
                print("item \(item): [\(f.body.hex)]")
            }
        }
    case "lamp-raw":     // read-only: raw lamp-state reply of NODE
        let f = try await client.request(PulseCommand.queryLamp(node(rest.first)))
        print("[\(f.body.hex)]")
    case "raw-config":   // debugging: raw-config ITEM VALUE NODE, then read back
        guard rest.count >= 3, let it = UInt8(rest[0]), let v = UInt8(rest[1]) else { fail(usage) }
        let n = node(rest[2])
        try await client.send(PulseCommand.setConfig(item: it, value: v, n))
        try await Task.sleep(nanoseconds: 500_000_000)
        let f = try await client.request(PulseCommand.queryConfig(item: it, n))
        print("read back: [\(f.body.hex)]")
    case "volume":
        guard let v = rest.first.flatMap(UInt8.init) else { fail(usage) }
        try await client.send(PulseCommand.volume(v, node(rest.dropFirst().first)))
    case "mute", "unmute": try await client.send(PulseCommand.mute(cmd == "mute", node(rest.first)))
    case "eq":
        guard let e = Equalizer.allCases.first(where: { $0.label.lowercased() == rest.first?.lowercased() }) else { fail(usage) }
        try await client.send(PulseCommand.equalizer(e.rawValue, node(rest.dropFirst().first)))
    case "channel":
        guard let c = SoundChannel.allCases.first(where: { $0.label.lowercased() == rest.first?.lowercased() }) else { fail(usage) }
        try await client.send(PulseCommand.channel(c.rawValue, node(rest.dropFirst().first)))
    case "source":
        guard let s = rest.first else { fail(usage) }
        try await client.send(PulseCommand.audioSource(s.lowercased().hasPrefix("aux") ? 0 : 1))
    case "memory":
        if let s = rest.first { try await client.setLightMemory(s == "on") }
        for n in (try? await client.nodes()) ?? [PulseAddress.master] {
            let m = try? await client.lightMemory(n)
            print("\(PulseAddress.describe(n)): brightness record \(m.map { $0 ? "on" : "off" } ?? "no reply")")
        }
    case "identify":
        try await client.send(PulseCommand.identify(node(rest.first)))
        try await Task.sleep(nanoseconds: 4_000_000_000)
        try await client.send(PulseCommand.identifyEnd(node(rest.first)))
    case "name":
        guard rest.count >= 2 else { fail(usage) }
        try await client.send(PulseCommand.setName(rest.dropFirst().joined(separator: " "), node(rest[0])))
    default: fail(usage)
    }
    try await Task.sleep(nanoseconds: 300_000_000) // let the last frame drain
    client.disconnect()
    try? await Task.sleep(nanoseconds: 700_000_000) // let the RFCOMM close reach the bulb
} catch {
    client.disconnect()
    try? await Task.sleep(nanoseconds: 700_000_000)
    fail("error: \(error)")
}
