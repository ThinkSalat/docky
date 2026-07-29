import Foundation
import XCTest

final class SystemDockSettingsSnapshotTests: XCTestCase {
    func testThemeValuesDriveRuntimeUntilUserOverridesThem() {
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.tileSize(
                stored: 48,
                themed: 44,
                isOverridden: false
            ),
            44
        )
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.largeSize(
                stored: 64,
                themed: 72,
                isOverridden: false,
                effectiveTileSize: 44
            ),
            72
        )
        XCTAssertTrue(
            DockSettingsThemeResolutionPolicy.magnification(
                stored: false,
                themed: true,
                isOverridden: false
            )
        )
    }

    func testUserOverridesWinOverThemeValues() {
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.tileSize(
                stored: 52,
                themed: 44,
                isOverridden: true
            ),
            52
        )
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.largeSize(
                stored: 80,
                themed: 72,
                isOverridden: true,
                effectiveTileSize: 52
            ),
            80
        )
        XCTAssertFalse(
            DockSettingsThemeResolutionPolicy.magnification(
                stored: false,
                themed: true,
                isOverridden: true
            )
        )
    }

    func testEffectiveLargeSizeNeverFallsBelowEffectiveTileSize() {
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.largeSize(
                stored: 64,
                themed: 40,
                isOverridden: false,
                effectiveTileSize: 56
            ),
            56
        )
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.largeSize(
                stored: 42,
                themed: nil,
                isOverridden: true,
                effectiveTileSize: 56
            ),
            56
        )
    }

    func testInvalidThemeSizesFailClosedToSafeRuntimeSizes() {
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.tileSize(
                stored: 0,
                themed: .infinity,
                isOverridden: false
            ),
            48
        )
        XCTAssertEqual(
            DockSettingsThemeResolutionPolicy.largeSize(
                stored: .nan,
                themed: -10,
                isOverridden: false,
                effectiveTileSize: 48
            ),
            48
        )
    }

    func testStartupPolicyOnlyImportsWhenNoDockyStateExists() {
        XCTAssertEqual(
            SystemDockSettingsStartupPolicy.action(
                hasImportMarker: false,
                hasPersistedDockyValues: false
            ),
            .bootstrapFromSystemDock
        )
        XCTAssertEqual(
            SystemDockSettingsStartupPolicy.action(
                hasImportMarker: true,
                hasPersistedDockyValues: true
            ),
            .loadPersistedValues(repairImportMarker: false)
        )
        XCTAssertEqual(
            SystemDockSettingsStartupPolicy.action(
                hasImportMarker: true,
                hasPersistedDockyValues: false
            ),
            .loadPersistedValues(repairImportMarker: false)
        )
    }

    func testStartupPolicyRepairsMissingMarkerWithoutReimporting() {
        XCTAssertEqual(
            SystemDockSettingsStartupPolicy.action(
                hasImportMarker: false,
                hasPersistedDockyValues: true
            ),
            .loadPersistedValues(repairImportMarker: true)
        )
    }

    func testParsesEverySupportedSystemDockValue() {
        let snapshot = SystemDockSettingsSnapshot(values: [
            "orientation": "left",
            "tilesize": NSNumber(value: 52),
            "largesize": NSNumber(value: 79),
            "magnification": NSNumber(value: true),
            "autohide": NSNumber(value: true),
            "autohide-delay": NSNumber(value: 0.25),
            "autohide-time-modifier": NSNumber(value: 0.8),
            "mineffect": "scale",
            "minimize-to-application": NSNumber(value: true),
            "show-recents": NSNumber(value: false),
            "show-process-indicators": NSNumber(value: true),
        ])

        XCTAssertEqual(snapshot.orientation, .left)
        XCTAssertEqual(snapshot.tileSize, 52)
        XCTAssertEqual(snapshot.largeSize, 79)
        XCTAssertEqual(snapshot.magnification, true)
        XCTAssertEqual(snapshot.autohide, true)
        XCTAssertEqual(snapshot.autohideDelay, 0.25)
        XCTAssertEqual(snapshot.autohideTimeModifier, 0.8)
        XCTAssertEqual(snapshot.minimizeEffect, .scale)
        XCTAssertEqual(snapshot.minimizeToApplication, true)
        XCTAssertEqual(snapshot.showRecents, false)
        XCTAssertEqual(snapshot.showProcessIndicators, true)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testRejectsInvalidEnumsAndUnsafeTileSizes() {
        let snapshot = SystemDockSettingsSnapshot(values: [
            "orientation": "diagonal",
            "tilesize": NSNumber(value: -1),
            "largesize": NSNumber(value: Double.infinity),
            "mineffect": "explode",
            "autohide-delay": NSNumber(value: Double.nan),
            "show-recents": NSNumber(value: true),
        ])

        XCTAssertNil(snapshot.orientation)
        XCTAssertNil(snapshot.tileSize)
        XCTAssertNil(snapshot.largeSize)
        XCTAssertNil(snapshot.minimizeEffect)
        XCTAssertNil(snapshot.autohideDelay)
        XCTAssertEqual(snapshot.showRecents, true)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testUnrelatedDockValuesDoNotCreateImportableSnapshot() {
        let snapshot = SystemDockSettingsSnapshot(values: [
            "persistent-apps": [["tile-data": ["file-label": "Finder"]]],
            "persistent-others": [],
        ])

        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(snapshot.importedAppearanceValues.isEmpty)
    }

    func testAppearanceOverrideMetadataOnlyIncludesImportedValues() {
        let partial = SystemDockSettingsSnapshot(values: [
            "tilesize": NSNumber(value: 48),
            "magnification": NSNumber(value: false),
            "autohide": NSNumber(value: true),
        ])

        XCTAssertEqual(
            partial.importedAppearanceValues,
            [.tileSize, .magnification]
        )
    }

    func testSnapshotRefreshCannotReachDockyMutationPath() throws {
        let source = try sourceFile(
            "Docky/Services/DockSettingsService.swift"
        )
        let refresh = try functionBody(
            signature:
                "    func refreshSystemDockSnapshot() -> Bool {",
            in: source
        )

        XCTAssertTrue(refresh.contains("systemSnapshot = snapshot"))
        XCTAssertFalse(refresh.contains("applyImportedValues"))
        XCTAssertFalse(refresh.contains("persistValues"))
        XCTAssertFalse(refresh.contains("markAppearanceOverrides"))

        let explicitImport = try functionBody(
            signature:
                "    func importCurrentSystemDockSettings() -> Bool {",
            in: source
        )
        XCTAssertTrue(
            explicitImport.contains(
                "marksAppearanceOverrides: true"
            )
        )

        let importImplementation = try functionBody(
            signature:
                "    private func importCurrentSystemDockSettings(",
            in: source
        )
        XCTAssertTrue(
            importImplementation.contains("applyImportedValues(snapshot)")
        )
        XCTAssertTrue(
            importImplementation.contains(
                "persistValues(hasImportedSystemDockSettings: true)"
            )
        )
        XCTAssertTrue(
            importImplementation.contains("markAppearanceOverrides")
        )
    }

    func testStartupPreservesStoredValuesAndOnlyTrueFirstRunImports() throws {
        let source = try sourceFile(
            "Docky/Services/DockSettingsService.swift"
        )
        let initializer = try functionBody(
            signature: "    private init() {",
            in: source
        )

        XCTAssertTrue(initializer.contains("loadPersistedValues()"))
        XCTAssertTrue(
            initializer.contains(
                "SystemDockSettingsStartupPolicy.action"
            )
        )
        XCTAssertTrue(
            initializer.contains(
                "Keys.persistedValueKeys.contains"
            )
        )
        XCTAssertTrue(
            initializer.contains("refreshSystemDockSnapshot()")
        )
        XCTAssertTrue(
            initializer.contains(
                "marksAppearanceOverrides: false"
            )
        )
    }

    func testImportAndReadOnlyRefreshAreClearlyNamedInUI() throws {
        let appearance = try sourceFile(
            "Docky/Views/SettingsWindow/AppearanceSettingsView.swift"
        )
        XCTAssertTrue(
            appearance.contains(
                #"Button("Import Current macOS Dock Settings")"#
            )
        )
        XCTAssertTrue(
            appearance.contains(
                #""Import macOS Dock settings?""#
            )
        )
        XCTAssertTrue(
            appearance.contains(
                "Refreshing diagnostics or system Dock data never imports"
            )
        )

        let divider = try sourceFile(
            "Docky/Views/Tiles/DividerTileView.swift"
        )
        XCTAssertTrue(
            divider.contains(
                #""Refresh System Dock Data""#
            )
        )
        XCTAssertTrue(
            divider.contains("refreshSystemDockSnapshot()")
        )
        XCTAssertFalse(divider.contains(#""Sync Dock""#))
    }

    func testRuntimeUsesEffectiveThemeAwareDockSettings() throws {
        let service = try sourceFile(
            "Docky/Services/DockSettingsService.swift"
        )
        XCTAssertTrue(
            service.contains(
                "activeManifest?.behavior?.largeSize"
            )
        )
        XCTAssertTrue(
            service.contains(
                "activeManifest?.behavior?.magnification"
            )
        )
        XCTAssertTrue(
            service.contains(
                "effectiveTileSize: effectiveTileSize"
            )
        )

        for path in [
            "Docky/Views/MainWindow/MainWindow.swift",
            "Docky/Views/MainWindow/MainWindowView.swift",
            "Docky/Views/Tiles/TileContainerView.swift",
            "Docky/Views/Tiles/AppFolderTileView.swift",
        ] {
            let runtime = try sourceFile(path)
            XCTAssertFalse(
                runtime.contains("dockSettings.displayTileSize"),
                path
            )
            XCTAssertFalse(
                runtime.contains("dockSettings.magnification"),
                path
            )
            XCTAssertFalse(
                runtime.contains("dockSettings.largeSize"),
                path
            )
        }

        let appearance = try sourceFile(
            "Docky/Views/SettingsWindow/AppearanceSettingsView.swift"
        )
        XCTAssertTrue(
            appearance.contains(
                "get: { dockSettings.effectiveMagnification }"
            )
        )
        XCTAssertTrue(
            appearance.contains(
                "get: { Double(dockSettings.effectiveLargeSize) }"
            )
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func functionBody(
        signature: String,
        in source: String
    ) throws -> String {
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
                    return String(source[signatureRange.lowerBound...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        XCTFail("Could not find end of function: \(signature)")
        return ""
    }
}
