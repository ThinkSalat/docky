//
//  DockSettingsService.swift
//  Docky
//
//  Owns Docky's imported Dock settings and a separate, read-only snapshot of
//  the current system Dock preferences.
//
//  Reads from `CFPreferences` on `com.apple.dock`.
//

import AppKit
import Combine
import Observation

@Observable
final class DockSettingsService {
    static let shared = DockSettingsService()

    typealias Orientation = SystemDockSettingsSnapshot.Orientation
    typealias MinimizeEffect = SystemDockSettingsSnapshot.MinimizeEffect

    /// Docky's persisted values. These change only through Docky controls or
    /// an explicitly requested import, never through snapshot refreshes.
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

    /// Latest read-only view of com.apple.dock. Kept separate from Docky's
    /// persisted values so diagnostics and refresh actions cannot reset user
    /// choices.
    private(set) var systemSnapshot: SystemDockSettingsSnapshot?

    /// Runtime tile size. Theme behavior is used until a Docky control or
    /// explicit system-Dock import establishes a user override.
    var effectiveTileSize: CGFloat {
        DockSettingsThemeResolutionPolicy.tileSize(
            stored: tileSize,
            themed:
                ThemeManager.shared.activeManifest?.behavior?.tileSize,
            isOverridden:
                DockyPreferences.shared
                    .isAppearanceOverridden(Keys.tileSize)
        )
    }

    /// Runtime magnified size, always large enough for the effective resting
    /// tile size even when a theme contains an inconsistent pair.
    var effectiveLargeSize: CGFloat {
        DockSettingsThemeResolutionPolicy.largeSize(
            stored: largeSize,
            themed:
                ThemeManager.shared.activeManifest?.behavior?.largeSize,
            isOverridden:
                DockyPreferences.shared
                    .isAppearanceOverridden(Keys.largeSize),
            effectiveTileSize: effectiveTileSize
        )
    }

    /// Runtime magnification switch. A raw Docky value still backs the
    /// Settings control; the active theme supplies the value until the user
    /// explicitly overrides it.
    var effectiveMagnification: Bool {
        DockSettingsThemeResolutionPolicy.magnification(
            stored: magnification,
            themed:
                ThemeManager.shared.activeManifest?.behavior?.magnification,
            isOverridden:
                DockyPreferences.shared
                    .isAppearanceOverridden(Keys.magnification)
        )
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let hasImportMarker = defaults.bool(
            forKey: Keys.hasImportedSystemDockSettings
        )
        let hasPersistedDockyValues = Keys.persistedValueKeys.contains {
            defaults.object(forKey: $0) != nil
        }

        switch SystemDockSettingsStartupPolicy.action(
            hasImportMarker: hasImportMarker,
            hasPersistedDockyValues: hasPersistedDockyValues
        ) {
        case .loadPersistedValues(let repairImportMarker):
            loadPersistedValues()
            if repairImportMarker {
                defaults.set(
                    true,
                    forKey: Keys.hasImportedSystemDockSettings
                )
            }
            refreshSystemDockSnapshot()
        case .bootstrapFromSystemDock:
            importCurrentSystemDockSettings(
                marksAppearanceOverrides: false
            )
        }
    }

    /// Refreshes only the diagnostic snapshot. This is deliberately
    /// side-effect-free with respect to Docky's persisted settings.
    @discardableResult
    func refreshSystemDockSnapshot() -> Bool {
        guard let snapshot = Self.readSystemDockSnapshot() else {
            systemSnapshot = nil
            return false
        }
        systemSnapshot = snapshot
        return true
    }

    /// Explicitly copies the current system Dock values into Docky.
    ///
    /// The user-facing import marks theme-aware values as overrides because
    /// choosing Import is user intent. The automatic first-run bootstrap uses
    /// the private overload below and leaves those override flags clear.
    @discardableResult
    func importCurrentSystemDockSettings() -> Bool {
        importCurrentSystemDockSettings(
            marksAppearanceOverrides: true
        )
    }

    @discardableResult
    private func importCurrentSystemDockSettings(
        marksAppearanceOverrides: Bool
    ) -> Bool {
        guard let snapshot = Self.readSystemDockSnapshot() else {
            systemSnapshot = nil
            return false
        }

        systemSnapshot = snapshot
        applyImportedValues(snapshot)
        persistValues(hasImportedSystemDockSettings: true)

        if marksAppearanceOverrides {
            markAppearanceOverrides(for: snapshot)
        }
        return true
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

    private static func readSystemDockSnapshot()
        -> SystemDockSettingsSnapshot? {
        guard let values = DockPlistReader.read() else {
            return nil
        }
        let snapshot = SystemDockSettingsSnapshot(values: values)
        return snapshot.isEmpty ? nil : snapshot
    }

    private func applyImportedValues(
        _ snapshot: SystemDockSettingsSnapshot
    ) {
        if let value = snapshot.orientation {
            orientation = value
        }
        if let value = snapshot.tileSize {
            tileSize = CGFloat(value)
        }
        if let value = snapshot.largeSize {
            largeSize = CGFloat(value)
        }
        if let value = snapshot.magnification {
            magnification = value
        }
        if let value = snapshot.autohide {
            autohide = value
        }
        if let value = snapshot.autohideDelay {
            autohideDelay = value
        }
        if let value = snapshot.autohideTimeModifier {
            autohideTimeModifier = value
        }
        if let value = snapshot.minimizeEffect {
            minimizeEffect = value
        }
        if let value = snapshot.minimizeToApplication {
            minimizeToApplication = value
        }
        if let value = snapshot.showRecents {
            showRecents = value
        }
        if let value = snapshot.showProcessIndicators {
            showProcessIndicators = value
        }
        clampLargeSize()
    }

    private func markAppearanceOverrides(
        for snapshot: SystemDockSettingsSnapshot
    ) {
        let preferences = DockyPreferences.shared
        for value in snapshot.importedAppearanceValues {
            switch value {
            case .tileSize:
                preferences.markAppearanceOverride(Keys.tileSize)
            case .largeSize:
                preferences.markAppearanceOverride(Keys.largeSize)
            case .magnification:
                preferences.markAppearanceOverride(Keys.magnification)
            }
        }
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

        static let persistedValueKeys = [
            orientation,
            tileSize,
            largeSize,
            magnification,
            autohide,
            autohideDelay,
            autohideTimeModifier,
            minimizeEffect,
            minimizeToApplication,
            showRecents,
            showProcessIndicators,
        ]
    }

}
