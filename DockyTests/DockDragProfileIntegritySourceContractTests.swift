import Foundation
import XCTest

final class DockDragProfileIntegritySourceContractTests:
    XCTestCase
{
    func testExternalDropCarriesSessionCredentialsIntoCASMutations()
        throws
    {
        let dragService = try sourceFile(
            "Docky/Services/DockDragService.swift"
        )
        XCTAssertTrue(
            dragService.contains(
                "private var draggingSequenceNumber: Int?"
            )
        )
        XCTAssertTrue(
            dragService.contains(
                "interactionCredentials.profileID"
            )
        )
        XCTAssertTrue(
            dragService.contains(
                "interactionCredentials.revision"
            )
        )
        XCTAssertTrue(
            dragService.contains(
                "interactionCredentials.spaceGeneration"
            )
        )
        XCTAssertTrue(
            dragService.contains(
                "NSWorkspace.activeSpaceDidChangeNotification"
            )
        )

        let mainWindow = try sourceFile(
            "Docky/Views/MainWindow/MainWindowView.swift"
        )
        let performDrop = try sourceSection(
            in: mainWindow,
            startingWith:
                "    override func performDragOperation(",
            endingWith:
                "    private func readURLs("
        )
        XCTAssertTrue(
            performDrop.contains(
                ".hasCurrentInteractionCredentials("
            )
        )
        XCTAssertTrue(
            performDrop.contains(
                "expectedProfileID:"
            )
        )
        XCTAssertTrue(
            performDrop.contains(
                "interactionCredentials.profileID"
            )
        )
        XCTAssertTrue(
            performDrop.contains(
                "expectedRevision:"
            )
        )
        XCTAssertTrue(
            performDrop.contains(
                "interactionCredentials.revision"
            )
        )
    }

    func testPaletteDropRequiresOpaquePayloadAndCapturedProfile()
        throws
    {
        let editMode = try sourceFile(
            "Docky/Services/DockEditModeService.swift"
        )
        let validation = try sourceSection(
            in: editMode,
            startingWith:
                "    func hasCurrentPalettePayload(",
            endingWith:
                "    private func makePaletteDrag("
        )
        XCTAssertTrue(
            validation.contains(
                "paletteDrag.pasteboardToken == payload"
            )
        )
        XCTAssertTrue(
            validation.contains(
                "paletteDrag.expectedProfileID"
            )
        )
        XCTAssertTrue(
            validation.contains(
                "paletteDrag.expectedRevision"
            )
        )
        XCTAssertTrue(
            validation.contains(
                "paletteDrag.expectedSpaceGeneration"
            )
        )

        let editor = try sourceFile(
            "Docky/Views/MainWindow/DockEditorOverlayWindowController.swift"
        )
        let startDrag = try sourceSection(
            in: editor,
            startingWith:
                "    private func startDrag(",
            endingWith:
                "\n    }\n}"
        )
        XCTAssertTrue(
            startDrag.contains(
                "object: pasteboardToken as NSString"
            )
        )
        XCTAssertFalse(
            startDrag.contains(
                "object: variant.id as NSString"
            )
        )
    }

    func testVisibleInsertAndTrashRemovalUseGuardedProfileTransactions()
        throws
    {
        let tileStore = try sourceFile(
            "Docky/Services/TileStore.swift"
        )
        let pinnedInsert = try sourceSection(
            in: tileStore,
            startingWith:
                "    func insertPinnedItem(\n        _ item:",
            endingWith:
                "    func smartOrganizePinnedItems()"
        )
        XCTAssertTrue(
            pinnedInsert.contains(
                ".authoritativeInsertionIndex("
            )
        )
        XCTAssertTrue(
            pinnedInsert.contains(
                "applyActiveProfileTransaction("
            )
        )

        let trailingInsert = try sourceSection(
            in: tileStore,
            startingWith:
                "    func insertTrailingItem(",
            endingWith:
                "    func makePinnedItem("
        )
        XCTAssertTrue(
            trailingInsert.contains(
                ".authoritativeInsertionIndex("
            )
        )
        XCTAssertTrue(
            trailingInsert.contains(
                "applyActiveProfileTransaction("
            )
        )

        let removals = try sourceSection(
            in: tileStore,
            startingWith:
                "    func removePinnedItem(",
            endingWith:
                "    private static let finderBundleID"
        )
        XCTAssertEqual(
            removals.components(
                separatedBy:
                    "applyActiveProfileTransaction("
            ).count - 1,
            2
        )
    }

    func testGroupingAndAsyncOrganizationPreserveProfileState()
        throws
    {
        let tileStore = try sourceFile(
            "Docky/Services/TileStore.swift"
        )
        let grouping = try sourceSection(
            in: tileStore,
            startingWith:
                "    func groupApps(",
            endingWith:
                "    func renameAppFolder("
        )
        XCTAssertTrue(
            grouping.contains(
                "let detachedSet = Set("
            )
        )
        XCTAssertTrue(
            grouping.contains(
                "detachedSet.contains($0)"
            )
        )
        XCTAssertFalse(
            grouping.contains(
                "groupedSet.contains($0)"
            )
        )

        let organize = try sourceSection(
            in: tileStore,
            startingWith:
                "    func smartOrganizePinnedItems()",
            endingWith:
                "    @discardableResult\n    func setTrailingTileOrder("
        )
        XCTAssertTrue(
            organize.contains(
                "let expectedProfileID"
            )
        )
        XCTAssertTrue(
            organize.contains(
                "let expectedRevision"
            )
        )
        XCTAssertTrue(
            organize.contains(
                "applyActiveProfileTransaction("
            )
        )
        XCTAssertTrue(
            organize.contains(
                "profile.pinnedItems"
            )
        )
        XCTAssertFalse(
            organize.contains(
                "self.preferences.pinnedItems = organizedItems"
            )
        )
    }

    func testSystemDockSyncCarriesPreAwaitProfileCredentials()
        throws
    {
        let tileStore = try sourceFile(
            "Docky/Services/TileStore.swift"
        )
        let startupImport = try sourceSection(
            in: tileStore,
            startingWith:
                "    func syncPreferencesFromSystemDockIfNeeded()",
            endingWith:
                "    private func reloadSystemDockState("
        )
        XCTAssertTrue(
            startupImport.contains(
                "captureMutationCredentials()"
            )
        )
        XCTAssertTrue(
            startupImport.contains(
                "preferenceSyncCredentials: credentials"
            )
        )
        XCTAssertTrue(
            startupImport.contains(
                "profile.pinnedItems.isEmpty"
            )
        )
        XCTAssertFalse(
            startupImport.contains(
                "preferences.pinnedItems.isEmpty"
            )
        )

        let reload = try sourceSection(
            in: tileStore,
            startingWith:
                "    private func reloadSystemDockState(",
            endingWith:
                "    private func applySystemDockSnapshot("
        )
        let requestCapture = try XCTUnwrap(
            reload.range(
                of:
                    "let preferenceSyncRequest ="
            )
        )
        let detachedRead = try XCTUnwrap(
            reload.range(
                of:
                    "Task.detached(priority: .userInitiated)"
            )
        )
        XCTAssertLessThan(
            requestCapture.lowerBound,
            detachedRead.lowerBound
        )
        XCTAssertTrue(
            reload.contains(
                "SystemDockPreferenceSyncRequest("
            )
        )
        XCTAssertTrue(
            reload.contains(
                "didApplyPreferenceSync"
            )
        )
        XCTAssertTrue(
            reload.contains(
                ".marksSystemImportComplete == true"
            )
        )

        let profileSync = try sourceSection(
            in: tileStore,
            startingWith:
                "    private func applySystemDockPreferenceSync(",
            endingWith:
                "    private static func synchronizeSystemDockPreferences("
        )
        XCTAssertTrue(
            profileSync.contains(
                "applyActiveProfileTransaction("
            )
        )
        XCTAssertTrue(
            profileSync.contains(
                "credentials:"
            )
        )
        XCTAssertTrue(
            profileSync.contains(
                "profile: &profile"
            )
        )
        XCTAssertFalse(
            profileSync.contains(
                "preferences.pinnedItems ="
            )
        )
        XCTAssertFalse(
            profileSync.contains(
                "preferences.trailingItems ="
            )
        )
    }

    func testDockEditorCapturesProfileBeforeEachWorkerAwait()
        throws
    {
        let editor = try sourceFile(
            "Docky/Services/DockEditorService.swift"
        )
        let pinMutation = try sourceSection(
            in: editor,
            startingWith:
                "    func setPinnedApp(",
            endingWith:
                "    @discardableResult\n    func setPinnedItemOrder("
        )
        assertCredentialsCapturedBeforeAwait(
            in: pinMutation
        )

        let orderMutation = try sourceSection(
            in: editor,
            startingWith:
                "    func setPinnedItemOrder(",
            endingWith:
                "    nonisolated private static func updateDockPlist("
        )
        assertCredentialsCapturedBeforeAwait(
            in: orderMutation
        )
    }

    func testInternalDragIsSpaceScopedAndKeepsDockVisible()
        throws {
        let tileContainer = try sourceFile(
            "Docky/Views/Tiles/TileContainerView.swift"
        )
        XCTAssertTrue(
            tileContainer.contains(
                "draggedSpaceGeneration"
            )
        )
        XCTAssertTrue(
            tileContainer.contains(
                "spaceInteractionEpoch.generation"
            )
        )
        XCTAssertTrue(
            tileContainer.contains(
                "invalidateDragForSpaceChange()"
            )
        )

        let mainWindow = try sourceFile(
            "Docky/Views/MainWindow/MainWindow.swift"
        )
        XCTAssertTrue(
            mainWindow.contains(
                "DockPresentationService.shared.$internalDrag"
            )
        )
        XCTAssertTrue(
            mainWindow.contains(
                "internalDrag.tileID != nil"
            )
        )
    }

    private func assertCredentialsCapturedBeforeAwait(
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let capture =
                source.range(
                    of: "captureMutationCredentials()"
                ),
              let workerAwait =
                source.range(
                    of: "await worker.perform"
                ) else {
            XCTFail(
                "Expected credential capture and worker await",
                file: file,
                line: line
            )
            return
        }
        XCTAssertLessThan(
            capture.lowerBound,
            workerAwait.lowerBound,
            file: file,
            line: line
        )
        XCTAssertTrue(
            source.contains(
                "refreshAfterDockyEditedSystemDock("
            ),
            file: file,
            line: line
        )
        XCTAssertTrue(
            source.contains(
                "credentials: profileMutationCredentials"
            ),
            file: file,
            line: line
        )
    }

    private func sourceFile(
        _ relativePath: String
    ) throws -> String {
        let repositoryRoot =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL =
            relativePath.split(separator: "/")
            .reduce(repositoryRoot) {
                partial,
                component in
                partial.appendingPathComponent(
                    String(component)
                )
            }
        return try String(
            contentsOf: sourceURL,
            encoding: .utf8
        )
    }

    private func sourceSection(
        in source: String,
        startingWith start: String,
        endingWith end: String
    ) throws -> String {
        let startRange = try XCTUnwrap(
            source.range(of: start)
        )
        let endRange = try XCTUnwrap(
            source.range(
                of: end,
                range:
                    startRange.upperBound
                    ..< source.endIndex
            )
        )
        return String(
            source[
                startRange.lowerBound
                ..< endRange.lowerBound
            ]
        )
    }
}
