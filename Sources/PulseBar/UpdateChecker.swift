import AppKit
import Foundation
import PulseKit

enum Links {
    static let repo = "digitalducktape/sengled-pulse-control"
    static let project = URL(string: "https://github.com/\(repo)")!
    static let releases = URL(string: "https://github.com/\(repo)/releases")!
    static let support = URL(string: "https://buymeacoffee.com/digitalducktape")!
}

/// Checks GitHub Releases for a newer version: at launch, then once a day.
/// Sends no data about you or your bulbs, only an anonymous request for the latest release.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable { let version: String; let url: URL }

    @Published var available: Release?
    @Published var note = ""
    @Published var automatic = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "autoUpdateCheck")
            if automatic { start() } else { timer?.invalidate(); timer = nil }
        }
    }

    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    private var timer: Timer?

    init(autoStart: Bool = true) {
        if autoStart && automatic { start() }
    }

    func start() {
        Task { await check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check(manual: Bool = false) async {
        if manual { note = "Checking…" }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Links.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PulseBar/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                note = manual ? "Couldn't reach GitHub Releases." : ""
                return
            }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let url = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Links.releases
            if Version.isNewer(version, than: current) {
                available = Release(version: version, url: url)
                note = ""
            } else {
                available = nil
                note = manual ? "You're up to date (v\(current))." : ""
            }
        } catch {
            note = manual ? "Couldn't check for updates: \(error.localizedDescription)" : ""
        }
    }
}
