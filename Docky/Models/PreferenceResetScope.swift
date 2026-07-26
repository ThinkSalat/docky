//
//  PreferenceResetScope.swift
//  Docky
//
//  Pure reset ownership for theme-aware preference overrides. The persisted
//  override set predates behavior themes and retains its legacy name in
//  DockyPreferences, but partial resets must only clear keys whose values
//  they actually reset.
//

import Foundation

nonisolated enum DockyPreferenceResetScope: Equatable {
    case appearance
    case behavior
}

nonisolated enum DockyThemeOverrideResetOwner: Equatable {
    case appearance
    case behavior
    case dockSettings
}

nonisolated enum DockyThemeOverrideKey: String, CaseIterable {
    case disablesGlassLook = "docky.disablesGlassLook"
    case tileVerticalPadding = "docky.tileVerticalPadding"
    case tileSpacing = "docky.tileSpacing"
    case tileClipShape = "docky.tileClipShape"
    case tileIconPadding = "docky.tileIconPadding"
    case tileHoverOpacity = "docky.tileHoverOpacity"
    case tileHoverScale = "docky.tileHoverScale"
    case tileHoverBackgroundColor = "docky.tileHoverBackgroundColor"
    case tileHoverBackgroundImagePath = "docky.tileHoverBackgroundImagePath"
    case tileHoverBackgroundOpacity = "docky.tileHoverBackgroundOpacity"
    case tileHoverBackgroundCornerRadius = "docky.tileHoverBackgroundCornerRadius"
    case tileActiveBackgroundColor = "docky.tileActiveBackgroundColor"
    case tileActiveBackgroundImagePath = "docky.tileActiveBackgroundImagePath"
    case tileActiveBackgroundOpacity = "docky.tileActiveBackgroundOpacity"
    case tileActiveBackgroundCornerRadius = "docky.tileActiveBackgroundCornerRadius"
    case widget1xContentPadding = "docky.widget1xContentPadding"
    case widget1xCornerRadius = "docky.widget1xCornerRadius"
    case widget2xContentPadding = "docky.widget2xContentPadding"
    case widget2xCornerRadius = "docky.widget2xCornerRadius"
    case widget3xContentPadding = "docky.widget3xContentPadding"
    case widget3xCornerRadius = "docky.widget3xCornerRadius"
    case widget4xContentPadding = "docky.widget4xContentPadding"
    case widget4xCornerRadius = "docky.widget4xCornerRadius"
    case windowCornerRadius = "docky.windowCornerRadius"
    case windowCornerRadiusTopLeading = "docky.windowCornerRadiusTopLeading"
    case windowCornerRadiusTopTrailing = "docky.windowCornerRadiusTopTrailing"
    case windowCornerRadiusBottomLeading = "docky.windowCornerRadiusBottomLeading"
    case windowCornerRadiusBottomTrailing = "docky.windowCornerRadiusBottomTrailing"
    case windowContentInsetTop = "docky.windowContentInsetTop"
    case windowContentInsetLeading = "docky.windowContentInsetLeading"
    case windowContentInsetBottom = "docky.windowContentInsetBottom"
    case windowContentInsetTrailing = "docky.windowContentInsetTrailing"
    case windowClipShape = "docky.windowClipShape"
    case windowTintColor = "docky.windowTintColor"
    case windowTintOpacity = "docky.windowTintOpacity"
    case windowBackgroundImagePath = "docky.windowBackgroundImagePath"
    case windowBackgroundImageMode = "docky.windowBackgroundImageMode"
    case activeIndicatorShape = "docky.activeIndicatorShape"
    case activeIndicatorImagePath = "docky.activeIndicatorImagePath"
    case activeIndicatorColor = "docky.activeIndicatorColor"
    case activeIndicatorOffset = "docky.activeIndicatorOffset"
    case activeIndicatorScale = "docky.activeIndicatorScale"
    case dividerImagePath = "docky.dividerImagePath"
    case leftDividerImagePath = "docky.leftDividerImagePath"
    case rightDividerImagePath = "docky.rightDividerImagePath"
    case mirrorsLeftDividerOnRight = "docky.mirrorsLeftDividerOnRight"
    case dividerPaddingFraction = "docky.dividerPaddingFraction"
    case dividerImageScale = "docky.dividerImageScale"
    case dividerOffset = "docky.dividerOffset"
    case dividerOpacity = "docky.dividerOpacity"
    case dividerColor = "docky.dividerColor"
    case windowBorderColor = "docky.windowBorderColor"
    case windowBorderWidth = "docky.windowBorderWidth"
    case iconShadowColor = "docky.iconShadowColor"
    case iconShadowRadius = "docky.iconShadowRadius"
    case iconShadowOpacity = "docky.iconShadowOpacity"
    case windowAxisSizing = "docky.windowAxisSizing"
    case showsActivePinnedSeparator = "docky.showsActivePinnedSeparator"
    case dockTileSize = "docky.dockSettings.tileSize"
    case dockLargeSize = "docky.dockSettings.largeSize"
    case dockMagnification = "docky.dockSettings.magnification"

    var resetOwner: DockyThemeOverrideResetOwner {
        switch self {
        case .windowAxisSizing, .showsActivePinnedSeparator:
            return .behavior
        case .dockTileSize, .dockLargeSize, .dockMagnification:
            return .dockSettings
        default:
            return .appearance
        }
    }
}

nonisolated enum DockyPreferenceResetScopeModel {
    static let allKnownThemeOverrideKeys = Set(
        DockyThemeOverrideKey.allCases.map(\.rawValue)
    )

    static let appearanceThemeOverrideKeys = keys(ownedBy: .appearance)
    static let behaviorThemeOverrideKeys = keys(ownedBy: .behavior)
    static let dockSettingsThemeOverrideKeys = keys(ownedBy: .dockSettings)

    /// Keys whose persisted values are only written through a user-facing
    /// preference setter, so their presence can safely seed an override
    /// during migration. DockSettings keys are excluded because their raw
    /// values are also written when importing the system Dock configuration.
    static let presenceInferredThemeOverrideKeys =
        appearanceThemeOverrideKeys.union(behaviorThemeOverrideKeys)

    /// Keys that version 1 omitted from its recognized-key catalog and whose
    /// raw persisted values safely prove user intent. Explicit DockSettings
    /// overrides are recovered from the stored override-key set instead.
    static let recognitionMigrationV2Keys: Set<String> = [
        DockyThemeOverrideKey.windowAxisSizing.rawValue,
    ]

    static func retainingThemeOverrides(
        _ existing: Set<String>,
        afterReset scope: DockyPreferenceResetScope
    ) -> Set<String> {
        existing.subtracting(themeOverrideKeysCleared(by: scope))
    }

    static func themeOverrideKeysCleared(
        by scope: DockyPreferenceResetScope
    ) -> Set<String> {
        switch scope {
        case .appearance:
            appearanceThemeOverrideKeys
        case .behavior:
            behaviorThemeOverrideKeys
        }
    }

    private static func keys(
        ownedBy owner: DockyThemeOverrideResetOwner
    ) -> Set<String> {
        Set(
            DockyThemeOverrideKey.allCases
                .filter { $0.resetOwner == owner }
                .map(\.rawValue)
        )
    }
}
