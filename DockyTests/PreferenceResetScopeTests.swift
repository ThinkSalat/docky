import Foundation
import Observation
import XCTest

final class PreferenceResetScopeTests: XCTestCase {
    func testOverrideObservationOnlyInvalidatesTheKeyBeingObserved() {
        let windowTintKey =
            DockyThemeOverrideKey.windowTintColor.rawValue
        let indicatorKey =
            DockyThemeOverrideKey.activeIndicatorColor.rawValue
        let store = DockyThemeOverrideObservationStore()
        let observedChanges = ObservationChangeCounter()

        withObservationTracking {
            _ = store.contains(windowTintKey)
        } onChange: {
            observedChanges.increment()
        }

        XCTAssertTrue(store.setOverridden(true, for: indicatorKey))
        XCTAssertEqual(observedChanges.value, 0)

        XCTAssertTrue(store.setOverridden(true, for: windowTintKey))
        XCTAssertEqual(observedChanges.value, 1)
    }

    func testOverrideKeySummaryRetainsBroadObservation() {
        let store = DockyThemeOverrideObservationStore()
        let indicatorKey =
            DockyThemeOverrideKey.activeIndicatorColor.rawValue
        let observedChanges = ObservationChangeCounter()

        withObservationTracking {
            _ = store.keys
        } onChange: {
            observedChanges.increment()
        }

        XCTAssertTrue(store.setOverridden(true, for: indicatorKey))
        XCTAssertEqual(observedChanges.value, 1)
        XCTAssertEqual(store.keys, [indicatorKey])
    }

    func testOverrideStoreReplacementUpdatesPerKeyMembership() {
        let tintKey = DockyThemeOverrideKey.windowTintColor.rawValue
        let indicatorKey =
            DockyThemeOverrideKey.activeIndicatorColor.rawValue
        let store = DockyThemeOverrideObservationStore(
            keys: [tintKey]
        )

        store.replaceAll(with: [indicatorKey])

        XCTAssertFalse(store.contains(tintKey))
        XCTAssertTrue(store.contains(indicatorKey))
        XCTAssertEqual(store.keys, [indicatorKey])
    }

    func testNativeLiquidGlassWithoutExplicitTintUsesNoTintLayer() {
        XCTAssertEqual(
            DockWindowTintLayerPolicy.resolve(
                hasExplicitTintPresentation: false,
                usesNativeLiquidGlass: true
            ),
            .transparent
        )
    }

    func testExplicitTintStillLayersOverNativeLiquidGlass() {
        XCTAssertEqual(
            DockWindowTintLayerPolicy.resolve(
                hasExplicitTintPresentation: true,
                usesNativeLiquidGlass: true
            ),
            .resolvedTint
        )
    }

    func testFallbackChromeKeepsResolvedTintLayer() {
        XCTAssertEqual(
            DockWindowTintLayerPolicy.resolve(
                hasExplicitTintPresentation: false,
                usesNativeLiquidGlass: false
            ),
            .resolvedTint
        )
    }

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

