//
//  SystemDockSettingsSnapshot.swift
//  Docky
//
//  A value-only snapshot of the subset of com.apple.dock preferences that
//  Docky can intentionally import. Keeping parsing outside the service makes
//  read-only inspection and state-changing import separate, testable actions.
//

import Foundation

nonisolated enum SystemDockSettingsStartupPolicy {
    enum Action: Equatable {
        case loadPersistedValues(repairImportMarker: Bool)
        case bootstrapFromSystemDock
    }

    static func action(
        hasImportMarker: Bool,
        hasPersistedDockyValues: Bool
    ) -> Action {
        guard hasImportMarker || hasPersistedDockyValues else {
            return .bootstrapFromSystemDock
        }
        return .loadPersistedValues(
            repairImportMarker:
                hasPersistedDockyValues && !hasImportMarker
        )
    }
}

nonisolated enum DockSettingsThemeResolutionPolicy {
    static func tileSize(
        stored: CGFloat,
        themed: CGFloat?,
        isOverridden: Bool
    ) -> CGFloat {
        if !isOverridden, let themed, isPositiveFinite(themed) {
            return themed
        }
        return isPositiveFinite(stored) ? stored : 48
    }

    static func largeSize(
        stored: CGFloat,
        themed: CGFloat?,
        isOverridden: Bool,
        effectiveTileSize: CGFloat
    ) -> CGFloat {
        let candidate: CGFloat
        if !isOverridden, let themed, isPositiveFinite(themed) {
            candidate = themed
        } else if isPositiveFinite(stored) {
            candidate = stored
        } else {
            candidate = effectiveTileSize
        }
        return max(effectiveTileSize, candidate)
    }

    static func magnification(
        stored: Bool,
        themed: Bool?,
        isOverridden: Bool
    ) -> Bool {
        guard !isOverridden, let themed else {
            return stored
        }
        return themed
    }

    private static func isPositiveFinite(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }
}

nonisolated struct SystemDockSettingsSnapshot: Equatable {
    enum Orientation: String, Equatable {
        case bottom, left, right
    }

    enum MinimizeEffect: String, Equatable {
        case genie, scale, suck
    }

    enum AppearanceValue: Equatable, Hashable {
        case tileSize
        case largeSize
        case magnification
    }

    let orientation: Orientation?
    let tileSize: Double?
    let largeSize: Double?
    let magnification: Bool?
    let autohide: Bool?
    let autohideDelay: TimeInterval?
    let autohideTimeModifier: Double?
    let minimizeEffect: MinimizeEffect?
    let minimizeToApplication: Bool?
    let showRecents: Bool?
    let showProcessIndicators: Bool?

    init(values: [String: Any]) {
        orientation = (values["orientation"] as? String)
            .flatMap(Orientation.init(rawValue:))
        tileSize = Self.positiveFiniteNumber(
            values["tilesize"]
        )
        largeSize = Self.positiveFiniteNumber(
            values["largesize"]
        )
        magnification = Self.boolean(values["magnification"])
        autohide = Self.boolean(values["autohide"])
        autohideDelay = Self.finiteNumber(values["autohide-delay"])
        autohideTimeModifier = Self.finiteNumber(
            values["autohide-time-modifier"]
        )
        minimizeEffect = (values["mineffect"] as? String)
            .flatMap(MinimizeEffect.init(rawValue:))
        minimizeToApplication = Self.boolean(
            values["minimize-to-application"]
        )
        showRecents = Self.boolean(values["show-recents"])
        showProcessIndicators = Self.boolean(
            values["show-process-indicators"]
        )
    }

    var isEmpty: Bool {
        orientation == nil
            && tileSize == nil
            && largeSize == nil
            && magnification == nil
            && autohide == nil
            && autohideDelay == nil
            && autohideTimeModifier == nil
            && minimizeEffect == nil
            && minimizeToApplication == nil
            && showRecents == nil
            && showProcessIndicators == nil
    }

    var importedAppearanceValues: Set<AppearanceValue> {
        var result = Set<AppearanceValue>()
        if tileSize != nil {
            result.insert(.tileSize)
        }
        if largeSize != nil {
            result.insert(.largeSize)
        }
        if magnification != nil {
            result.insert(.magnification)
        }
        return result
    }

    private static func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue,
              number.isFinite else {
            return nil
        }
        return number
    }

    private static func positiveFiniteNumber(_ value: Any?) -> Double? {
        guard let number = finiteNumber(value), number > 0 else {
            return nil
        }
        return number
    }
}
