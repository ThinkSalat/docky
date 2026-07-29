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
import Observation

/// Observable theme-override membership with per-key invalidation.
///
/// A plain observable `Set<String>` invalidates every reader whenever any
/// member changes. That made an indicator-color override redraw unrelated
/// window chrome because both settings consulted the same set. Each key gets a
/// stable flag object here, while `keys` remains the intentionally broad
/// observation used by the Themes settings summary.
@Observable
final class DockyThemeOverrideObservationStore {
    @Observable
    final class Flag {
        var isOverridden: Bool

        init(isOverridden: Bool) {
            self.isOverridden = isOverridden
        }
    }

    private(set) var keys: Set<String>
    @ObservationIgnored private var membership: Set<String>
    @ObservationIgnored private var flags: [String: Flag]

    init(keys: Set<String> = []) {
        self.keys = keys
        self.membership = keys
        self.flags = Dictionary(
            uniqueKeysWithValues: keys.map {
                ($0, Flag(isOverridden: true))
            }
        )
    }

    func contains(_ key: String) -> Bool {
        flag(for: key).isOverridden
    }

    @discardableResult
    func setOverridden(_ isOverridden: Bool, for key: String) -> Bool {
        let flag = flag(for: key)
        guard flag.isOverridden != isOverridden else { return false }

        flag.isOverridden = isOverridden
        if isOverridden {
            membership.insert(key)
            keys.insert(key)
        } else {
            membership.remove(key)
            keys.remove(key)
        }
        return true
    }

    func replaceAll(with newKeys: Set<String>) {
        guard newKeys != membership else { return }

        for key in membership.symmetricDifference(newKeys) {
            flag(for: key).isOverridden = newKeys.contains(key)
        }
        membership = newKeys
        keys = newKeys
    }

    private func flag(for key: String) -> Flag {
        if let existing = flags[key] {
            return existing
        }

        let created = Flag(isOverridden: membership.contains(key))
        flags[key] = created
        return created
    }
}

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

nonisolated enum TileHoverEffectsMasterProvenance:
    String,
    Equatable,
    Sendable
{
    case user
    case automaticMigration
}

nonisolated enum TileHoverEffectsMigrationAction:
    Equatable,
    Sendable
{
    case deferUntilUsableTheme
    case keepStored(Bool)
    case materialize(Bool)
}

/// One-time compatibility policy for the tile-hover master switch. Automatic
/// values carry provenance and a schema version so a known-bad migration can
/// be repaired exactly once without ever reinterpreting a user's later toggle.
nonisolated enum TileHoverEffectsMigrationPolicy {
    static let currentVersion = 2

    static func action(
        storedMasterValue: Bool?,
        storedProvenance: String?,
        storedMigrationVersion: Int?,
        hasUsableThemeBootstrap: Bool,
        isExistingInstall: Bool,
        legacyToggleHadEffectiveColor: Bool
    ) -> TileHoverEffectsMigrationAction {
        if let storedMasterValue,
           storedValueIsAuthoritative(
               provenance: storedProvenance,
               migrationVersion: storedMigrationVersion
           ) {
            return .keepStored(storedMasterValue)
        }

        guard hasUsableThemeBootstrap else {
            return .deferUntilUsableTheme
        }

        let resolved = isExistingInstall
            ? legacyToggleHadEffectiveColor
            : true
        return .materialize(resolved)
    }

    static func legacyToggleHadEffectiveColor(
        explicitMode: ThemeOptionalAppearanceMode?,
        legacyAppearanceOverrideIsSet: Bool,
        hasDecodedCustomColor: Bool,
        hasValidatedThemeColor: Bool
    ) -> Bool {
        if let explicitMode {
            switch explicitMode {
            case .inherit:
                return hasValidatedThemeColor
            case .disabled:
                return false
            case .custom:
                return hasDecodedCustomColor
            }
        }

        return (
            legacyAppearanceOverrideIsSet
                && hasDecodedCustomColor
        ) || hasValidatedThemeColor
    }

    private static func storedValueIsAuthoritative(
        provenance: String?,
        migrationVersion: Int?
    ) -> Bool {
        guard let provenance else {
            // The short-lived broken migration wrote only the Bool. Treat
            // that exact unversioned shape as repairable.
            return false
        }
        guard let known =
            TileHoverEffectsMasterProvenance(rawValue: provenance)
        else {
            // Future/foreign provenance must fail safe and preserve the value.
            return true
        }
        switch known {
        case .user:
            return true
        case .automaticMigration:
            return (migrationVersion ?? 0) >= currentVersion
        }
    }
}

