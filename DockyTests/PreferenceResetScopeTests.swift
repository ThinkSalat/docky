import Foundation
import XCTest

final class PreferenceResetScopeTests: XCTestCase {
    func testAppearanceResetPreservesBehaviorDockSettingsAndUnknownOverrides() {
        let appearance = DockyThemeOverrideKey.tileSpacing.rawValue
        let windowAxis = DockyThemeOverrideKey.windowAxisSizing.rawValue
        let separator = DockyThemeOverrideKey.showsActivePinnedSeparator.rawValue
        let tileSize = DockyThemeOverrideKey.dockTileSize.rawValue
        let futureKey = "docky.futureThemeOverride"

        let retained = DockyPreferenceResetScopeModel.retainingThemeOverrides(
            [appearance, windowAxis, separator, tileSize, futureKey],
            afterReset: .appearance
        )

        XCTAssertFalse(retained.contains(appearance))
        XCTAssertTrue(retained.contains(windowAxis))
        XCTAssertTrue(retained.contains(separator))
        XCTAssertTrue(retained.contains(tileSize))
        XCTAssertTrue(retained.contains(futureKey))
    }

    func testBehaviorResetPreservesAppearanceDockSettingsAndUnknownOverrides() {
        let appearance = DockyThemeOverrideKey.windowTintOpacity.rawValue
        let windowAxis = DockyThemeOverrideKey.windowAxisSizing.rawValue
        let separator = DockyThemeOverrideKey.showsActivePinnedSeparator.rawValue
        let magnification = DockyThemeOverrideKey.dockMagnification.rawValue
        let futureKey = "docky.futureThemeOverride"

        let retained = DockyPreferenceResetScopeModel.retainingThemeOverrides(
            [appearance, windowAxis, separator, magnification, futureKey],
            afterReset: .behavior
        )

        XCTAssertTrue(retained.contains(appearance))
        XCTAssertFalse(retained.contains(windowAxis))
        XCTAssertFalse(retained.contains(separator))
        XCTAssertTrue(retained.contains(magnification))
        XCTAssertTrue(retained.contains(futureKey))
    }

    func testWindowAxisSizingBelongsToBehaviorReset() {
        XCTAssertEqual(
            DockyThemeOverrideKey.windowAxisSizing.resetOwner,
            .behavior
        )
        XCTAssertTrue(
            DockyPreferenceResetScopeModel.behaviorThemeOverrideKeys.contains(
                DockyThemeOverrideKey.windowAxisSizing.rawValue
            )
        )
        XCTAssertFalse(
            DockyPreferenceResetScopeModel.appearanceThemeOverrideKeys.contains(
                DockyThemeOverrideKey.windowAxisSizing.rawValue
            )
        )
    }

    func testDockSettingsOverridesAreNotOwnedByEitherPartialReset() {
        let externallyOwned = DockyPreferenceResetScopeModel
            .dockSettingsThemeOverrideKeys
        let partiallyReset = DockyPreferenceResetScopeModel
            .appearanceThemeOverrideKeys
            .union(DockyPreferenceResetScopeModel.behaviorThemeOverrideKeys)

        XCTAssertEqual(
            externallyOwned,
            [
                DockyThemeOverrideKey.dockTileSize.rawValue,
                DockyThemeOverrideKey.dockLargeSize.rawValue,
                DockyThemeOverrideKey.dockMagnification.rawValue,
            ]
        )
        XCTAssertTrue(externallyOwned.isDisjoint(with: partiallyReset))
    }

    func testEveryKnownOverrideHasExactlyOneResetOwner() {
        let partitioned = DockyPreferenceResetScopeModel
            .appearanceThemeOverrideKeys
            .union(DockyPreferenceResetScopeModel.behaviorThemeOverrideKeys)
            .union(DockyPreferenceResetScopeModel.dockSettingsThemeOverrideKeys)

        XCTAssertEqual(
            partitioned,
            DockyPreferenceResetScopeModel.allKnownThemeOverrideKeys
        )
        XCTAssertEqual(
            partitioned.count,
            DockyThemeOverrideKey.allCases.count
        )
    }

    func testRecognitionMigrationOnlyAddsPreviouslyUnrecognizedKeys() {
        XCTAssertEqual(
            DockyPreferenceResetScopeModel.recognitionMigrationV2Keys,
            [
                DockyThemeOverrideKey.windowAxisSizing.rawValue,
            ]
        )
        XCTAssertFalse(
            DockyPreferenceResetScopeModel.recognitionMigrationV2Keys.contains(
                DockyThemeOverrideKey.showsActivePinnedSeparator.rawValue
            )
        )
    }

