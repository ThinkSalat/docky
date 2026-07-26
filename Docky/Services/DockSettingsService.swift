//
//  DockSettingsService.swift
//  Docky
//
//  Reads system Dock preferences (com.apple.dock) and republishes them.
//
//  Reads from `CFPreferences` on `com.apple.dock`.
//

import AppKit
import Combine
import Observation

@Observable
final class DockSettingsService {
    static let shared = DockSettingsService()

    enum Orientation: String {
        case bottom, left, right
    }

    enum MinimizeEffect: String {
        case genie, scale, suck
    }

    private(set) var orientation: Orientation = .bottom
    private(set) var tileSize: CGFloat = 48
    private(set) var largeSize: CGFloat = 64
    private(set) var magnification: Bool = false
    private(set) var autohide: Bool = false
    private(set) var autohideDelay: TimeInterval = 0.5
    private(set) var autohideTimeModifier: Double = 1.0
    private(set) var minimizeEffect: MinimizeEffect = .genie
    private(set) var minimizeToApplication: Bool = false
    private(set) var showRecents: Bool = true
    private(set) var showProcessIndicators: Bool = true

    /// Effective tile size used by every dock-rendering surface. Falls
    /// through to the active theme's `behavior.tileSize` when the user
    /// hasn't moved the size slider in this build; otherwise returns
    /// the user's value. Override marking happens in `setTileSize`.
    var displayTileSize: CGFloat {
        if !DockyPreferences.shared.isAppearanceOverridden(Keys.tileSize),
           let themed = ThemeManager.shared.activeManifest?.behavior?.tileSize,
           themed > 0 {
            return themed
        }
        return tileSize
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        if defaults.bool(forKey: Keys.hasImportedSystemDockSettings) {
            loadPersistedValues()
        } else {
            refresh()
        }
    }

    func refresh() {
        guard let values = DockPlistReader.read() else { return }
        applyValues(values)
        persistValues(hasImportedSystemDockSettings: true)
    }

    func setTileSize(_ size: CGFloat) {
        tileSize = size
        if largeSize < tileSize {
            largeSize = tileSize
        }
        persistValues()
        DockyPreferences.shared.markAppearanceOverride(Keys.tileSize)
    }

    func setLargeSize(_ size: CGFloat) {
        largeSize = max(tileSize, size)
        persistValues()
        DockyPreferences.shared.markAppearanceOverride(Keys.largeSize)
    }

    func setMagnification(_ isEnabled: Bool) {
        magnification = isEnabled
        persistValues()
        DockyPreferences.shared.markAppearanceOverride(Keys.magnification)
    }

    private func loadPersistedValues() {
        if let raw = defaults.string(forKey: Keys.orientation), let value = Orientation(rawValue: raw) {
            orientation = value
        }
        if let value = defaults.object(forKey: Keys.tileSize) as? Double {
            tileSize = CGFloat(value)
        }
        if let value = defaults.object(forKey: Keys.largeSize) as? Double {
            largeSize = CGFloat(value)
        }
        if let value = defaults.object(forKey: Keys.magnification) as? Bool {
            magnification = value
        }
        if let value = defaults.object(forKey: Keys.autohide) as? Bool {
            autohide = value
        }
        if let value = defaults.object(forKey: Keys.autohideDelay) as? Double {
            autohideDelay = value
        }
        if let value = defaults.object(forKey: Keys.autohideTimeModifier) as? Double {
            autohideTimeModifier = value
        }
        if let raw = defaults.string(forKey: Keys.minimizeEffect), let value = MinimizeEffect(rawValue: raw) {
            minimizeEffect = value
        }
        if let value = defaults.object(forKey: Keys.minimizeToApplication) as? Bool {
            minimizeToApplication = value
        }
        if let value = defaults.object(forKey: Keys.showRecents) as? Bool {
            showRecents = value
        }
        if let value = defaults.object(forKey: Keys.showProcessIndicators) as? Bool {
            showProcessIndicators = value
        }

        clampLargeSize()
    }

    private func applyValues(_ values: [String: Any]) {
        if let raw = values["orientation"] as? String, let value = Orientation(rawValue: raw) {
            orientation = value
        }
        if let value = (values["tilesize"] as? NSNumber)?.doubleValue {
            tileSize = CGFloat(value)
        }
        if let value = (values["largesize"] as? NSNumber)?.doubleValue {
            largeSize = CGFloat(value)
        }
        if let value = (values["magnification"] as? NSNumber)?.boolValue {
            magnification = value
        }
        if let value = (values["autohide"] as? NSNumber)?.boolValue {
            autohide = value
        }
        if let value = (values["autohide-delay"] as? NSNumber)?.doubleValue {
            autohideDelay = value
        }
        if let value = (values["autohide-time-modifier"] as? NSNumber)?.doubleValue {
            autohideTimeModifier = value
        }
        if let raw = values["mineffect"] as? String, let value = MinimizeEffect(rawValue: raw) {
            minimizeEffect = value
        }
        if let value = (values["minimize-to-application"] as? NSNumber)?.boolValue {
            minimizeToApplication = value
        }
        if let value = (values["show-recents"] as? NSNumber)?.boolValue {
            showRecents = value
        }
        if let value = (values["show-process-indicators"] as? NSNumber)?.boolValue {
            showProcessIndicators = value
        }

        clampLargeSize()
    }

    private func clampLargeSize() {
        if largeSize < tileSize {
            largeSize = tileSize
        }
    }

    private func persistValues(hasImportedSystemDockSettings: Bool? = nil) {
        defaults.set(orientation.rawValue, forKey: Keys.orientation)
        defaults.set(Double(tileSize), forKey: Keys.tileSize)
        defaults.set(Double(largeSize), forKey: Keys.largeSize)
        defaults.set(magnification, forKey: Keys.magnification)
        defaults.set(autohide, forKey: Keys.autohide)
        defaults.set(autohideDelay, forKey: Keys.autohideDelay)
        defaults.set(autohideTimeModifier, forKey: Keys.autohideTimeModifier)
        defaults.set(minimizeEffect.rawValue, forKey: Keys.minimizeEffect)
        defaults.set(minimizeToApplication, forKey: Keys.minimizeToApplication)
        defaults.set(showRecents, forKey: Keys.showRecents)
        defaults.set(showProcessIndicators, forKey: Keys.showProcessIndicators)

        if let hasImportedSystemDockSettings {
            defaults.set(hasImportedSystemDockSettings, forKey: Keys.hasImportedSystemDockSettings)
        }
    }

    private enum Keys {
        static let hasImportedSystemDockSettings = "docky.dockSettings.hasImportedSystemDockSettings"
        static let orientation = "docky.dockSettings.orientation"
        static let tileSize = DockyThemeOverrideKey.dockTileSize.rawValue
        static let largeSize = DockyThemeOverrideKey.dockLargeSize.rawValue
        static let magnification = DockyThemeOverrideKey.dockMagnification.rawValue
        static let autohide = "docky.dockSettings.autohide"
        static let autohideDelay = "docky.dockSettings.autohideDelay"
        static let autohideTimeModifier = "docky.dockSettings.autohideTimeModifier"
        static let minimizeEffect = "docky.dockSettings.minimizeEffect"
        static let minimizeToApplication = "docky.dockSettings.minimizeToApplication"
        static let showRecents = "docky.dockSettings.showRecents"
        static let showProcessIndicators = "docky.dockSettings.showProcessIndicators"
    }

}