nonisolated enum TileHoverEffectsInstallEvidencePolicy {
    enum Classification: String, Equatable, Sendable {
        case fresh
        case existing
    }

    static let ignoredFreshLaunchKeys: Set<String> = [
        "docky.applicationInstallPromptDeferredPath",
        "docky.tileHoverEffectsEnabled",
        "docky.tileHoverEffectsInstallClassification",
        "docky.tileHoverEffectsMasterProvenance",
        "docky.tileHoverEffectsMigrationVersion",
    ]

    static func classification(
        storedValue: String?,
        persistedKeys: Set<String>
    ) -> Classification {
        if let storedValue,
           let stored =
            Classification(rawValue: storedValue) {
            return stored
        }
        return isExistingInstall(persistedKeys: persistedKeys)
            ? .existing
            : .fresh
    }

    static func isExistingInstall(
        persistedKeys: Set<String>
    ) -> Bool {
        persistedKeys.contains {
            $0.hasPrefix("docky.")
                && !ignoredFreshLaunchKeys.contains($0)
        }
    }
}

/// Pure runtime gate for visual hover channels. Keeping the neutral values in
/// one policy prevents an individual renderer or future theme value from
/// bypassing the persisted master switch.
nonisolated enum TileHoverEffectsRuntimePolicy {
    static func allowsHoverPresentation(
        isEnabled: Bool,
        featureEnabled: Bool
    ) -> Bool {
        isEnabled && featureEnabled
    }

    static func allowsMagnification(
        isEnabled: Bool,
        configuredEnabled: Bool
    ) -> Bool {
        isEnabled && configuredEnabled
    }

    static func scale(
        isEnabled: Bool,
        configured: CGFloat
    ) -> CGFloat {
        isEnabled ? configured : 1
    }

    static func tileOpacity(
        isEnabled: Bool,
        configured: CGFloat
    ) -> CGFloat {
        isEnabled ? configured : 1
    }

    static func backgroundOpacity(
        isEnabled: Bool,
        configured: CGFloat
    ) -> CGFloat {
        isEnabled ? configured : 0
    }

    static func backgroundCornerRadius(
        isEnabled: Bool,
        configured: CGFloat
    ) -> CGFloat {
        isEnabled ? configured : 0
    }

    static func allowsBackgroundSource(isEnabled: Bool) -> Bool {
        isEnabled
    }
}

/// User intent for an optional appearance source that a theme may also
/// provide. A nullable custom value alone cannot distinguish "follow the
/// theme" from "explicitly use no value", so this mode is persisted
/// independently from the dormant custom value.
nonisolated enum ThemeOptionalAppearanceMode:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Sendable
{
    case inherit
    case disabled
    case custom

    var id: String { rawValue }
}

/// Pure resolver shared by color and image sources. `.custom` deliberately
/// fails closed when its stored value is unavailable instead of unexpectedly
/// reviving the theme value.
nonisolated enum ThemeOptionalAppearanceResolution {
    static func value<Value>(
        mode: ThemeOptionalAppearanceMode,
        custom: Value?,
        themed: Value?
    ) -> Value? {
        switch mode {
        case .inherit:
            themed
        case .disabled:
            nil
        case .custom:
            custom
        }
    }
}

nonisolated enum ThemeOptionalAppearanceModeStorage {
    static func encode(
        _ modes: [String: ThemeOptionalAppearanceMode]
    ) -> [String: String] {
        modes.mapValues(\.rawValue)
    }

    static func decode(
        _ rawValues: [String: String],
        recognizedKeys: Set<String>
    ) -> [String: ThemeOptionalAppearanceMode] {
        rawValues.reduce(
            into: [String: ThemeOptionalAppearanceMode]()
        ) { result, entry in
            guard recognizedKeys.contains(entry.key),
                  let mode = ThemeOptionalAppearanceMode(
                      rawValue: entry.value
                  )
            else {
                return
            }
            result[entry.key] = mode
        }
    }
}