    func testStoredExplicitUserTileHoverChoiceAlwaysWinsMigration() {
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: false,
                storedProvenance:
                    TileHoverEffectsMasterProvenance.user.rawValue,
                storedMigrationVersion: nil,
                hasUsableThemeBootstrap: false,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: true
            ),
            .keepStored(false)
        )
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: true,
                storedProvenance:
                    TileHoverEffectsMasterProvenance.user.rawValue,
                storedMigrationVersion: 1,
                hasUsableThemeBootstrap: true,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: false
            ),
            .keepStored(true)
        )
    }

    func testInstallPromptOnlyStateStillCountsAsFreshInstall() {
        XCTAssertEqual(
            TileHoverEffectsInstallEvidencePolicy.classification(
                storedValue: nil,
                persistedKeys: [
                    "docky.applicationInstallPromptDeferredPath",
                ]
            ),
            .fresh
        )
        XCTAssertEqual(
            TileHoverEffectsInstallEvidencePolicy.classification(
                storedValue:
                    TileHoverEffectsInstallEvidencePolicy
                        .Classification.fresh.rawValue,
                persistedKeys: [
                    "docky.profiles",
                    "docky.hidesSystemDock",
                ]
            ),
            .fresh,
            "A recorded first-launch classification must survive unrelated "
                + "default materialization before theme bootstrap."
        )
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: nil,
                storedProvenance: nil,
                storedMigrationVersion: nil,
                hasUsableThemeBootstrap: true,
                isExistingInstall: false,
                legacyToggleHadEffectiveColor: false
            ),
            .materialize(true)
        )
    }

    func testHoverMigrationDefersWithoutUsableThemeBootstrap() {
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: nil,
                storedProvenance: nil,
                storedMigrationVersion: nil,
                hasUsableThemeBootstrap: false,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: true
            ),
            .deferUntilUsableTheme
        )
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: true,
                storedProvenance:
                    TileHoverEffectsMasterProvenance
                        .automaticMigration.rawValue,
                storedMigrationVersion: 1,
                hasUsableThemeBootstrap: false,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: false
            ),
            .deferUntilUsableTheme
        )
    }

    func testBrokenHoverMigrationIsRepairedExactlyOnce() {
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: true,
                storedProvenance: nil,
                storedMigrationVersion: nil,
                hasUsableThemeBootstrap: true,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: false
            ),
            .materialize(false)
        )
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: true,
                storedProvenance:
                    TileHoverEffectsMasterProvenance
                        .automaticMigration.rawValue,
                storedMigrationVersion: 1,
                hasUsableThemeBootstrap: true,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: false
            ),
            .materialize(false)
        )
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: false,
                storedProvenance:
                    TileHoverEffectsMasterProvenance
                        .automaticMigration.rawValue,
                storedMigrationVersion:
                    TileHoverEffectsMigrationPolicy.currentVersion,
                hasUsableThemeBootstrap: true,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: true
            ),
            .keepStored(false)
        )
    }

    func testUnversionedLiveOffValueRepairsWithoutTurningBackOn() {
        XCTAssertEqual(
            TileHoverEffectsMigrationPolicy.action(
                storedMasterValue: false,
                storedProvenance: nil,
                storedMigrationVersion: nil,
                hasUsableThemeBootstrap: true,
                isExistingInstall: true,
                legacyToggleHadEffectiveColor: false
            ),
            .materialize(false)
        )
    }

    func testLegacyHoverEffectiveColorTruthTable() {
        typealias Case = (
            mode: ThemeOptionalAppearanceMode?,
            override: Bool,
            custom: Bool,
            theme: Bool,
            expected: Bool
        )
        let cases: [Case] = [
            // Cleared override with dormant decoded raw data stayed OFF.
            (nil, false, true, false, false),
            (nil, true, true, false, true),
            // A valid effective theme color kept the old toggle ON.
            (nil, false, false, true, true),
            // Corrupt local data decoded absent; legacy fallback still used
            // a valid theme when one existed.
            (nil, true, false, false, false),
            (nil, true, false, true, true),
            (.inherit, true, true, false, false),
            (.inherit, false, false, true, true),
            (.disabled, true, true, true, false),
            (.custom, false, true, true, true),
            (.custom, false, false, true, false),
        ]

        for item in cases {
            XCTAssertEqual(
                TileHoverEffectsMigrationPolicy
                    .legacyToggleHadEffectiveColor(
                        explicitMode: item.mode,
                        legacyAppearanceOverrideIsSet:
                            item.override,
                        hasDecodedCustomColor: item.custom,
                        hasValidatedThemeColor: item.theme
                    ),
                item.expected,
                "mode=\(String(describing: item.mode)) "
                    + "override=\(item.override) custom=\(item.custom) "
                    + "theme=\(item.theme)"
            )
        }
    }

    func testLegacyHoverMigrationUsesEffectiveDecodedColorAfterThemeBootstrap()
        throws
    {
        let preferencesSource = try dockyPreferencesSource()
        XCTAssertFalse(
            preferencesSource.contains(
                "hasPersistedLegacyBackgroundColor:"
            ),
            "Raw preference-key presence must not stand in for the old "
                + "effective-color toggle."
        )
        XCTAssertTrue(
            preferencesSource.contains(
                "legacyToggleHadEffectiveColor:"
            )
        )
        let migrationBody = try declarationBody(
            containing:
                "func resolveTileHoverEffectsMigrationAfterThemeBootstrap()",
            in: preferencesSource
        )
        XCTAssertTrue(
            migrationBody.contains(
                "tileHoverBackgroundColor != nil"
            ),
            "A corrupt local color must count as absent after decoding."
        )
        XCTAssertTrue(
            migrationBody.contains(
                ".appearance.tile?.hover?.backgroundColor?.nsColor"
            ),
            "A theme-only color counts only when it resolves to a valid color."
        )
        XCTAssertTrue(
            migrationBody.contains("optionalAppearanceModes[")
        )
        XCTAssertTrue(
            migrationBody.contains(
                "userOverriddenAppearanceKeys.contains("
            ),
            "Dormant decoded data must count only when the old effective "
                + "getter would have selected the local override."
        )
        XCTAssertFalse(
            migrationBody.contains(
                "storedTileHoverBackgroundColor != nil"
            ),
            "Raw color data must never be used as effective color intent."
        )

        let appDelegateSource = try sourceFile("Docky/AppDelegate.swift")
        let launchBody = try declarationBody(
            containing:
                "func applicationDidFinishLaunching(_ aNotification:",
            in: appDelegateSource
        )
        let themeBootstrap = try XCTUnwrap(
            launchBody.range(of: "ThemeManager.shared.bootstrap()")
        )
        let hoverMigration = try XCTUnwrap(
            launchBody.range(
                of:
                    "resolveTileHoverEffectsMigrationAfterThemeBootstrap()"
            )
        )
        let bootstrapCatch = try XCTUnwrap(
            launchBody.range(of: "} catch {")
        )
        XCTAssertLessThan(
            themeBootstrap.lowerBound,
            hoverMigration.lowerBound,
            "Theme-only color intent cannot be known until bootstrap ends."
        )
        XCTAssertLessThan(
            hoverMigration.lowerBound,
            bootstrapCatch.lowerBound,
            "A thrown/failed bootstrap must defer rather than finalize."
        )
        XCTAssertTrue(
            launchBody.contains(
                "guard ThemeManager.shared.hasLoadedCatalog else"
            )
        )
        XCTAssertTrue(
            migrationBody.contains(
                "hasUsableThemeBootstrap:"
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                #""docky.tileHoverEffectsMasterProvenance""#
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                #""docky.tileHoverEffectsInstallClassification""#
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                #""docky.tileHoverEffectsMigrationVersion""#
            )
        )
        XCTAssertTrue(
            migrationBody.contains(
                "provenance: .automaticMigration"
            )
        )
    }

    func testDisabledTileHoverRuntimeIsNeutralAcrossEveryVisualChannel() {
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.scale(
                isEnabled: false,
                configured: 1.16
            ),
            1
        )
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.tileOpacity(
                isEnabled: false,
                configured: 0.5
            ),
            1
        )
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.backgroundOpacity(
                isEnabled: false,
                configured: 0.75
            ),
            0
        )
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.backgroundCornerRadius(
                isEnabled: false,
                configured: 18
            ),
            0
        )
        XCTAssertFalse(
            TileHoverEffectsRuntimePolicy.allowsBackgroundSource(
                isEnabled: false
            )
        )
    }

    func testEnabledTileHoverRuntimePreservesConfiguredValues() {
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.scale(
                isEnabled: true,
                configured: 1.16
            ),
            1.16
        )
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.tileOpacity(
                isEnabled: true,
                configured: 0.5
            ),
            0.5
        )
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.backgroundOpacity(
                isEnabled: true,
                configured: 0.75
            ),
            0.75
        )
        XCTAssertEqual(
            TileHoverEffectsRuntimePolicy.backgroundCornerRadius(
                isEnabled: true,
                configured: 18
            ),
            18
        )
        XCTAssertTrue(
            TileHoverEffectsRuntimePolicy.allowsBackgroundSource(
                isEnabled: true
            )
        )
    }

    func testDisabledTileHoverMasterSuppressesEveryPresentationGate() {
        XCTAssertFalse(
            TileHoverEffectsRuntimePolicy.allowsHoverPresentation(
                isEnabled: false,
                featureEnabled: true
            ),
            "The global master must dominate an enabled tooltip or preview."
        )
        XCTAssertFalse(
            TileHoverEffectsRuntimePolicy.allowsHoverPresentation(
                isEnabled: false,
                featureEnabled: false
            )
        )
        XCTAssertFalse(
            TileHoverEffectsRuntimePolicy.allowsMagnification(
                isEnabled: false,
                configuredEnabled: true
            ),
            "The global master must dominate configured magnification."
        )
        XCTAssertFalse(
            TileHoverEffectsRuntimePolicy.allowsMagnification(
                isEnabled: false,
                configuredEnabled: false
            )
        )
    }

    func testEnabledTileHoverMasterStillRespectsSubordinateFeatureGates() {
        XCTAssertTrue(
            TileHoverEffectsRuntimePolicy.allowsHoverPresentation(
                isEnabled: true,
                featureEnabled: true
            )
        )
        XCTAssertFalse(
            TileHoverEffectsRuntimePolicy.allowsHoverPresentation(
                isEnabled: true,
                featureEnabled: false
            )
        )
        XCTAssertTrue(
            TileHoverEffectsRuntimePolicy.allowsMagnification(
                isEnabled: true,
                configuredEnabled: true
            )
        )
        XCTAssertFalse(
            TileHoverEffectsRuntimePolicy.allowsMagnification(
                isEnabled: true,
                configuredEnabled: false
            )
        )
    }

    func testTileHoverMasterIsRecheckedAcrossEveryRuntimeSurface() throws {
        let tileSource = try tileViewSource()
        let masterChange = try declarationBody(
            containing:
                ".onChange(of: preferences.tileHoverEffectsEnabled)",
            in: tileSource
        )
        XCTAssertTrue(
            masterChange.contains("updateTooltipPresentation()"),
            "Changing the master must immediately hide or restore titles."
        )
        XCTAssertTrue(
            masterChange.contains("updateWindowPreviewPresentation("),
            "Changing the master must cancel/dismiss window previews."
        )
        XCTAssertTrue(
            masterChange.contains("updateWidgetExpansionPresentation("),
            "Changing the master must cancel/dismiss widget previews."
        )

        let tooltipBody = try declarationBody(
            containing: "private func updateTooltipPresentation()",
            in: tileSource
        )
        XCTAssertTrue(
            tooltipBody.contains("preferences.tileHoverEffectsEnabled"),
            "Title tooltips must be subordinate to the global master."
        )

        let windowPreviewBody = try declarationBody(
            containing:
                "private func updateWindowPreviewPresentation(isHovering:",
            in: tileSource
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(
                of: "preferences.tileHoverEffectsEnabled",
                in: windowPreviewBody
            ),
            2,
            "Window previews must check the master both before scheduling "
                + "and again after their hover delay."
        )

        let widgetPreviewBody = try declarationBody(
            containing:
                "private func updateWidgetExpansionPresentation(isHovering:",
            in: tileSource
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(
                of: "preferences.tileHoverEffectsEnabled",
                in: widgetPreviewBody
            ),
            2,
            "Widget previews must check the master both before scheduling "
                + "and again after their hover delay."
        )

        let containerSource = try sourceFile(
            "Docky/Views/Tiles/TileContainerView.swift"
        )
        let magnificationActiveBody = try declarationBody(
            containing: "private var magnificationActive: Bool",
            in: containerSource
        )
        XCTAssertTrue(
            magnificationActiveBody.contains(
                "preferences.tileHoverEffectsEnabled"
            ),
            "Tile layout must suppress magnification under the master."
        )
        let containerMasterChange = try declarationBody(
            containing:
                ".onChange(of: preferences.tileHoverEffectsEnabled)",
            in: containerSource
        )
        XCTAssertTrue(
            containerMasterChange.contains("clearPointer()"),
            "Turning the master off must clear a pointer already in flight."
        )

        let mainWindowSource = try sourceFile(
            "Docky/Views/MainWindow/MainWindow.swift"
        )
        let pointerForwardingBody = try declarationBody(
            containing:
                "private func forwardMagnificationPointer(",
            in: mainWindowSource
        )
        XCTAssertTrue(
            pointerForwardingBody.contains(
                "tileHoverEffectsEnabled"
            ),
            "The AppKit pointer bridge must not feed disabled magnification."
        )

        let mainWindowViewSource = try sourceFile(
            "Docky/Views/MainWindow/MainWindowView.swift"
        )
        let trackingBody = try declarationBody(
            containing: "private var isTrackingMagnification: Bool",
            in: mainWindowViewSource
        )
        XCTAssertTrue(
            trackingBody.contains("tileHoverEffectsEnabled"),
            "Chrome animation tracking must use the same master gate."
        )
    }

    func testNowPlayingTransportHoverOverlayUsesTheGlobalMaster() throws {
        let source = try sourceFile(
            "Docky/Views/Tiles/NowPlayingWidgetTileView.swift"
        )
        XCTAssertTrue(
            source.contains(
                "@Bindable private var preferences = DockyPreferences.shared"
            ),
            "The widget must observe master changes while the pointer stays "
                + "stationary."
        )
        let oneUpBody = try declarationBody(
            containing: "private func nowPlayingOneUp(layout:",
            in: source
        )
        XCTAssertTrue(
            oneUpBody.contains("showsHoverTransportOverlay")
        )
        let overlayGateBody = try declarationBody(
            containing: "private var showsHoverTransportOverlay: Bool",
            in: source
        )
        XCTAssertTrue(overlayGateBody.contains("isHovering"))
        XCTAssertTrue(
            overlayGateBody.contains(
                "preferences.tileHoverEffectsEnabled"
            ),
            "The play/pause transport overlay is a visible hover effect and "
                + "must not bypass the global master."
        )
        XCTAssertTrue(
            overlayGateBody.contains(
                "TileHoverEffectsRuntimePolicy.allowsHoverPresentation("
            )
        )
    }

    func testHoverMasterResamplesMagnificationUnderAStationaryPointer() throws {
        let source = try sourceFile(
            "Docky/Views/MainWindow/MainWindow.swift"
        )
        let containerBody = try declarationBody(
            containing: "final class MainWindowContainerView: NSView",
            in: source
        )
        let observationBody = try declarationBody(
            containing:
                "private func observeTileHoverEffectsPreference()",
            in: containerBody
        )
        XCTAssertTrue(
            observationBody.contains("withObservationTracking")
        )
        XCTAssertTrue(
            observationBody.contains(
                "DockyPreferences.shared.tileHoverEffectsEnabled"
            )
        )
        XCTAssertTrue(
            observationBody.contains(
                "resampleMagnificationPointerFromCurrentLocation()"
            ),
            "OFF -> ON must not wait for a new mouseMoved event."
        )
        XCTAssertTrue(
            observationBody.contains("magnification.clearPointer()")
                || observationBody.contains(
                    "DockMagnificationService.shared.clearPointer()"
                ),
            "ON -> OFF must still clear the current sample immediately."
        )

        let resampleBody = try declarationBody(
            containing:
                "func resampleMagnificationPointerFromCurrentLocation()",
            in: source
        )
        XCTAssertTrue(
            resampleBody.contains("mouseLocationOutsideOfEventStream"),
            "The resample must read the current pointer without waiting "
                + "for another event."
        )
        XCTAssertTrue(
            resampleBody.contains(
                "forwardMagnificationPointer(locationInWindow:"
            ),
            "The stationary sample must enter the same path as live mouse "
                + "events."
        )

        let forwardingBody = try declarationBody(
            containing:
                "private func forwardMagnificationPointer(",
            in: source
        )
        XCTAssertTrue(
            forwardingBody.contains("contentView.convert("),
            "Live events and resamples must share hosting-view conversion."
        )
        XCTAssertTrue(
            forwardingBody.contains("cursorIsAtChromeFringe("),
            "Resampling must retain the normal chrome-fringe rejection."
        )
        XCTAssertTrue(
            forwardingBody.contains("magnification.updatePointer(")
                || forwardingBody.contains(
                    "DockMagnificationService.shared.updatePointer("
                ),
            "A valid stationary sample must reach the magnification service."
        )
    }

    func testTileHoverSettingsExposeOneMasterAndDormantSubordinates() throws {
        let appearanceSource = try appearanceSettingsSource()
        XCTAssertTrue(appearanceSource.contains(#""Tile Hover Effects""#))
        XCTAssertTrue(
            appearanceSource.contains(#""Enable Tile Hover Effects""#)
        )
        XCTAssertTrue(
            appearanceSource.contains(
                "isOn: $preferences.tileHoverEffectsEnabled"
            )
        )
        XCTAssertFalse(
            appearanceSource.contains(
                "Controls only the tile's hover background"
            ),
            "The settings copy must not claim the global master is visual-only."
        )

        let magnificationSettings = try sourceSegment(
            from: "Toggle(isOn: systemDockMagnificationBinding)",
            to: #"Section("macOS Dock Import")"#,
            in: appearanceSource
        )
        XCTAssertTrue(
            magnificationSettings.contains(
                ".disabled(!preferences.tileHoverEffectsEnabled)"
            ),
            "Magnification stays configured but must be dormant while "
                + "the global master is off."
        )

        let windowSettings = try windowManagementSettingsSource()
        let windowPreviewSettings = try sourceSegment(
            from: #"Section("Window Preview")"#,
            to: ".formStyle(.grouped)",
            in: windowSettings
        )
        XCTAssertTrue(
            windowPreviewSettings.contains(
                "preferences.tileHoverEffectsEnabled"
            )
        )
        XCTAssertTrue(
            windowPreviewSettings.contains(
                ".disabled(!preferences.tileHoverEffectsEnabled)"
            ),
            "The subordinate window-preview controls must remain visible "
                + "but dormant under the master."
        )

        let behaviorSource = try behaviorSettingsSource()
        let widgetSettings = try declarationBody(
            containing: "private var widgetsSection: some View",
            in: behaviorSource
        )
        XCTAssertTrue(
            widgetSettings.contains("preferences.tileHoverEffectsEnabled")
        )
        XCTAssertTrue(
            widgetSettings.contains(
                ".disabled(!preferences.tileHoverEffectsEnabled)"
            ),
            "The subordinate widget-preview controls must remain visible "
                + "but dormant under the master."
        )
    }

    func testBehaviorResetUsesSafeRecoveryValuesForExternalEffects() throws {
        XCTAssertFalse(DockyBehaviorResetSafetyPolicy.opensAtLogin)
        XCTAssertFalse(DockyBehaviorResetSafetyPolicy.hidesSystemDock)
        XCTAssertFalse(
            DockyBehaviorResetSafetyPolicy.enablesWidgetHoverPreview
        )

        let source = try dockyPreferencesSource()
        let behaviorBody = try functionBody(
            named: "resetBehaviorToDefaults",
            in: source
        )
        XCTAssertTrue(
            behaviorBody.contains(
                "DockyBehaviorResetSafetyPolicy.opensAtLogin"
            )
        )
        XCTAssertTrue(
            behaviorBody.contains(
                "DockyBehaviorResetSafetyPolicy.hidesSystemDock"
            )
        )
        XCTAssertTrue(
            behaviorBody.contains(
                "DockyBehaviorResetSafetyPolicy.enablesWidgetHoverPreview"
            )
        )
    }

    func testMissingSystemDockPreferencePreservesAndMaterializesLegacyDefault()
    {
        XCTAssertTrue(
            SystemDockVisibilityStoredPreferencePolicy.resolve(
                storedValue: nil
            )
        )
        XCTAssertTrue(
            SystemDockVisibilityStoredPreferencePolicy.shouldMaterialize(
                storedValue: nil
            )
        )

        XCTAssertFalse(
            SystemDockVisibilityStoredPreferencePolicy.resolve(
                storedValue: false
            )
        )
        XCTAssertFalse(
            SystemDockVisibilityStoredPreferencePolicy.shouldMaterialize(
                storedValue: false
            )
        )

        XCTAssertTrue(
            SystemDockVisibilityStoredPreferencePolicy.resolve(
                storedValue: true
            )
        )
        XCTAssertFalse(
            SystemDockVisibilityStoredPreferencePolicy.shouldMaterialize(
                storedValue: true
            )
        )
    }

    func testMissingSystemDockPreferenceIsPersistedAfterInitialization()
        throws
    {
        let source = try dockyPreferencesSource()
        XCTAssertTrue(
            source.contains(
                "SystemDockVisibilityStoredPreferencePolicy.resolve("
            )
        )
        XCTAssertTrue(
            source.contains(
                "SystemDockVisibilityStoredPreferencePolicy.shouldMaterialize("
            )
        )
        XCTAssertTrue(
            source.contains(
                "forKey: Keys.hidesSystemDock"
            )
        )
    }

    func testLaunchAtLoginMutationCommitsOnlyConfirmedStates() {
        XCTAssertEqual(
            LaunchAtLoginPreferencePolicy.resolve(
                previousValue: false,
                requestedValue: true,
                result: .enabled
            ),
            LaunchAtLoginPreferenceResolution(
                value: true,
                shouldPersist: true,
                requiresApproval: false,
                errorMessage: nil
            )
        )
        XCTAssertEqual(
            LaunchAtLoginPreferencePolicy.resolve(
                previousValue: true,
                requestedValue: false,
                result: .disabled
            ).value,
            false
        )
    }

    func testLaunchAtLoginRequiresApprovalIsDistinctAndCommitted() {
        let resolution = LaunchAtLoginPreferencePolicy.resolve(
            previousValue: false,
            requestedValue: true,
            result: .requiresApproval
        )

        XCTAssertTrue(resolution.value)
        XCTAssertTrue(resolution.shouldPersist)
        XCTAssertTrue(resolution.requiresApproval)
        XCTAssertNil(resolution.errorMessage)
    }

    func testLaunchAtLoginFailureRetainsPreviousConfirmedValue() {
        let resolution = LaunchAtLoginPreferencePolicy.resolve(
            previousValue: true,
            requestedValue: false,
            result: .failed("denied")
        )

        XCTAssertTrue(resolution.value)
        XCTAssertFalse(resolution.shouldPersist)
        XCTAssertFalse(resolution.requiresApproval)
        XCTAssertEqual(resolution.errorMessage, "denied")
    }

    func testLaunchAtLoginContradictoryPostconditionFailsClosed() {
        let resolution = LaunchAtLoginPreferencePolicy.resolve(
            previousValue: false,
            requestedValue: true,
            result: .disabled
        )

        XCTAssertFalse(resolution.value)
        XCTAssertFalse(resolution.shouldPersist)
        XCTAssertNotNil(resolution.errorMessage)
    }

    func testLaunchAtLoginThrownMutationStillAcceptsMatchingPostcondition() {
        XCTAssertEqual(
            LaunchAtLoginMutationVerificationPolicy.result(
                requestedValue: true,
                observedStatus: .requiresApproval,
                mutationErrorDescription: "approval required"
            ),
            .requiresApproval
        )
        XCTAssertEqual(
            LaunchAtLoginMutationVerificationPolicy.result(
                requestedValue: false,
                observedStatus: .disabled,
                mutationErrorDescription: "already removed"
            ),
            .disabled
        )
    }

    func testLaunchAtLoginMismatchedPostconditionKeepsFailureDetail() {
        guard case .failed(let message) =
            LaunchAtLoginMutationVerificationPolicy.result(
                requestedValue: true,
                observedStatus: .disabled,
                mutationErrorDescription: "denied"
            )
        else {
            return XCTFail("Expected a verified failure")
        }

        XCTAssertTrue(message.contains("reported disabled"))
        XCTAssertTrue(message.contains("denied"))
    }

    func testLaunchAtLoginObservedStatusNeverRewritesSavedIntent() {
        XCTAssertEqual(
            LaunchAtLoginStatusPresentationPolicy.resolve(
                desiredValue: true,
                observedStatus: .enabled
            ),
            LaunchAtLoginStatusPresentation(
                requiresApproval: false,
                mismatchMessage: nil
            )
        )
        XCTAssertNotNil(
            LaunchAtLoginStatusPresentationPolicy.resolve(
                desiredValue: true,
                observedStatus: .disabled
            ).mismatchMessage
        )
    }

    func testSystemDockPreferenceCommitsOnlyVerifiedExternalState() {
        XCTAssertEqual(
            SystemDockVisibilityPreferencePolicy.resolve(
                previousValue: false,
                requestedValue: true,
                result: .hidden
            ),
            SystemDockVisibilityPreferenceResolution(
                value: true,
                shouldPersist: true,
                errorMessage: nil
            )
        )

        let failed =
            SystemDockVisibilityPreferencePolicy.resolve(
                previousValue: true,
                requestedValue: false,
                result: .failed("restore failed")
            )
        XCTAssertTrue(failed.value)
        XCTAssertFalse(failed.shouldPersist)
        XCTAssertEqual(failed.errorMessage, "restore failed")
    }

    func testSystemDockRecoveryTreatsAnotherSessionAsStaleDespitePIDReuse() {
        XCTAssertFalse(
            SystemDockRecoveryOwnershipPolicy.isCurrentSession(
                stateIsActive: true,
                ownerPID: 42,
                currentPID: 42,
                stateSessionID: "previous-session",
                currentSessionID: "current-session"
            )
        )
        XCTAssertTrue(
            SystemDockRecoveryOwnershipPolicy.isCurrentSession(
                stateIsActive: true,
                ownerPID: 42,
                currentPID: 42,
                stateSessionID: "current-session",
                currentSessionID: "current-session"
            )
        )

        XCTAssertEqual(
            SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: true,
                restoreCompleted: false,
                ownerPID: 42,
                currentPID: 42,
                stateSessionID: "previous-session",
                currentSessionID: "current-session",
                ownerProcessRunning: true
            ),
            .staleOwner
        )
    }

    func testSystemDockRecoveryLeavesLiveForeignOwnerUntouched() {
        XCTAssertEqual(
            SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: true,
                restoreCompleted: false,
                ownerPID: 41,
                currentPID: 42,
                stateSessionID: "live-owner",
                currentSessionID: "current-session",
                ownerProcessRunning: true
            ),
            .liveForeignOwner
        )
    }

    func testSystemDockRecoveryStillRecoversDeadForeignOwner() {
        XCTAssertEqual(
            SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: true,
                restoreCompleted: false,
                ownerPID: 41,
                currentPID: 42,
                stateSessionID: "dead-owner",
                currentSessionID: "current-session",
                ownerProcessRunning: false
            ),
            .staleOwner
        )
    }

    func testSystemDockRecoveryPreservesExactCurrentSession() {
        XCTAssertEqual(
            SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: true,
                restoreCompleted: false,
                ownerPID: 42,
                currentPID: 42,
                stateSessionID: "current-session",
                currentSessionID: "current-session",
                ownerProcessRunning: true
            ),
            .currentSession
        )
    }

    func testSystemDockCompletedTombstoneCanNeverReplaySnapshot() {
        XCTAssertEqual(
            SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: true,
                restoreCompleted: true,
                ownerPID: 41,
                currentPID: 42,
                stateSessionID: "old-generation",
                currentSessionID: "current-session",
                ownerProcessRunning: false
            ),
            .inactive
        )
    }

    func testSystemDockGenerationCASRejectsNewOwner() {
        let generationA = SystemDockRecoveryIdentity(
            ownerPID: 41,
            sessionID: "generation-a"
        )
        XCTAssertTrue(
            SystemDockRecoveryCoordinationPolicy.generationMatches(
                expected: generationA,
                actualOwnerPID: 41,
                actualSessionID: "generation-a"
            )
        )
        XCTAssertFalse(
            SystemDockRecoveryCoordinationPolicy.generationMatches(
                expected: generationA,
                actualOwnerPID: 42,
                actualSessionID: "generation-b"
            )
        )
    }

    func testSystemDockRecoveryLockSerializesGenerationTransactions()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = directory.appendingPathComponent("state.plist")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try? SystemDockRecoveryFileLock.withExclusiveLock(
                stateFileURL: stateURL
            ) {
                firstEntered.signal()
                releaseFirst.wait()
            }
            firstFinished.signal()
        }
        XCTAssertEqual(
            firstEntered.wait(timeout: .now() + 1),
            .success
        )

        DispatchQueue.global().async {
            _ = try? SystemDockRecoveryFileLock.withExclusiveLock(
                stateFileURL: stateURL
            ) {
                secondEntered.signal()
            }
            secondFinished.signal()
        }

        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 0.05),
            .timedOut
        )
        releaseFirst.signal()
        XCTAssertEqual(
            firstFinished.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(
            secondFinished.wait(timeout: .now() + 1),
            .success
        )
    }

    func testSystemDockNormalRestoreRequiresExactSessionOwnership() throws {
        let service = try sourceFile(
            "Docky/Services/SystemDockVisibilityService.swift"
        )
        XCTAssertTrue(
            service.contains(
                "SystemDockRecoveryCoordinationPolicy.disposition("
            )
        )
        XCTAssertTrue(
            service.contains(
                "so another session's snapshot cannot be "
            )
        )
        XCTAssertTrue(service.contains("restored or erased."))
        XCTAssertTrue(
            service.contains(
                "guard restoreAuthorizedLocked(authorization) else"
            )
        )
        XCTAssertTrue(service.contains("withRecoveryLock {"))
        XCTAssertTrue(service.contains("disposition == .liveForeignOwner"))
    }

    func testSystemDockSnapshotKeepsNumericZeroAndOneDistinctFromBooleans() {
        let marker = "__null__"
        XCTAssertEqual(
            SystemDockSnapshotTypingPolicy.scalar(
                for: NSNumber(value: 0.0),
                nullMarker: marker
            ),
            .number(0)
        )
        XCTAssertEqual(
            SystemDockSnapshotTypingPolicy.scalar(
                for: NSNumber(value: 1.0),
                nullMarker: marker
            ),
            .number(1)
        )
        XCTAssertEqual(
            SystemDockSnapshotTypingPolicy.scalar(
                for: NSNumber(value: false),
                nullMarker: marker
            ),
            .boolean(false)
        )
        XCTAssertEqual(
            SystemDockSnapshotTypingPolicy.scalar(
                for: NSNumber(value: true),
                nullMarker: marker
            ),
            .boolean(true)
        )
    }

    func testSystemDockRestoreAppliesOnlyTheManagedKeySubset() throws {
        let service = try sourceFile(
            "Docky/Services/SystemDockVisibilityService.swift"
        )
        XCTAssertTrue(
            service.contains(
                "isCompleteSupportedSnapshot(snapshot)"
            )
        )
        XCTAssertTrue(
            service.contains(
                "Self.managedKeys.compactMap"
            )
        )
        XCTAssertFalse(
            service.contains(
                "applyDockValues(snapshot, eventName: \"snapshotApplied\")"
            )
        )
    }

    func testHotKeyPreferenceRejectsFailedCandidateRegistration() {
        XCTAssertEqual(
            GlobalHotKeyPreferencePolicy.resolve(
                result: .registered
            ),
            GlobalHotKeyPreferenceResolution(
                shouldCommit: true,
                errorMessage: nil
            )
        )
        XCTAssertEqual(
            GlobalHotKeyPreferencePolicy.resolve(
                result: .inactive
            ).shouldCommit,
            true
        )

        let failed = GlobalHotKeyPreferencePolicy.resolve(
            result: .failed("conflict")
        )
        XCTAssertFalse(failed.shouldCommit)
        XCTAssertEqual(failed.errorMessage, "conflict")
    }

    func testWindowSwitcherBaseShortcutReservesShiftForReverseCycling() {
        XCTAssertEqual(
            WindowSwitcherBaseShortcutPolicy.validate(
                isConfigured: false,
                containsShift: true
            ),
            .inactive
        )
        XCTAssertEqual(
            WindowSwitcherBaseShortcutPolicy.validate(
                isConfigured: true,
                containsShift: false
            ),
            .accepted
        )

        guard case .rejected(let message) =
            WindowSwitcherBaseShortcutPolicy.validate(
                isConfigured: true,
                containsShift: true
            )
        else {
            return XCTFail(
                "A Shift-containing base chord must be rejected."
            )
        }
        XCTAssertTrue(message.contains("Shift"))
        XCTAssertTrue(message.contains("reverse cycling"))
        XCTAssertTrue(message.contains("previous shortcut was kept"))
    }

    func testHotKeyEnablementCommitsOnlyConfirmedServiceState() {
        XCTAssertEqual(
            GlobalHotKeyEnablementPreferencePolicy.resolve(
                previousValue: false,
                requestedValue: true,
                expectsRegistrationWhenEnabled: true,
                result: .registered
            ),
            GlobalHotKeyEnablementPreferenceResolution(
                value: true,
                shouldPersist: true,
                errorMessage: nil
            )
        )
        XCTAssertEqual(
            GlobalHotKeyEnablementPreferencePolicy.resolve(
                previousValue: false,
                requestedValue: true,
                expectsRegistrationWhenEnabled: false,
                result: .inactive
            ),
            GlobalHotKeyEnablementPreferenceResolution(
                value: true,
                shouldPersist: true,
                errorMessage: nil
            )
        )
        XCTAssertEqual(
            GlobalHotKeyEnablementPreferencePolicy.resolve(
                previousValue: true,
                requestedValue: false,
                expectsRegistrationWhenEnabled: true,
                result: .inactive
            ),
            GlobalHotKeyEnablementPreferenceResolution(
                value: false,
                shouldPersist: true,
                errorMessage: nil
            )
        )

        let missingRegistration =
            GlobalHotKeyEnablementPreferencePolicy.resolve(
                previousValue: false,
                requestedValue: true,
                expectsRegistrationWhenEnabled: true,
                result: .inactive
            )
        XCTAssertEqual(missingRegistration.value, false)
        XCTAssertFalse(missingRegistration.shouldPersist)
        XCTAssertNotNil(missingRegistration.errorMessage)

        let failed =
            GlobalHotKeyEnablementPreferencePolicy.resolve(
                previousValue: true,
                requestedValue: false,
                expectsRegistrationWhenEnabled: true,
                result: .failed("unregister failed")
            )
        XCTAssertEqual(failed.value, true)
        XCTAssertFalse(failed.shouldPersist)
        XCTAssertEqual(failed.errorMessage, "unregister failed")
    }

    func testHotKeyEnableTogglesAreCandidateFirstTransactions() throws {
        let preferences = try dockyPreferencesSource()
        XCTAssertTrue(
            preferences.contains(
                "private(set) var enablesLaunchpadOverlay: Bool"
            )
        )
        XCTAssertTrue(
            preferences.contains(
                "private(set) var enablesWindowSwitcher: Bool"
            )
        )

        let launchpadService = try XCTUnwrap(
            preferences.range(
                of: "LaunchpadHotKeyService.shared.setEnabled("
            )
        )
        let launchpadCommit = try XCTUnwrap(
            preferences.range(
                of: "enablesLaunchpadOverlay = resolution.value"
            )
        )
        XCTAssertLessThan(
            launchpadService.lowerBound,
            launchpadCommit.lowerBound
        )

        let switcherService = try XCTUnwrap(
            preferences.range(
                of: "WindowSwitcherService.shared.setEnabled("
            )
        )
        let switcherCommit = try XCTUnwrap(
            preferences.range(
                of: "enablesWindowSwitcher = resolution.value"
            )
        )
        XCTAssertLessThan(
            switcherService.lowerBound,
            switcherCommit.lowerBound
        )

        let launchpadView = try sourceFile(
            "Docky/Views/SettingsWindow/LaunchpadSettingsView.swift"
        )
        XCTAssertTrue(
            launchpadView.contains(
                "isOn: launchpadEnabledBinding"
            )
        )
        XCTAssertFalse(
            launchpadView.contains(
                "$preferences.enablesLaunchpadOverlay"
            )
        )

        let switcherView = try windowManagementSettingsSource()
        XCTAssertTrue(
            switcherView.contains(
                "isOn: windowSwitcherEnabledBinding"
            )
        )
        XCTAssertFalse(
            switcherView.contains(
                "$preferences.enablesWindowSwitcher"
            )
        )
        XCTAssertTrue(
            switcherView.contains(
                "Shift is reserved for reverse cycling."
            )
        )
    }

    func testGlobalHotKeyReplacementVerifiesEveryCleanupFailure() throws {
        let launchpad = try sourceFile(
            "Docky/Services/LaunchpadHotKeyService.swift"
        )
        XCTAssertTrue(
            launchpad.contains(
                "guard previousUnregisterStatus == noErr else"
            )
        )
        XCTAssertTrue(
            launchpad.contains("if candidateCleanupStatus != noErr")
        )
        XCTAssertTrue(
            launchpad.contains(
                "orphanedHotKeyRefs.append(candidateRef)"
            )
        )
        XCTAssertTrue(
            launchpad.contains("healTrackedRegistrationIfNeeded()")
        )
        XCTAssertTrue(
            launchpad.contains(
                "confirmed shortcut metadata were retained"
            )
        )

        let switcher = try sourceFile(
            "Docky/Services/WindowSwitcherService.swift"
        )
        XCTAssertTrue(
            switcher.contains("if cleanupStatus != noErr")
        )
        XCTAssertTrue(
            switcher.contains("cleanupCandidatePair(")
        )
        XCTAssertTrue(
            switcher.contains("healTrackedRegistrationIfNeeded()")
        )
        XCTAssertFalse(
            switcher.contains("restorePreviousForwardHotKey(")
        )
        XCTAssertTrue(
            switcher.contains(
                "orphanedHotKeyRefs.append(reference)"
            )
        )
        XCTAssertTrue(
            switcher.contains(
                "confirmed shortcut metadata were retained"
            )
        )
    }

    func testExternalSettingsLifecycleIsReadOnlyAtStartup() throws {
        let appDelegate = try sourceFile("Docky/AppDelegate.swift")
        XCTAssertTrue(
            appDelegate.contains("refreshOpenAtLoginStatus()")
        )
        XCTAssertTrue(
            appDelegate.contains(
                "func applicationDidBecomeActive("
            )
        )
        XCTAssertFalse(
            appDelegate.contains("applyOpenAtLoginPreference()")
        )
        XCTAssertFalse(
            appDelegate.contains(
                "enableOpenAtLoginOnFirstLaunchIfNeeded()"
            )
        )

        let preferences = try dockyPreferencesSource()
        XCTAssertFalse(
            preferences.contains(
                "enableOpenAtLoginOnFirstLaunchIfNeeded"
            )
        )
    }

    func testSystemDockWatchdogRequiresReadyHandshakeAndVerifiedRestore()
        throws
    {
        let service = try sourceFile(
            "Docky/Services/SystemDockVisibilityService.swift"
        )
        XCTAssertTrue(
            service.contains(
                #""watchdogReady": existingWatchdog != nil"#
            )
        )
        XCTAssertTrue(
            service.contains("verifiedCurrentWatchdogProcess()")
        )
        XCTAssertTrue(service.contains("readyState.watchdogReady"))
        XCTAssertTrue(service.contains("readyState.watchdogPID"))
        XCTAssertTrue(service.contains("dockValuesMatch(values)"))
        XCTAssertTrue(service.contains(#""restoreCompleted": true"#))
        XCTAssertTrue(
            service.contains("clearRecoveryMetadataLocked(")
        )

        let watchdog = try sourceFile(
            "DockyDockWatchdog/main.swift"
        )
        let readyRange = try XCTUnwrap(
            watchdog.range(of: "guard markWatchdogReady()")
        )
        let loopRange = try XCTUnwrap(
            watchdog.range(of: "while stateMatches()")
        )
        XCTAssertLessThan(
            readyRange.lowerBound,
            loopRange.lowerBound
        )

        let restoreRange = try XCTUnwrap(
            watchdog.range(of: "guard restoreSnapshot(")
        )
        let clearRange = try XCTUnwrap(
            watchdog.range(of: "guard clearDockySnapshot()")
        )
        XCTAssertLessThan(
            restoreRange.lowerBound,
            clearRange.lowerBound
        )
        let tombstoneRange = try XCTUnwrap(
            watchdog.range(of: "guard markRecoveryCompleted()")
        )
        XCTAssertLessThan(
            restoreRange.lowerBound,
            tombstoneRange.lowerBound
        )
        XCTAssertLessThan(
            tombstoneRange.lowerBound,
            clearRange.lowerBound
        )
        XCTAssertTrue(
            watchdog.contains(
                "SystemDockRecoveryFileLock.withExclusiveLock("
            )
        )
        XCTAssertTrue(
            watchdog.contains("guard !isProcessRunning(ownerPID) else")
        )
        XCTAssertTrue(
            watchdog.contains("guard removeCompletedStateFile() else")
        )
        XCTAssertTrue(
            watchdog.contains(
                "CFPreferencesCopyAppValue(snapshotKey, domain) == nil"
            )
        )
    }

    func testWindowHoverPreviewHasASeparatePersistedRuntimeGate() throws {
        let preferencesSource = try dockyPreferencesSource()
        XCTAssertTrue(
            preferencesSource.contains(
                "var enablesWindowHoverPreview: Bool {"
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                "static let enablesWindowHoverPreview"
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                #""docky.enablesWindowHoverPreview""#
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                "storedEnablesWindowHoverPreview"
            )
        )

        let tileSource = try tileViewSource()
        let windowPreviewBody = try declarationBody(
            containing:
                "private func updateWindowPreviewPresentation(isHovering:",
            in: tileSource
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(
                of:
                    "TileHoverEffectsRuntimePolicy"
                        + ".allowsHoverPresentation(",
                in: windowPreviewBody
            ),
            2,
            "The immediate and delayed paths must use the combined "
                + "master/subordinate runtime policy."
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(
                of: "preferences.tileHoverEffectsEnabled",
                in: windowPreviewBody
            ),
            2
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(
                of: "preferences.enablesWindowHoverPreview",
                in: windowPreviewBody
            ),
            2
        )
        XCTAssertTrue(
            tileSource.contains(
                ".onChange(of: preferences.enablesWindowHoverPreview)"
            )
        )

        let settingsSource = try windowManagementSettingsSource()
        XCTAssertTrue(
            settingsSource.contains(
                #""Show Window Previews on Hover""#
            )
        )
        XCTAssertTrue(
            settingsSource.contains(
                "isOn: $preferences.enablesWindowHoverPreview"
            )
        )
    }

    func testOptionalAppearanceModesResolveThemeOffAndCustomDistinctly() {
        XCTAssertEqual(
            ThemeOptionalAppearanceResolution.value(
                mode: .inherit,
                custom: "custom",
                themed: "theme"
            ),
            "theme"
        )
        XCTAssertNil(
            ThemeOptionalAppearanceResolution.value(
                mode: .disabled,
                custom: "custom",
                themed: "theme"
            ) as String?
        )
        XCTAssertEqual(
            ThemeOptionalAppearanceResolution.value(
                mode: .custom,
                custom: "custom",
                themed: "theme"
            ),
            "custom"
        )
    }

    func testMissingCustomOptionalAppearanceFailsClosed() {
        XCTAssertNil(
            ThemeOptionalAppearanceResolution.value(
                mode: .custom,
                custom: nil,
                themed: "theme"
            ) as String?
        )
    }

    func testClearOverridesLeavesDormantOptionalNumericValueInactiveUntilExplicitCustomIntent() {
        let dormantCustom: CGFloat = 12
        let themed: CGFloat = 4

        XCTAssertEqual(
            ThemeOptionalAppearanceResolution.value(
                mode: .inherit,
                custom: dormantCustom,
                themed: themed
            ),
            themed,
            "Clearing override intent must ignore, but not destroy, dormant storage."
        )
        XCTAssertEqual(
            ThemeOptionalAppearanceResolution.value(
                mode: .custom,
                custom: dormantCustom,
                themed: themed
            ),
            dormantCustom,
            "An explicit same-value selection must reactivate dormant storage."
        )
    }

    func testOptionalAppearanceModeStorageRoundTripsAndFiltersInvalidData() {
        let validKey =
            DockyThemeOverrideKey.tileActiveBackgroundColor.rawValue
        let disabledKey =
            DockyThemeOverrideKey.windowBackgroundImagePath.rawValue
        let encoded = ThemeOptionalAppearanceModeStorage.encode([
            validKey: .custom,
            disabledKey: .disabled,
        ])

        XCTAssertEqual(encoded[validKey], "custom")
        XCTAssertEqual(encoded[disabledKey], "disabled")

        var stored = encoded
        stored["unknown.future.key"] = "disabled"
        stored[DockyThemeOverrideKey.iconShadowColor.rawValue] =
            "not-a-mode"
        XCTAssertEqual(
            ThemeOptionalAppearanceModeStorage.decode(
                stored,
                recognizedKeys:
                    DockyPreferenceResetScopeModel
                        .allKnownThemeOverrideKeys
            ),
            [
                validKey: .custom,
                disabledKey: .disabled,
            ]
        )
    }

    func testThemeAwareUserIntentCommitPersistsEvenForSameRawValue() throws {
        let source = try dockyPreferencesSource()
        let compact = source.filter { !$0.isWhitespace }

        XCTAssertEqual(
            compact.components(
                separatedBy: "funccommitUserAppearanceValue"
            ).count - 1,
            3,
            "CGFloat, Bool, and String-backed enum controls need typed "
                + "user-intent commits."
        )
        XCTAssertEqual(
            compact.components(
                separatedBy: "self[keyPath:keyPath]=value"
            ).count - 1,
            4,
            "The three nonoptional overloads and optional numeric "
                + "transaction must all update their typed storage."
        )
        XCTAssertEqual(
            compact.components(
                separatedBy: "forKey:key.rawValue"
            ).count - 1,
            4,
            "Every nonoptional overload plus the optional numeric "
                + "transaction must force-persist same-value user intent."
        )
        XCTAssertEqual(
            compact.components(
                separatedBy: "markAppearanceOverride(key.rawValue)"
            ).count - 1,
            3,
            "Every explicit Settings selection must establish user intent."
        )
    }

    func testOptionalNumericUserIntentCommitPersistsModeForSameDormantValue()
        throws
    {
        let source = try dockyPreferencesSource()
        let compact = source.filter { !$0.isWhitespace }

        XCTAssertTrue(
            compact.contains(
                "funccommitUserOptionalAppearanceValue("
                    + "_value:CGFloat,"
            )
        )
        XCTAssertTrue(
            compact.contains(
                "self[keyPath:keyPath]=value"
                    + "persistOptionalDouble(value,forKey:key.rawValue)"
                    + "setOptionalAppearanceMode(.custom,for:key)"
            ),
            "The explicit commit must persist and restore custom intent even "
                + "when assigning the same dormant raw value skips didSet."
        )
        XCTAssertTrue(
            compact.contains(
                "guardusesCustomelse{"
                    + "setOptionalAppearanceMode(.inherit,for:key)"
                    + "return}"
            ),
            "Inherit must change only source intent and preserve dormant raw storage."
        )
        XCTAssertTrue(
            compact.contains(
                "self[keyPath:keyPath]??effectiveValue()"
            ),
            "Re-enabling must prefer the dormant custom value before seeding "
                + "from the effective theme value."
        )
    }

    func testClearAllOverridesPreservesDormantOptionalNumericStorage() throws {
        let source = try dockyPreferencesSource()
        let body = try functionBody(
            named: "clearAllAppearanceOverrides",
            in: source
        )
        let dormantProperties = [
            "tileHoverOpacity",
            "tileHoverScale",
            "tileHoverBackgroundOpacity",
            "tileHoverBackgroundCornerRadius",
            "tileActiveBackgroundOpacity",
            "tileActiveBackgroundCornerRadius",
            "widget1xContentPadding",
            "widget1xCornerRadius",
            "widget2xContentPadding",
            "widget2xCornerRadius",
            "widget3xContentPadding",
            "widget3xCornerRadius",
            "widget4xContentPadding",
            "widget4xCornerRadius",
            "windowCornerRadiusTopLeading",
            "windowCornerRadiusTopTrailing",
            "windowCornerRadiusBottomLeading",
            "windowCornerRadiusBottomTrailing",
        ]

        XCTAssertTrue(body.contains("appearanceOverrideStore.replaceAll(with: [])"))
        XCTAssertTrue(body.contains("optionalAppearanceModes = [:]"))
        for property in dormantProperties {
            XCTAssertFalse(
                body.contains("\(property) ="),
                "Clear Overrides must preserve dormant \(property) storage."
            )
        }
    }

    func testAllNullableNumericAppearanceSettersSynchronizeTypedMode() throws {
        let source = try dockyPreferencesSource()
        let properties = [
            "tileHoverOpacity",
            "tileHoverScale",
            "tileHoverBackgroundOpacity",
            "tileHoverBackgroundCornerRadius",
            "tileActiveBackgroundOpacity",
            "tileActiveBackgroundCornerRadius",
            "widget1xContentPadding",
            "widget1xCornerRadius",
            "widget2xContentPadding",
            "widget2xCornerRadius",
            "widget3xContentPadding",
            "widget3xCornerRadius",
            "widget4xContentPadding",
            "widget4xCornerRadius",
            "windowCornerRadiusTopLeading",
            "windowCornerRadiusTopTrailing",
            "windowCornerRadiusBottomLeading",
            "windowCornerRadiusBottomTrailing",
        ]

        for property in properties {
            XCTAssertTrue(
                source.contains(
                    "updateOptionalAppearanceModeForStoredValue(\n"
                        + "                \(property) != nil,\n"
                        + "                key: Keys.\(property)\n"
                        + "            )"
                ),
                "\(property) must synchronize nullable storage with typed intent."
            )
        }
    }

    func testNullableNumericAppearanceControlsUseTypedIntentBindings() throws {
        let source = try appearanceSettingsSource()
        let compact = source.filter { !$0.isWhitespace }
        let sliderControls = [
            "tileHoverOpacity",
            "tileHoverScale",
            "tileHoverBackgroundOpacity",
            "tileHoverBackgroundCornerRadius",
            "tileActiveBackgroundOpacity",
            "tileActiveBackgroundCornerRadius",
        ]
        let widgetControls = [
            ("widget1xContentPadding", "padding"),
            ("widget1xCornerRadius", "radius"),
            ("widget2xContentPadding", "padding"),
            ("widget2xCornerRadius", "radius"),
            ("widget3xContentPadding", "padding"),
            ("widget3xCornerRadius", "radius"),
        ]
        let cornerControls = [
            "windowCornerRadiusTopLeading",
            "windowCornerRadiusTopTrailing",
            "windowCornerRadiusBottomLeading",
            "windowCornerRadiusBottomTrailing",
        ]

        for property in sliderControls {
            XCTAssertTrue(
                compact.contains(
                    "optionalNumericAppearanceBinding("
                        + "for:.\(property),"
                        + "at:\\.\(property),"
                ),
                "\(property) must force-commit same-value custom intent."
            )
        }

        for (property, label) in widgetControls {
            XCTAssertTrue(
                compact.contains("\(label)Key:.\(property),")
            )
            XCTAssertTrue(
                compact.contains("\(label)KeyPath:\\.\(property),")
            )
            XCTAssertFalse(
                compact.contains("$preferences.\(property)"),
                "\(property) UI state must not be inferred from dormant raw storage."
            )
        }

        for property in cornerControls {
            XCTAssertTrue(compact.contains("key:.\(property),"))
            XCTAssertTrue(compact.contains("keyPath:\\.\(property),"))
            XCTAssertFalse(
                compact.contains("$preferences.\(property)"),
                "\(property) UI state must not be inferred from dormant raw storage."
            )
        }

        XCTAssertTrue(
            compact.contains(
                "preferences.optionalAppearanceMode(for:key)==.custom"
            )
        )
        XCTAssertTrue(
            compact.contains(
                "preferences.setUserOptionalAppearanceUsesCustom("
            )
        )
    }

    func testAllNonOptionalAppearanceThemeControlsUseEffectiveBindings()
        throws
    {
        let source = try appearanceSettingsSource()
        let compact = source.filter { !$0.isWhitespace }
        let controls: [
            (
                key: String,
                property: String,
                effective: String
            )
        ] = [
            ("disablesGlassLook", "disablesGlassLook", "effectiveDisablesGlassLook"),
            ("activeIndicatorShape", "activeIndicatorShape", "effectiveActiveIndicatorShape"),
            ("activeIndicatorOffset", "activeIndicatorOffset", "effectiveActiveIndicatorOffset"),
            ("activeIndicatorScale", "activeIndicatorScale", "effectiveActiveIndicatorScale"),
            ("mirrorsLeftDividerOnRight", "mirrorsLeftDividerOnRight", "effectiveMirrorsLeftDividerOnRight"),
            ("dividerPaddingFraction", "dividerPaddingFraction", "effectiveDividerPaddingFraction"),
            ("dividerOffset", "dividerOffset", "effectiveDividerOffset"),
            ("dividerImageScale", "dividerImageScale", "effectiveDividerImageScale"),
            ("dividerOpacity", "dividerOpacity", "effectiveDividerOpacity"),
            ("tileClipShape", "tileClipShape", "effectiveTileClipShape"),
            ("tileVerticalPadding", "tileVerticalPadding", "effectiveTileVerticalPadding"),
            ("tileSpacing", "tileSpacing", "effectiveTileSpacing"),
            ("tileIconPadding", "tileIconPadding", "effectiveTileIconPadding"),
            ("iconShadowRadius", "iconShadowRadius", "effectiveIconShadowRadius"),
            ("iconShadowOpacity", "iconShadowOpacity", "effectiveIconShadowOpacity"),
            ("windowClipShape", "windowClipShape", "effectiveWindowClipShape"),
            ("windowCornerRadius", "windowCornerRadius", "effectiveWindowCornerRadius"),
            ("windowContentInsetTop", "windowContentInsetTop", "effectiveWindowContentInsetTop"),
            ("windowContentInsetLeading", "windowContentInsetLeading", "effectiveWindowContentInsetLeading"),
            ("windowContentInsetBottom", "windowContentInsetBottom", "effectiveWindowContentInsetBottom"),
            ("windowContentInsetTrailing", "windowContentInsetTrailing", "effectiveWindowContentInsetTrailing"),
            ("windowBorderWidth", "windowBorderWidth", "effectiveWindowBorderWidth"),
            ("windowBackgroundImageMode", "windowBackgroundImageMode", "effectiveWindowBackgroundImageMode"),
            ("windowTintOpacity", "windowTintOpacity", "effectiveWindowTintOpacity"),
        ]

        XCTAssertEqual(controls.count, 24)
        for control in controls {
            XCTAssertTrue(
                compact.contains("for:.\(control.key)"),
                "Missing typed override key for \(control.property)"
            )
            XCTAssertTrue(
                compact.contains("at:\\.\(control.property)"),
                "Missing typed key path for \(control.property)"
            )
            XCTAssertTrue(
                compact.contains(
                    "preferences.\(control.effective)"
                ),
                "The control must display \(control.effective)"
            )

            let escaped = NSRegularExpression.escapedPattern(
                for: control.property
            )
            let directBinding = try NSRegularExpression(
                pattern:
                    #"\$preferences\."# + escaped
                        + #"(?![A-Za-z0-9_])"#
            )
            XCTAssertEqual(
                directBinding.numberOfMatches(
                    in: source,
                    range: NSRange(source.startIndex..., in: source)
                ),
                0,
                "\(control.property) must not expose dormant raw storage."
            )
        }

        XCTAssertTrue(
            compact.contains(
                "get:{Double(dockSettings.effectiveTileSize)}"
            )
        )
        XCTAssertTrue(
            compact.contains(
                "get:{dockSettings.effectiveMagnification}"
            )
        )
        XCTAssertTrue(
            compact.contains(
                "get:{Double(dockSettings.effectiveLargeSize)}"
            )
        )
        XCTAssertFalse(compact.contains("dockSettings.tileSize"))
        XCTAssertFalse(compact.contains("dockSettings.largeSize"))
        XCTAssertFalse(compact.contains("dockSettings.magnification"))
    }

    func testThemeAwareAppearanceDerivedStateUsesEffectiveValues() throws {
        let source = try appearanceSettingsSource()
        let compact = source.filter { !$0.isWhitespace }

        for required in [
            "preferences.effectiveActiveIndicatorShape==.image",
            "!preferences.effectiveMirrorsLeftDividerOnRight",
            "dockSettings.effectiveMagnification",
            "preferences.effectiveWindowClipShape==.circle",
            "preferences.effectiveTileVerticalPadding*2",
            "letlower=Double(dockSettings.effectiveTileSize)",
        ] {
            XCTAssertTrue(
                compact.contains(required),
                "Missing effective derived-state expression: \(required)"
            )
        }

        XCTAssertTrue(
            compact.contains(
                "min(base.lowerBound,current)...max(base.upperBound,current)"
            ),
            "Slider ranges must include a valid active-theme value."
        )
    }

    func testBehaviorThemeControlsUseEffectiveUserIntentBindings() throws {
        let source = try behaviorSettingsSource()
        let compact = source.filter { !$0.isWhitespace }

        for required in [
            "get:{preferences.effectiveWindowAxisSizing}",
            "for:.windowAxisSizing",
            "at:\\.windowAxisSizing",
            "preferences.effectiveShowsActivePinnedSeparator",
            "for:.showsActivePinnedSeparator",
            "at:\\.showsActivePinnedSeparator",
        ] {
            XCTAssertTrue(
                compact.contains(required),
                "Missing behavior theme binding expression: \(required)"
            )
        }
        XCTAssertFalse(
            compact.contains("$preferences.windowAxisSizing")
        )
        XCTAssertFalse(
            compact.contains(
                "$preferences.showsActivePinnedSeparator"
            )
        )
    }

    func testPerCornerRadiusStorageSynchronizesTypedIntent() throws {
        let source = try dockyPreferencesSource()
        for property in [
            "windowCornerRadiusTopLeading",
            "windowCornerRadiusTopTrailing",
            "windowCornerRadiusBottomLeading",
            "windowCornerRadiusBottomTrailing",
        ] {
            XCTAssertTrue(
                source.contains(
                    "updateOptionalAppearanceModeForStoredValue(\n"
                        + "                \(property) != nil,\n"
                        + "                key: Keys.\(property)\n"
                        + "            )"
                ),
                "\(property) must distinguish dormant storage from source intent."
            )
        }
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
        var behavior = assignmentProperties(in: behaviorBody)
        if behaviorBody.contains("setOpenAtLogin(") {
            behavior.insert("opensAtLogin")
        }
        if behaviorBody.contains("setHidesSystemDock(") {
            behavior.insert("hidesSystemDock")
        }
        var fullOnly = assignmentProperties(in: fullBody)
        if fullBody.contains("setLaunchpadShortcut(") {
            fullOnly.insert("launchpadShortcut")
        }
        if fullBody.contains("setLaunchpadOverlayEnabled(") {
            fullOnly.insert("enablesLaunchpadOverlay")
        }
        if fullBody.contains("setWindowSwitcherShortcut(") {
            fullOnly.insert("windowSwitcherShortcut")
        }
        if fullBody.contains("setWindowSwitcherEnabled(") {
            fullOnly.insert("enablesWindowSwitcher")
        }

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

    func testSeparateHandoffDockPersistsOffByDefault() throws {
        let source = try dockyPreferencesSource()

        XCTAssertTrue(
            source.contains(
                #"static let separateHandoffDock = "docky.separateHandoffDock""#
            )
        )
        XCTAssertTrue(source.contains("static let separateHandoffDock = false"))
        XCTAssertTrue(source.contains("var separateHandoffDock: Bool {"))
        XCTAssertTrue(
            source.contains(
                "forKey: Keys.separateHandoffDock"
            )
        )
        XCTAssertTrue(
            source.contains(
                "storedSeparateHandoffDock"
            )
        )

        let behaviorBody = try functionBody(
            named: "resetBehaviorToDefaults",
            in: source
        )
        XCTAssertTrue(
            behaviorBody.contains(
                "separateHandoffDock = DefaultValues.separateHandoffDock"
            )
        )
    }

    func testSeparateHandoffDockIsExposedInPlacementSettings() throws {
        let source = try behaviorSettingsSource()

        XCTAssertTrue(source.contains(#""Separate Handoff Dock""#))
        XCTAssertTrue(
            source.contains(
                "isOn: $preferences.separateHandoffDock"
            )
        )
        XCTAssertTrue(
            source.contains(
                "Show Handoff in its own compact dock beside the main dock."
            )
        )
    }

    private func dockyPreferencesSource() throws -> String {
        try sourceFile(
            "Docky/Services/DockyPreferences.swift"
        )
    }

    private func behaviorSettingsSource() throws -> String {
        try sourceFile(
            "Docky/Views/SettingsWindow/BehaviorSettingsView.swift"
        )
    }

    private func appearanceSettingsSource() throws -> String {
        try sourceFile(
            "Docky/Views/SettingsWindow/AppearanceSettingsView.swift"
        )
    }

    private func tileViewSource() throws -> String {
        try sourceFile("Docky/Views/Tiles/TileView.swift")
    }

    private func windowManagementSettingsSource() throws -> String {
        try sourceFile(
            "Docky/Views/SettingsWindow/WindowManagementSettingsView.swift"
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = relativePath
            .split(separator: "/")
            .reduce(repositoryRoot) { partial, component in
                partial.appendingPathComponent(String(component))
            }
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func functionBody(
        named name: String,
        in source: String
    ) throws -> String {
        let signature = "    func \(name)() {"
        return try declarationBody(containing: signature, in: source)
    }

    private func declarationBody(
        containing declaration: String,
        in source: String
    ) throws -> String {
        let signatureRange = try XCTUnwrap(source.range(of: declaration))
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

        XCTFail("Could not find the end of \(declaration)")
        return ""
    }

    private func sourceSegment(
        from start: String,
        to end: String,
        in source: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(
                of: end,
                range: startRange.upperBound..<source.endIndex
            )
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func occurrenceCount(
        of needle: String,
        in source: String
    ) -> Int {
        source.components(separatedBy: needle).count - 1
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
            pattern: #"(?m)^    (?:private\(set\) )?var ([A-Za-z_][A-Za-z0-9_]*):[^\n]*\{\n        didSet \{"#,
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

private final class ObservationChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
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
        "tileHoverEffectsEnabled",
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
        "appFolderCreationHoverDelay",
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
        "separateHandoffDock",
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
        "enablesWindowHoverPreview",
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