    func testPresenceInferenceExcludesAutomaticallyImportedDockSettings() {
        XCTAssertEqual(
            DockyPreferenceResetScopeModel.presenceInferredThemeOverrideKeys,
            DockyPreferenceResetScopeModel.appearanceThemeOverrideKeys.union(
                DockyPreferenceResetScopeModel.behaviorThemeOverrideKeys
            )
        )
        XCTAssertTrue(
            DockyPreferenceResetScopeModel
                .presenceInferredThemeOverrideKeys
                .isDisjoint(
                    with: DockyPreferenceResetScopeModel
                        .dockSettingsThemeOverrideKeys
                )
        )
    }

    func testDockyPreferenceResetInventoryHasOneExplicitOwner() throws {
        let source = try dockyPreferencesSource()
        let appearanceBody = try functionBody(
            named: "resetAppearanceToDefaults",
            in: source
        )
        let behaviorBody = try functionBody(
            named: "resetBehaviorToDefaults",
            in: source
        )
        let fullBody = try functionBody(
            named: "resetToDefaults",
            in: source
        )

        let appearance = assignmentProperties(in: appearanceBody)
        let behavior = assignmentProperties(in: behaviorBody)
        let fullOnly = assignmentProperties(in: fullBody)

        XCTAssertEqual(appearance, ResetInventory.appearance)
        XCTAssertEqual(behavior, ResetInventory.behavior)
        XCTAssertEqual(fullOnly, ResetInventory.fullOnly)
        XCTAssertTrue(appearance.isDisjoint(with: behavior))
        XCTAssertTrue(appearance.isDisjoint(with: fullOnly))
        XCTAssertTrue(behavior.isDisjoint(with: fullOnly))

        let classified = appearance
            .union(behavior)
            .union(fullOnly)
            .union(ResetInventory.intentionallyPreserved)
        XCTAssertEqual(
            didSetPreferenceProperties(in: source),
            classified,
            "Every mutable DockyPreferences value must be reset by exactly "
                + "one surface or documented as intentionally preserved."
        )

        XCTAssertTrue(fullBody.contains("resetAppearanceToDefaults()"))
        XCTAssertTrue(fullBody.contains("resetBehaviorToDefaults()"))

        let importedDockSettings = Set([
            "tileSize",
            "largeSize",
            "magnification",
        ])
        XCTAssertTrue(importedDockSettings.isDisjoint(with: classified))
        XCTAssertFalse(fullBody.contains("DockSettingsService"))
    }

    private func dockyPreferencesSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Docky")
            .appendingPathComponent("Services")
            .appendingPathComponent("DockyPreferences.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func functionBody(
        named name: String,
        in source: String
    ) throws -> String {
        let signature = "    func \(name)() {"
        let signatureRange = try XCTUnwrap(source.range(of: signature))
        let openingBrace = try XCTUnwrap(
            source[signatureRange.lowerBound...].firstIndex(of: "{")
        )
        var depth = 0
        var index = openingBrace

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(
                        source[source.index(after: openingBrace)..<index]
                    )
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        XCTFail("Could not find the end of \(name)")
        return ""
    }

    private func assignmentProperties(in body: String) -> Set<String> {
        captures(
            // Asset resets run inside clearUserAsset(s) closures so the
            // generation invalidation and preference mutation are atomic.
            // Count assignments at the function level and in those nested
            // closures; `let`/`var` locals do not match this pattern.
            pattern: #"(?m)^ {8,}([A-Za-z_][A-Za-z0-9_]*)\s*="#,
            in: body
        )
    }

    private func didSetPreferenceProperties(in source: String) -> Set<String> {
        let classStart = source.range(
            of: "@Observable final class DockyPreferences {"
        )!.lowerBound
        let storageBoundary = source.range(
            of: "    private let defaults: UserDefaults",
            range: classStart..<source.endIndex
        )!.lowerBound
        let preferenceStorage = String(source[classStart..<storageBoundary])
        return captures(
            pattern: #"(?m)^    var ([A-Za-z_][A-Za-z0-9_]*):[^\n]*\{\n        didSet \{"#,
            in: preferenceStorage
        )
    }

    private func captures(
        pattern: String,
        in source: String
    ) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: range).compactMap {
            guard let captureRange = Range($0.range(at: 1), in: source) else {
                return nil
            }
            return String(source[captureRange])
        })
    }
}