/// A behavior reset is a recovery operation, so it must not silently opt the
/// user into background or system-wide effects. First-launch suggestions stay
/// separate from these deliberately conservative reset values.
nonisolated enum DockyBehaviorResetSafetyPolicy {
    static let opensAtLogin = false
    static let hidesSystemDock = false
    static let enablesWidgetHoverPreview = false
}

/// `Hide System Dock` shipped as an enabled-by-default preference. Older
/// installations therefore legitimately have no stored key when the user
/// kept that default. Resolve that missing value using the legacy contract
/// and materialize it once so a future default change cannot reinterpret the
/// same unchanged preferences.
nonisolated enum SystemDockVisibilityStoredPreferencePolicy {
    static let legacyDefault = true

    static func resolve(storedValue: Bool?) -> Bool {
        storedValue ?? legacyDefault
    }

    static func shouldMaterialize(storedValue: Bool?) -> Bool {
        storedValue == nil
    }
}

nonisolated enum LaunchAtLoginMutationResult: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case failed(String)
}

/// The state macOS currently reports for Docky's login item. This is kept
/// separate from the user's persisted preference: System Settings can change
/// the observed state while Docky is not running, and merely launching Docky
/// must never overwrite that external choice.
nonisolated enum LaunchAtLoginObservedStatus:
    String,
    Equatable,
    Sendable
{
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

/// Verifies a ServiceManagement mutation against the state reported after the
/// call. ServiceManagement may throw after the requested state has already
/// taken effect, so a matching observed postcondition wins over the thrown
/// error. A non-matching postcondition always fails closed.
nonisolated enum LaunchAtLoginMutationVerificationPolicy {
    static func result(
        requestedValue: Bool,
        observedStatus: LaunchAtLoginObservedStatus,
        mutationErrorDescription: String?
    ) -> LaunchAtLoginMutationResult {
        switch (requestedValue, observedStatus) {
        case (true, .enabled):
            return .enabled
        case (true, .requiresApproval):
            return .requiresApproval
        case (false, .disabled):
            return .disabled
        default:
            let requested = requestedValue ? "enabled" : "disabled"
            let actual = observedStatus.rawValue
            let mutationDetail = mutationErrorDescription.map {
                " \($0)"
            } ?? ""
            return .failed(
                "macOS did not confirm the requested \(requested) state "
                    + "(reported \(actual)).\(mutationDetail)"
            )
        }
    }
}

nonisolated struct LaunchAtLoginStatusPresentation:
    Equatable,
    Sendable
{
    let requiresApproval: Bool
    let mismatchMessage: String?
}

/// Converts the independently stored intent and observed status into UI
/// feedback without mutating either value.
nonisolated enum LaunchAtLoginStatusPresentationPolicy {
    static func resolve(
        desiredValue: Bool,
        observedStatus: LaunchAtLoginObservedStatus
    ) -> LaunchAtLoginStatusPresentation {
        switch (desiredValue, observedStatus) {
        case (true, .enabled), (false, .disabled):
            return LaunchAtLoginStatusPresentation(
                requiresApproval: false,
                mismatchMessage: nil
            )
        case (true, .requiresApproval):
            return LaunchAtLoginStatusPresentation(
                requiresApproval: true,
                mismatchMessage: nil
            )
        case (_, .unavailable):
            return LaunchAtLoginStatusPresentation(
                requiresApproval: false,
                mismatchMessage:
                    "macOS could not report Docky's login-item status."
            )
        case (true, .disabled):
            return LaunchAtLoginStatusPresentation(
                requiresApproval: false,
                mismatchMessage:
                    "Docky is saved as on, but macOS currently reports "
                    + "the login item as disabled. Toggle it off and on "
                    + "to request the change again."
            )
        case (false, .enabled), (false, .requiresApproval):
            return LaunchAtLoginStatusPresentation(
                requiresApproval:
                    observedStatus == .requiresApproval,
                mismatchMessage:
                    "Docky is saved as off, but macOS still reports the "
                    + "login item as registered. Toggle it on and off "
                    + "to remove it."
            )
        }
    }
}

nonisolated struct LaunchAtLoginPreferenceResolution:
    Equatable,
    Sendable
{
    let value: Bool
    let shouldPersist: Bool
    let requiresApproval: Bool
    let errorMessage: String?
}

/// Resolves a ServiceManagement result without mutating preferences. Failed
/// or contradictory mutations retain the last confirmed value; successful
/// and pending-approval registrations commit the user's requested value.
nonisolated enum LaunchAtLoginPreferencePolicy {
    static func resolve(
        previousValue: Bool,
        requestedValue: Bool,
        result: LaunchAtLoginMutationResult
    ) -> LaunchAtLoginPreferenceResolution {
        switch result {
        case .enabled where requestedValue:
            return LaunchAtLoginPreferenceResolution(
                value: true,
                shouldPersist: true,
                requiresApproval: false,
                errorMessage: nil
            )
        case .disabled where !requestedValue:
            return LaunchAtLoginPreferenceResolution(
                value: false,
                shouldPersist: true,
                requiresApproval: false,
                errorMessage: nil
            )
        case .requiresApproval where requestedValue:
            return LaunchAtLoginPreferenceResolution(
                value: true,
                shouldPersist: true,
                requiresApproval: true,
                errorMessage: nil
            )
        case .failed(let message):
            return LaunchAtLoginPreferenceResolution(
                value: previousValue,
                shouldPersist: false,
                requiresApproval: false,
                errorMessage: message
            )
        case .enabled, .disabled, .requiresApproval:
            return LaunchAtLoginPreferenceResolution(
                value: previousValue,
                shouldPersist: false,
                requiresApproval: false,
                errorMessage:
                    "macOS reported a login item state that did not match "
                    + "the requested change."
            )
        }
    }
}

nonisolated enum SystemDockVisibilityMutationResult:
    Equatable,
    Sendable
{
    case hidden
    case restored
    case failed(String)
}

/// A persisted active Dock-recovery state belongs to this exact app session,
/// not merely to a live process identifier. PIDs can be recycled after a
/// crash, so an active state from any other session must be recovered even
/// when its recorded PID happens to be occupied again.
nonisolated enum SystemDockRecoveryOwnershipPolicy {
    static func isCurrentSession(
        stateIsActive: Bool,
        ownerPID: Int32,
        currentPID: Int32,
        stateSessionID: String,
        currentSessionID: String
    ) -> Bool {
        stateIsActive
            && ownerPID > 0
            && ownerPID == currentPID
            && !stateSessionID.isEmpty
            && stateSessionID == currentSessionID
    }
}

nonisolated enum SystemDockSnapshotScalar: Equatable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case unsupported
}

