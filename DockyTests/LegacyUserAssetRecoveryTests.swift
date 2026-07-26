import Foundation
import XCTest

final class LegacyUserAssetRecoveryTests: XCTestCase {
    func testCandidateDiscoveryIsLexicalAndDoesNotRequireFilesToExist() {
        let managedDirectory = URL(
            fileURLWithPath: "/tmp/nonexistent/Docky/UserAssets",
            isDirectory: true
        )
        let references = [
            LegacyUserAssetReference(
                target: .launchpadIcon,
                sourcePath: "/Users/example/Pictures/icon.png",
                slot: "launchpad"
            ),
            LegacyUserAssetReference(
                target: .windowBackground,
                sourcePath: managedDirectory
                    .appendingPathComponent("missing-managed.png")
                    .path,
                slot: "window"
            ),
            LegacyUserAssetReference(
                target: .divider,
                sourcePath: managedDirectory
                    .appendingPathComponent("nested/divider.png")
                    .path,
                slot: "divider"
            ),
            LegacyUserAssetReference(
                target: .startMenuIcon,
                sourcePath: "",
                slot: "empty"
            ),
            LegacyUserAssetReference(
                target: .tileHoverBackground,
                sourcePath: "relative/image.png",
                slot: "relative"
            ),
        ]

        let candidates = LegacyUserAssetRecoveryPlanner.candidates(
            from: references,
            managedDirectory: managedDirectory
        )

        XCTAssertEqual(
            candidates.map(\.target),
            [.launchpadIcon, .divider]
        )
    }

    func testCommitGateRejectsLateResultAfterPreferenceChanges() {
        let capturedPath = "/Users/example/Pictures/old.png"

        XCTAssertTrue(
            LegacyUserAssetRecoveryPlanner.canReplace(
                currentPath: capturedPath,
                expectedSourcePath: capturedPath
            )
        )
        XCTAssertFalse(
            LegacyUserAssetRecoveryPlanner.canReplace(
                currentPath: "/Users/example/Pictures/new.png",
                expectedSourcePath: capturedPath
            )
        )
        XCTAssertFalse(
            LegacyUserAssetRecoveryPlanner.canReplace(
                currentPath: nil,
                expectedSourcePath: capturedPath
            )
        )
    }

    func testDiagnosticKindsDoNotExposeAssociatedIdentifiers() {
        XCTAssertEqual(
            LegacyUserAssetTarget.appIcon(
                bundleIdentifier: "com.private.Example"
            ).diagnosticKind,
            "appIcon"
        )
        XCTAssertEqual(
            LegacyUserAssetTarget.folderIcon(
                folderPath: "/Users/example/Secret"
            ).diagnosticKind,
            "folderIcon"
        )
    }

    func testRecoveryImportsStayProtectedUntilPreferenceResolution()
        async throws {
        let fileManager = FileManager.default
        let fixture = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "docky-legacy-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: fixture) }
        try fileManager.createDirectory(
            at: fixture,
            withIntermediateDirectories: false
        )

        let source = fixture.appendingPathComponent("legacy.png")
        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        try Data("legacy".utf8).write(to: source)
        let candidate = LegacyUserAssetCandidate(
            target: .launchpadIcon,
            sourcePath: source.path,
            slot: "legacy-test-slot"
        )

        let results =
            await LegacyUserAssetRecoveryWorker.importCandidates(
                [candidate],
                into: managed
            )
        let importedPath = try XCTUnwrap(
            results.first?.destinationPath
        )

        let removedWhilePending =
            await ManagedUserAssetStore.pruneUnreferencedAssetsOffMain(
                forSlot: candidate.slot,
                preservingPaths: [],
                within: managed
            )
        XCTAssertEqual(removedWhilePending, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: importedPath))