private enum ResetInventory {
    static let appearance: Set<String> = [
        "activeIndicatorColor",
        "activeIndicatorImagePath",
        "activeIndicatorOffset",
        "activeIndicatorScale",
        "activeIndicatorShape",
        "disablesGlassLook",
        "dividerColor",
        "dividerImagePath",
        "dividerImageScale",
        "dividerOffset",
        "dividerOpacity",
        "dividerPaddingFraction",
        "iconShadowColor",
        "iconShadowOpacity",
        "iconShadowRadius",
        "leftDividerImagePath",
        "mirrorsLeftDividerOnRight",
        "rightDividerImagePath",
        "tileActiveBackgroundColor",
        "tileActiveBackgroundCornerRadius",
        "tileActiveBackgroundImagePath",
        "tileActiveBackgroundOpacity",
        "tileClipShape",
        "tileHoverBackgroundColor",
        "tileHoverBackgroundCornerRadius",
        "tileHoverBackgroundImagePath",
        "tileHoverBackgroundOpacity",
        "tileHoverOpacity",
        "tileHoverScale",
        "tileIconPadding",
        "tileSpacing",
        "tileVerticalPadding",
        "widget1xContentPadding",
        "widget1xCornerRadius",
        "widget2xContentPadding",
        "widget2xCornerRadius",
        "widget3xContentPadding",
        "widget3xCornerRadius",
        "widget4xContentPadding",
        "widget4xCornerRadius",
        "windowBackgroundImageMode",
        "windowBackgroundImagePath",
        "windowBorderColor",
        "windowBorderWidth",
        "windowClipShape",
        "windowContentInsetBottom",
        "windowContentInsetLeading",
        "windowContentInsetTop",
        "windowContentInsetTrailing",
        "windowCornerRadius",
        "windowCornerRadiusBottomLeading",
        "windowCornerRadiusBottomTrailing",
        "windowCornerRadiusTopLeading",
        "windowCornerRadiusTopTrailing",
        "windowTintColor",
        "windowTintOpacity",
    ]

    static let behavior: Set<String> = [
        "appTileFrontmostClickBehavior",
        "autohideAnimationDuration",
        "autohideWindowDelay",
        "autohidesWindow",
        "enablesShelveMode",
        "enablesWidgetHoverPreview",
        "folderBadgeMode",
        "folderBadgePreviewStyle",
        "fullscreenRevealDelay",
        "hidesDuringFullscreen",
        "hidesRecentApps",
        "hidesSystemDock",
        "maximizedWindowBehavior",
        "opensAtLogin",
        "overflowBehavior",
        "shelveHidesFinder",
        "shelveHidesTrash",
        "showsActivePinnedSeparator",
        "showsAppBadges",
        "showsGroupedOpenedAppsBackdrop",
        "showsGroupedOpenedAppsInDock",
        "showsMinimizedWindows",
        "showsRunningApps",
        "widgetHoverPreviewDelay",
        "widgetHoverPreviewSpans",
        "windowAxisSizing",
        "windowDisplayTarget",
        "windowPosition",
        "windowSpaceBehavior",
    ]

    static let fullOnly: Set<String> = [
        "appIconOverrides",
        "enablesLaunchpadOverlay",
        "enablesStartMenuOverlay",
        "enablesWindowSwitcher",
        "folderIconOverrides",
        "hidesProfileStrip",
        "includesMinimizedWindows",
        "launchpadBackgroundBlursImage",
        "launchpadBackgroundImagePath",
        "launchpadBaseIconSize",
        "launchpadColumnSpacing",
        "launchpadGridColumnCount",
        "launchpadGridRowCount",
        "launchpadIconPaddingFraction",
        "launchpadIconPath",
        "launchpadLayoutAxis",
        "launchpadOverlayTransparency",
        "launchpadShortcut",
        "launchpadSortMode",
        "opensStartMenuFromFinderTile",
        "showsWindowSwitcherFocusPreview",
        "startMenuIconPaddingFraction",
        "startMenuIconPath",
        "switcherCloseKeyCode",
        "switcherMinimizeKeyCode",
        "switcherZoomKeyCode",
        "trashIconOverrides",
        "windowPreviewHoverDelay",
        "windowPreviewLayout",
        "windowSwitcherLayout",
        "windowSwitcherPreviewMode",
        "windowSwitcherShortcut",
    ]

    static let intentionallyPreserved: Set<String> = [
        "appWidgetDisplays",
        "hasSeenDockEditorHint",
        "hiddenAppBundleIdentifiers",
        "photoFrameBookmarks",
        "pinnedAppBundleIdentifiers",
        "pinnedItems",
        "trailingItems",
        "widgetPlacements",
    ]
}
