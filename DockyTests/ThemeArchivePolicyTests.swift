import Foundation
import XCTest

nonisolated final class ThemeArchivePolicyTests: XCTestCase {
    func testArchiveListingRejectsTraversalAndAmbiguousPaths() throws {
        for unsafePath in [
            "../outside",
            "theme/../../outside",
            "/absolute/theme.json",
            #"C:\theme\theme.json"#,
            "C:/theme/theme.json",
            "theme//theme.json",
            "theme/./theme.json",
            "theme/\nname.png",
            "theme/\rname.png",
        ] {
            XCTAssertThrowsError(
                try ThemeArchivePolicy.validateArchiveEntryPath(unsafePath),
                unsafePath
            )
        }

        XCTAssertNoThrow(
            try ThemeArchivePolicy.validateArchiveEntryPath(
                "safe-theme/assets/icon.png"
            )
        )
        XCTAssertNoThrow(
            try ThemeArchivePolicy.validateArchiveEntryPath("safe-theme/")
        )
    }

    func testArchiveListingIsBoundedAndMustBeUTF8() throws {
        let listing = Data(
            "theme/theme.json\ntheme/assets/icon.png\n".utf8
        )
        XCTAssertEqual(
            try ThemeArchivePolicy.validatedArchiveEntries(
                from: listing
            ),
            ["theme/theme.json", "theme/assets/icon.png"]
        )

        let oneEntryLimit = ThemeArchiveLimits(
            maximumArchiveBytes: 100,
            maximumListingBytes: 100,
            maximumEntryCount: 1,
            maximumExpandedBytes: 100,
            maximumManifestBytes: 100
        )
        XCTAssertThrowsError(
            try ThemeArchivePolicy.validatedArchiveEntries(
                from: listing,
                limits: oneEntryLimit
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeArchivePolicyError,
                .tooManyEntries
            )
        }
        XCTAssertThrowsError(
            try ThemeArchivePolicy.validatedArchiveEntries(
                from: Data([0xFF, 0x0A])
            )
        )
    }

    func testArchiveListingRejectsFilesystemCollisionsAndFileAncestors()
        throws {
        for listing in [
            "theme/theme.json\ntheme/theme.json\n",
            "theme/theme.json\ntheme/Theme.json\n",
            "theme/caf\u{00E9}.png\ntheme/cafe\u{0301}.png\n",
            "theme/assets\ntheme/assets/icon.png\n",
        ] {
            XCTAssertThrowsError(
                try ThemeArchivePolicy.validatedArchiveEntries(
                    from: Data(listing.utf8)
                ),
                listing
            ) { error in
                XCTAssertEqual(
                    error as? ThemeArchivePolicyError,
                    .invalidArchiveListing
                )
            }
        }
    }

    func testDeclaredArchiveTotalsAreBoundedBeforeExtraction() throws {
        let limits = ThemeArchiveLimits(
            maximumArchiveBytes: 100,
            maximumListingBytes: 100,
            maximumEntryCount: 2,
            maximumExpandedBytes: 10,
            maximumManifestBytes: 100
        )
        XCTAssertNoThrow(
            try ThemeArchivePolicy.validateArchiveTotals(
                from: Data(
                    "2 files, 10 bytes uncompressed, 4 bytes compressed: 60%\n"
                        .utf8
                ),
                limits: limits
            )
        )
        XCTAssertThrowsError(
            try ThemeArchivePolicy.validateArchiveTotals(
                from: Data(
                    "3 files, 10 bytes uncompressed, 4 bytes compressed: 60%\n"
                        .utf8
                ),
                limits: limits
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeArchivePolicyError,
                .tooManyEntries
            )
        }
        XCTAssertThrowsError(
            try ThemeArchivePolicy.validateArchiveTotals(
                from: Data(
                    "1 file, 11 bytes uncompressed, 4 bytes compressed: 63%\n"
                        .utf8
                ),
                limits: limits
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeArchivePolicyError,
                .expandedContentTooLarge
            )
        }
    }

    func testSelectedArchiveMustBeBoundedRegularFileNotSymlink() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let archive = fixture.appendingPathComponent("theme.dockytheme")
        let link = fixture.appendingPathComponent("linked.dockytheme")
        try Data(repeating: 0x41, count: 11).write(to: archive)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: archive
        )

        XCTAssertNoThrow(
            try ThemeArchivePolicy.validateArchiveFile(at: archive)
        )
        XCTAssertThrowsError(
            try ThemeArchivePolicy.validateArchiveFile(at: link)
        ) { error in
            XCTAssertEqual(
                error as? ThemeArchivePolicyError,
                .archiveIsNotRegularFile
            )
        }

        let limits = ThemeArchiveLimits(
            maximumArchiveBytes: 10,
            maximumListingBytes: 100,
            maximumEntryCount: 10,
            maximumExpandedBytes: 100,
            maximumManifestBytes: 100
        )
        XCTAssertThrowsError(
            try ThemeArchivePolicy.validateArchiveFile(
                at: archive,
                limits: limits
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeArchivePolicyError,
                .archiveTooLarge
            )
        }
    }

    func testExtractedTreeAcceptsOnlyRegularFilesAndDirectories() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let assets = fixture.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: fixture.appendingPathComponent("theme.json")
        )
        try Data("image".utf8).write(
            to: assets.appendingPathComponent("icon.png")
        )

        XCTAssertNoThrow(
            try ThemeArchivePolicy.validateExtractedTree(at: fixture)
        )
        XCTAssertEqual(
            ThemeArchivePolicy.safeRegularFile(
                atRelativePath: "assets/icon.png",
                within: fixture
            ),
            assets.appendingPathComponent("icon.png")
        )
    }

    func testExtractedTreeAndAssetLookupRejectSymlinks() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let external = fixture.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("external".utf8).write(to: external)

        let assets = fixture.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        let link = assets.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: external
        )

        XCTAssertThrowsError(
            try ThemeArchivePolicy.validateExtractedTree(at: fixture)
        )
        XCTAssertNil(
            ThemeArchivePolicy.safeRegularFile(
                atRelativePath: "assets/linked.png",
                within: fixture
            )
        )
    }

    func testAssetLookupRejectsSymlinkedDirectoryComponent() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let realAssets = fixture.appendingPathComponent(
            "real-assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realAssets,
            withIntermediateDirectories: true
        )
        try Data("image".utf8).write(
            to: realAssets.appendingPathComponent("icon.png")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.appendingPathComponent("assets"),
            withDestinationURL: realAssets
        )

        XCTAssertNil(
            ThemeArchivePolicy.safeRegularFile(
                atRelativePath: "assets/icon.png",
                within: fixture
            )
        )
    }

    func testExpandedTreeLimitsAreEnforced() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(repeating: 0x41, count: 11).write(
            to: fixture.appendingPathComponent("large.bin")
        )
        let limits = ThemeArchiveLimits(
            maximumArchiveBytes: 100,
            maximumListingBytes: 100,
            maximumEntryCount: 10,
            maximumExpandedBytes: 10,
            maximumManifestBytes: 100
        )

        XCTAssertThrowsError(
            try ThemeArchivePolicy.validateExtractedTree(
                at: fixture,
                limits: limits
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeArchivePolicyError,
                .expandedContentTooLarge
            )
        }
    }

    func testThemeIdentifiersRemainCompatibleAndSafe() {
        XCTAssertTrue(
            ThemeArchivePolicy.isValidThemeID("com.example.Dark_Theme-2")
        )
        XCTAssertFalse(ThemeArchivePolicy.isValidThemeID("../escape"))
        XCTAssertFalse(ThemeArchivePolicy.isValidThemeID(".hidden"))
        XCTAssertEqual(
            ThemeArchivePolicy.slugifyThemeID("My Theme 2"),
            "my-theme-2"
        )
    }

    func testProcessRunnerDrainsBothPipesAndBoundsStoredOutput()
        async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 4000 ]; do printf 1234567890; printf 0987654321 >&2; i=$((i+1)); done",
            ],
            timeout: 5,
            maximumStandardOutputBytes: 1_024,
            maximumStandardErrorBytes: 1_024
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.count, 1_024)
        XCTAssertEqual(result.standardError.count, 1_024)
        XCTAssertTrue(result.standardOutputWasTruncated)
        XCTAssertTrue(result.standardErrorWasTruncated)
    }

    func testProcessRunnerTimeoutTerminatesPromptly() async {
        let start = Date()
        do {
            _ = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05,
                maximumStandardOutputBytes: 100,
                maximumStandardErrorBytes: 100
            )
            XCTFail("Expected the bounded process to time out.")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testProcessRunnerCancellationTerminatesPromptly() async {
        let start = Date()
        let task = Task {
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 10,
                maximumStandardOutputBytes: 100,
                maximumStandardErrorBytes: 100
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the bounded process to be cancelled.")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        } catch {
            XCTFail("Expected CancellationError, received \(error).")
        }
    }

    func testThemeManagerDoesNoFilesystemWorkDuringInitialization() throws {
        let source = try sourceFile("Docky/Services/ThemeManager.swift")
        let modelSource = try sourceFile("Docky/Models/Theme.swift")
        let initializer = try sourceSection(
            in: source,
            startingWith: "    private init() {",
            endingWith: "\n    }"
        )
        XCTAssertFalse(initializer.contains("FileManager"))
        XCTAssertFalse(initializer.contains("refresh"))
        XCTAssertFalse(initializer.contains("createDirectory"))
        XCTAssertTrue(source.contains("func bootstrap() async throws"))
        XCTAssertTrue(source.contains("func refreshInstalled() async throws"))
        XCTAssertTrue(
            modelSource.contains(
                "nonisolated struct ThemeManifest: Codable, Equatable, Sendable"
            )
        )
    }

    func testRuntimeThemeMutationPolicyFailsClosedWithLocalizedErrors() {
        for operation in ThemeRuntimeMutation.allCases {
            XCTAssertFalse(
                ThemeRuntimeMutationPolicy.isAllowed(operation)
            )
            XCTAssertThrowsError(
                try ThemeRuntimeMutationPolicy.reject(operation)
            ) { error in
                XCTAssertEqual(
                    error as? ThemeRuntimeMutationError,
                    .disabled(operation)
                )
                let description =
                    (error as? LocalizedError)?.errorDescription
                XCTAssertFalse(description?.isEmpty ?? true)
                XCTAssertTrue(
                    description?.contains("temporarily unavailable")
                        ?? false
                )
            }
        }

        let explanation =
            ThemeRuntimeMutationPolicy.unavailableExplanation
        XCTAssertTrue(explanation.contains("import"))
        XCTAssertTrue(explanation.contains("export"))
        XCTAssertTrue(explanation.contains("deletion"))
    }

    func testThemeCatalogRefreshIsSerializedAndReadOnly() throws {
        let source = try sourceFile(
            "Docky/Models/ThemeStorageWorker.swift"
        )
        let refreshSource = try sourceSection(
            in: source,
            startingWith:
                "    private nonisolated static func refreshCatalogSynchronously(",
            endingWith:
                "\n    private nonisolated static func prepareUserThemesDirectory("
        )

        XCTAssertTrue(source.contains("actor ThemeStorageWorker"))
        XCTAssertTrue(source.contains("private func serialized<T: Sendable>"))
        XCTAssertTrue(source.contains("operationTail"))
        XCTAssertTrue(refreshSource.contains("scanInstalledThemes("))
        for mutation in [
            "prepareUserThemesDirectory",
            "createDirectory",
            "setAttributes",
            "recoverInterruptedInstallBackups",
            "moveItem",
            "removeItem",
        ] {
            XCTAssertFalse(refreshSource.contains(mutation), mutation)
        }

        XCTAssertEqual(
            source.components(
                separatedBy:
                    "Runtime theme mutation is disabled until fd-relative tree operations are implemented."
            ).count - 1,
            3
        )
    }

    func testThemeManagerRejectsMutationsAtBoundary() throws {
        let source = try sourceFile("Docky/Services/ThemeManager.swift")
        XCTAssertTrue(
            source.contains(
                "ThemeRuntimeMutationPolicy.reject(.deleteTheme)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "ThemeRuntimeMutationPolicy.reject(.importTheme)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "ThemeRuntimeMutationPolicy.reject(.exportTheme)"
            )
        )
        XCTAssertFalse(source.contains("storageWorker.deleteTheme("))
        XCTAssertFalse(source.contains("storageWorker.importTheme("))
        XCTAssertFalse(source.contains("storageWorker.exportTheme("))
    }

    func testThemeSettingsExposesReadOnlyActionsOnly() throws {
        let source = try sourceFile(
            "Docky/Views/SettingsWindow/ThemesSettingsView.swift"
        )
        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertTrue(source.contains("try await manager.bootstrap()"))
        XCTAssertTrue(
            source.contains("try await manager.refreshInstalled()")
        )
        XCTAssertTrue(
            source.contains(
                "ThemeRuntimeMutationPolicy.unavailableExplanation"
            )
        )
        XCTAssertTrue(source.contains("Reveal Themes Folder"))
        XCTAssertFalse(source.contains("NSOpenPanel"))
        XCTAssertFalse(source.contains("NSSavePanel"))
        XCTAssertFalse(source.contains(".confirmationDialog("))
        XCTAssertFalse(source.contains("manager.importTheme("))
        XCTAssertFalse(source.contains("manager.exportCurrentAppearance("))
        XCTAssertFalse(source.contains("manager.deleteTheme("))
        XCTAssertFalse(source.contains("themeIDPendingDeletion"))
        XCTAssertFalse(source.contains("NSImage(contentsOf:"))
        XCTAssertFalse(source.contains("FileManager.default.fileExists"))
    }

    func testAppDelegateDoesNotOfferThemeImport() throws {
        let source = try sourceFile("Docky/AppDelegate.swift")
        let openHandler = try sourceSection(
            in: source,
            startingWith:
                "    func application(_ application: NSApplication, open urls: [URL]) {",
            endingWith: "\n    /// Routes a `docky://` URL"
        )
        XCTAssertTrue(
            openHandler.contains(
                "ThemeRuntimeMutationPolicy.unavailableExplanation"
            )
        )
        XCTAssertTrue(
            openHandler.contains(
                "Theme import is temporarily unavailable"
            )
        )
        XCTAssertFalse(openHandler.contains("ThemeManager.shared.importTheme"))
        XCTAssertFalse(openHandler.contains("Import this Docky theme?"))
        XCTAssertFalse(openHandler.contains("addButton(withTitle: \"Import\")"))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ThemeArchivePolicyTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSection(
        in source: String,
        startingWith startMarker: String,
        endingWith endMarker: String
    ) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
            )
        )
        return source[start.lowerBound..<end.lowerBound]
    }
}
