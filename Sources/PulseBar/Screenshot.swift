import AppKit
import SwiftUI

/// Renders the menu bar panel with sample data into a PNG (for the README), offscreen:
/// no screen-recording permission and no Bluetooth needed.
@MainActor
enum Screenshot {
    static func render(to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSAppearance.current = appearance

        let root = PulsePanel()
            .environmentObject(PulseModel.preview())
            .environmentObject(UpdateChecker(autoStart: false))
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        // A key window in an active app, so switches and buttons draw in their active
        // (accent-colored) state. It's placed off every screen and never visible.
        let window = KeyableWindow(contentRect: host.frame.offsetBy(dx: -10_000, dy: -10_000),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // let controls finish drawing

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(Int(size.width))×\(Int(size.height)) pt)")
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
