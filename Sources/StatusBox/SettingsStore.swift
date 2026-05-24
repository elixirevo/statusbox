import AppKit
import Combine
import Foundation

final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings

    private let defaults: UserDefaults
    private let key = "StatusBox.AppSettings.v3"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .defaults
        }
        refreshDisplays()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        persist(copy)
    }

    func refreshDisplays() {
        update { settings in
            let now = Date()
            if settings.defaultDisplayMode == .box && !settings.boxFeatureEnabled {
                settings.defaultDisplayMode = .menuBar
            }
            for screen in NSScreen.screens {
                let id = screen.statusBoxDisplayId
                var policy = settings.displayPolicies[id] ?? DisplayPolicy(
                    displayId: id,
                    displayName: screen.localizedName,
                    mode: settings.defaultDisplayMode,
                    lastSeenAt: now
                )
                policy.displayName = screen.localizedName
                policy.lastSeenAt = now
                if policy.mode == .box && !settings.boxFeatureEnabled {
                    policy.mode = .menuBar
                }
                settings.displayPolicies[id] = policy

            }
        }
    }

    func policy(for screen: NSScreen) -> DisplayPolicy {
        settings.displayPolicies[screen.statusBoxDisplayId] ?? DisplayPolicy(
            displayId: screen.statusBoxDisplayId,
            displayName: screen.localizedName,
            mode: settings.defaultDisplayMode,
            lastSeenAt: Date()
        )
    }

    func range(for screen: NSScreen) -> HiddenRange? {
        settings.hiddenRanges[screen.statusBoxDisplayId]
    }

    var hasAnyRange: Bool {
        !settings.hiddenRanges.isEmpty
    }

    func setPolicy(displayId: String, mode: DisplayMode) {
        update { settings in
            var policy = settings.displayPolicies[displayId] ?? DisplayPolicy(
                displayId: displayId,
                displayName: displayId,
                mode: mode,
                lastSeenAt: Date()
            )
            policy.mode = mode
            settings.displayPolicies[displayId] = policy
        }
    }

    func setRange(_ range: HiddenRange) {
        update { settings in
            settings.hiddenRanges[range.displayId] = range.normalized
        }
    }

    func removeRange(displayId: String) {
        update { settings in
            settings.hiddenRanges.removeValue(forKey: displayId)
        }
    }

    private func persist(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