/// Classifies Core Foundation preference values without Swift's permissive
/// NSNumber-to-Bool cast. In particular, numeric 0 and 1 must remain numbers
/// in the recovery snapshot rather than being restored as booleans.
nonisolated enum SystemDockSnapshotTypingPolicy {
    static func scalar(
        for value: Any?,
        nullMarker: String
    ) -> SystemDockSnapshotScalar {
        guard let value else {
            return .null
        }

        if let string = value as? String {
            return string == nullMarker ? .null : .string(string)
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(number.doubleValue)
        }

        return .unsupported
    }
}

nonisolated struct SystemDockVisibilityPreferenceResolution:
    Equatable,
    Sendable
{
    let value: Bool
    let shouldPersist: Bool
    let errorMessage: String?
}

/// Commits the Hide System Dock preference only after the corresponding
/// external Dock mutation has a verified postcondition.
nonisolated enum SystemDockVisibilityPreferencePolicy {
    static func resolve(
        previousValue: Bool,
        requestedValue: Bool,
        result: SystemDockVisibilityMutationResult
    ) -> SystemDockVisibilityPreferenceResolution {
        switch (requestedValue, result) {
        case (true, .hidden):
            return SystemDockVisibilityPreferenceResolution(
                value: true,
                shouldPersist: true,
                errorMessage: nil
            )
        case (false, .restored):
            return SystemDockVisibilityPreferenceResolution(
                value: false,
                shouldPersist: true,
                errorMessage: nil
            )
        case (_, .failed(let message)):
            return SystemDockVisibilityPreferenceResolution(
                value: previousValue,
                shouldPersist: false,
                errorMessage: message
            )
        case (true, .restored), (false, .hidden):
            return SystemDockVisibilityPreferenceResolution(
                value: previousValue,
                shouldPersist: false,
                errorMessage:
                    "The macOS Dock reported a state that did not match "
                    + "the requested change."
            )
        }
    }
}