        let removedAfterResolution =
            await ManagedUserAssetStore.resolvePendingImportOffMain(
                atPath: importedPath,
                forSlot: candidate.slot,
                preservingPaths: [],
                within: managed
            )
        XCTAssertEqual(removedAfterResolution, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: importedPath))
    }

    func testRecoveryIsExplicitAndCoversEveryManagedImagePreference() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferencesSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/DockyPreferences.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Views/SettingsWindow/LegacyUserAssetRecoveryView.swift"
            ),
            encoding: .utf8
        )
        let recoveryModelSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Models/LegacyUserAssetRecovery.swift"
            ),
            encoding: .utf8
        )
        let appDelegateSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/AppDelegate.swift"
            ),
            encoding: .utf8
        )

        for expectedPath in [
            "appIconOverrides",
            "trashIconOverrides",
            "folderIconOverrides",
            "launchpadIconPath",
            "startMenuIconPath",
            "launchpadBackgroundImagePath",
            "activeIndicatorImagePath",
            "windowBackgroundImagePath",
            "tileActiveBackgroundImagePath",
            "tileHoverBackgroundImagePath",
            "dividerImagePath",
            "leftDividerImagePath",
            "rightDividerImagePath",
        ] {
            XCTAssertTrue(
                preferencesSource.contains(expectedPath),
                "Missing recovery coverage for \(expectedPath)"
            )
        }

        XCTAssertTrue(settingsSource.contains("Button(\"Recover "))
        XCTAssertTrue(
            settingsSource.contains(
                "await preferences.recoverLegacyUserAssets()"
            )
        )
        XCTAssertFalse(
            appDelegateSource.contains("recoverLegacyUserAssets()"),
            "Legacy sources must never be probed automatically at launch"
        )
        let plannerSource = recoveryModelSource
            .components(
                separatedBy: "nonisolated enum LegacyUserAssetRecoveryPlanner"
            )[1]
            .components(
                separatedBy: "nonisolated struct LegacyUserAssetImportResult"
            )[0]
        for prohibitedProbe in [
            "FileManager",
            "fileExists",
            "resourceValues",
            "Data(contentsOf:",
            "FileHandle",
        ] {
            XCTAssertFalse(
                plannerSource.contains(prohibitedProbe),
                "Candidate discovery must stay lexical: \(prohibitedProbe)"
            )
        }
        XCTAssertTrue(
            preferencesSource.contains(
                "LegacyUserAssetRecoveryWorker.importCandidates"
            )
        )
        XCTAssertTrue(
            recoveryModelSource.contains(
                "ManagedUserAssetStore.importAssetOffMain"
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                "resolvingPendingPath: destinationPath"
            )
        )
        XCTAssertTrue(
            preferencesSource.contains(
                "LegacyUserAssetRecoveryPlanner.canReplace"
            )
        )
        let pickerImportSource = preferencesSource
            .components(separatedBy: "func importUserAssetPath(")[1]
            .components(separatedBy: "func setAppIconOverride(")[0]
        XCTAssertFalse(pickerImportSource.contains("\"slot\": slot"))
        XCTAssertFalse(pickerImportSource.contains("localizedDescription"))
        XCTAssertTrue(pickerImportSource.contains("\"errorDomain\""))
        XCTAssertTrue(pickerImportSource.contains("\"errorCode\""))
    }

    func testPickerImportsAreAsyncAndPaddingNeverReimportsAssets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferencesSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/DockyPreferences.swift"
            ),
            encoding: .utf8
        )
        let managedStoreSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Models/ManagedUserAssetStore.swift"
            ),
            encoding: .utf8
        )

        let importSource = preferencesSource
            .components(separatedBy: "func importUserAssetPath(")[1]
            .components(separatedBy: "private func userAssetDiagnosticKind")[0]
        XCTAssertTrue(importSource.contains(") async -> String?"))
        XCTAssertTrue(
            importSource.contains(
                "await ManagedUserAssetStore.importAssetOffMain"
            )
        )
        XCTAssertFalse(importSource.contains("ManagedUserAssetStore.importAsset("))

        let detachedImportSource = managedStoreSource
            .components(separatedBy: "static func importAssetOffMain(")[1]
            .components(separatedBy: "private static func fileType(")[0]
        XCTAssertTrue(
            detachedImportSource.contains(
                "Task.detached(priority: .userInitiated)"
            )
        )

        for (functionName, nextFunctionName) in [
            ("setAppIconPaddingFraction", "removeAppIconOverride"),
            ("setTrashIconPaddingFraction", "removeTrashIconOverride"),
            ("setFolderIconPaddingFraction", "folderIconOverridePadding"),
        ] {
            let paddingSource = preferencesSource
                .components(separatedBy: "func \(functionName)(")[1]
                .components(separatedBy: "func \(nextFunctionName)(")[0]
            XCTAssertFalse(
                paddingSource.contains("importUserAssetPath"),
                "\(functionName) must not reread the managed image"
            )
            XCTAssertTrue(paddingSource.contains("iconPath: existing.iconPath"))
        }

        for relativePath in [
            "Docky/Views/SettingsWindow/AppIconsSettingsView.swift",
            "Docky/Views/SettingsWindow/AppearanceSettingsView.swift",
            "Docky/Views/SettingsWindow/LaunchpadSettingsView.swift",
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("Task { @MainActor in"),
                "\(relativePath) must resume preference updates on MainActor"
            )
            let importCallCount = source.components(
                separatedBy: "preferences.importUserAssetPath("
            ).count - 1
            let awaitedImportCallCount = source.components(
                separatedBy: "await preferences.importUserAssetPath("
            ).count - 1
            XCTAssertEqual(
                importCallCount,
                awaitedImportCallCount,
                "\(relativePath) has a synchronous picker import"
            )
        }
    }
}