nonisolated enum GlobalHotKeyRegistrationResult:
    Equatable,
    Sendable
{
    case registered
    case inactive
    case failed(String)
}

nonisolated enum WindowSwitcherBaseShortcutValidationResult:
    Equatable,
    Sendable
{
    case inactive
    case accepted
    case rejected(String)
}

/// The switcher derives reverse cycling by adding Shift to the base chord.
/// A base chord that already contains Shift would make forward and reverse
/// identical, so it must be rejected before either Carbon registration.
nonisolated enum WindowSwitcherBaseShortcutPolicy {
    static func validate(
        isConfigured: Bool,
        containsShift: Bool
    ) -> WindowSwitcherBaseShortcutValidationResult {
        guard isConfigured else {
            return .inactive
        }
        guard !containsShift else {
            return .rejected(
                "Window Switcher's base shortcut cannot include Shift "
                    + "because Shift is reserved for reverse cycling. "
                    + "The previous shortcut was kept."
            )
        }
        return .accepted
    }
}

nonisolated struct GlobalHotKeyPreferenceResolution:
    Equatable,
    Sendable
{
    let shouldCommit: Bool
    let errorMessage: String?
}

/// A shortcut value is durable only after Carbon accepted every hotkey needed
/// by that feature. `.inactive` is a successful outcome for a cleared
/// shortcut or a currently-disabled feature.
nonisolated enum GlobalHotKeyPreferencePolicy {
    static func resolve(
        result: GlobalHotKeyRegistrationResult
    ) -> GlobalHotKeyPreferenceResolution {
        switch result {
        case .registered, .inactive:
            return GlobalHotKeyPreferenceResolution(
                shouldCommit: true,
                errorMessage: nil
            )
        case .failed(let message):
            return GlobalHotKeyPreferenceResolution(
                shouldCommit: false,
                errorMessage: message
            )
        }
    }
}

nonisolated struct GlobalHotKeyEnablementPreferenceResolution:
    Equatable,
    Sendable
{
    let value: Bool
    let shouldPersist: Bool
    let errorMessage: String?
}

/// Commits an enable toggle only after its service has reconciled the actual
/// Carbon registrations. An enabled feature with no configured shortcut is a
/// valid inactive state; an enabled feature with a usable shortcut must have
/// a confirmed registration.
nonisolated enum GlobalHotKeyEnablementPreferencePolicy {
    static func resolve(
        previousValue: Bool,
        requestedValue: Bool,
        expectsRegistrationWhenEnabled: Bool,
        result: GlobalHotKeyRegistrationResult
    ) -> GlobalHotKeyEnablementPreferenceResolution {
        switch (requestedValue, expectsRegistrationWhenEnabled, result) {
        case (false, _, .inactive),
             (true, false, .inactive),
             (true, true, .registered):
            return GlobalHotKeyEnablementPreferenceResolution(
                value: requestedValue,
                shouldPersist: true,
                errorMessage: nil
            )
        case (_, _, .failed(let message)):
            return GlobalHotKeyEnablementPreferenceResolution(
                value: previousValue,
                shouldPersist: false,
                errorMessage: message
            )
        default:
            return GlobalHotKeyEnablementPreferenceResolution(
                value: previousValue,
                shouldPersist: false,
                errorMessage:
                    "The global shortcut service reported a state that did "
                    + "not match the requested feature setting."
            )
        }
    }
}
