import Darwin
import Foundation
import XCTest

final class ManagedUserAssetStoreTests: XCTestCase {
    func testManagedCandidateContainmentIsLexicalAndDoesNotRequireFile() {
        let root = URL(fileURLWithPath: "/tmp/docky-managed-root")
        let candidate = root.appendingPathComponent("missing.png")

        XCTAssertEqual(
            ManagedUserAssetStore.managedCandidateURL(
                forPath: candidate.path,
                within: root
            ),
            candidate
        )
        XCTAssertNil(
            ManagedUserAssetStore.managedCandidateURL(
                forPath: root
                    .appendingPathComponent("../escaped.png")
                    .path,
                within: root
            )
        )
        XCTAssertNil(
            ManagedUserAssetStore.managedCandidateURL(
                forPath: root
                    .appendingPathComponent("nested/file.png")
                    .path,
                within: root
            )
        )
    }

    func testManagedURLAcceptsOnlyExistingRegularDirectChildren() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let root = fixture.appendingPathComponent(
            "UserAssets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let directChild = root.appendingPathComponent("icon.png")
        try Data("icon".utf8).write(to: directChild)

        XCTAssertEqual(
            ManagedUserAssetStore.managedURL(
                forPath: directChild.path,
                within: root
            ),
            directChild
        )
        XCTAssertNil(
            ManagedUserAssetStore.managedURL(
                forPath: root.appendingPathComponent(
                    "nested/icon.png"
                ).path,
                within: root
            )
        )
        XCTAssertNil(
            ManagedUserAssetStore.managedURL(
                forPath: fixture
                    .appendingPathComponent("UserAssets-other/icon.png")
                    .path,
                within: root
            )
        )
        XCTAssertNil(
            ManagedUserAssetStore.managedURL(
                forPath: "/Users/example/Documents/icon.png",
                within: root
            )
        )
        XCTAssertNil(
            ManagedUserAssetStore.managedURL(
                forPath: root.appendingPathComponent("missing.png").path,
                within: root
            )
        )
    }

    func testManagedURLRejectsDirectoriesAndSymlinks() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let root = fixture.appendingPathComponent(
            "UserAssets",
            isDirectory: true
        )
        let childDirectory = root.appendingPathComponent(
            "directory.png",
            isDirectory: true
        )
        let externalFile = fixture.appendingPathComponent("external.png")
        let childLink = root.appendingPathComponent("linked.png")
        try FileManager.default.createDirectory(
            at: childDirectory,
            withIntermediateDirectories: true
        )
        try Data("external".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: childLink,
            withDestinationURL: externalFile
        )

        XCTAssertNil(
            ManagedUserAssetStore.managedURL(
                forPath: childDirectory.path,
                within: root
            )
        )
        XCTAssertNil(
            ManagedUserAssetStore.managedURL(
                forPath: childLink.path,
                within: root
            )
        )
    }

    func testManagedURLRejectsSymlinkedManagedDirectory() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let realRoot = fixture.appendingPathComponent(
            "RealUserAssets",
            isDirectory: true
        )
        let linkedRoot = fixture.appendingPathComponent(
            "UserAssets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realRoot,
            withIntermediateDirectories: true
        )
        let realFile = realRoot.appendingPathComponent("icon.png")
        try Data("icon".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )

        XCTAssertNil(
            ManagedUserAssetStore.managedURL(
                forPath: linkedRoot.appendingPathComponent("icon.png").path,
                within: linkedRoot
            )
        )
    }

    func testImportRejectsSymlinkedManagedDirectory() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appendingPathComponent("selected.png")
        let realRoot = fixture.appendingPathComponent(
            "RealUserAssets",
            isDirectory: true
        )
        let linkedRoot = fixture.appendingPathComponent(
            "UserAssets",
            isDirectory: true
        )
        try Data("icon".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: realRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )

        XCTAssertThrowsError(
            try ManagedUserAssetStore.importAsset(
                from: source,
                slot: "test-icon",
                into: linkedRoot
            )
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: realRoot.path
            ).isEmpty
        )
    }

    func testImportRejectsSymlinkedIntermediateManagedDirectory() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appendingPathComponent("selected.png")
        let realParent = fixture.appendingPathComponent(
            "RealDocky",
            isDirectory: true
        )
        let linkedParent = fixture.appendingPathComponent(
            "Docky",
            isDirectory: true
        )
        let managed = linkedParent.appendingPathComponent(
            "UserAssets",
            isDirectory: true
        )
        try Data("icon".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: realParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: realParent
        )

        XCTAssertThrowsError(
            try ManagedUserAssetStore.importAsset(
                from: source,
                slot: "test-icon",
                into: managed
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedUserAssetError,
                .invalidManagedDirectory
            )
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: realParent.path
            ).isEmpty
        )
    }

    func testImportCopiesAssetAndDoesNotRetainExternalPath() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appendingPathComponent("selected.png")
        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        try Data("original".utf8).write(to: source)

        let imported = try ManagedUserAssetStore.importAsset(
            from: source,
            slot: "test-icon",
            into: managed
        )

        XCTAssertEqual(imported.deletingLastPathComponent(), managed)
        XCTAssertNotEqual(imported.path, source.path)
        XCTAssertEqual(try Data(contentsOf: imported), Data("original".utf8))

        try Data("changed".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: imported), Data("original".utf8))
    }

    func testPostPublicationSwapCannotChmodSymlinkTarget() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appendingPathComponent("selected.png")
        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let sentinel = fixture.appendingPathComponent("sentinel.txt")
        let displaced = fixture.appendingPathComponent("published-original")
        try Data("selected".utf8).write(to: source)
        try Data("sentinel".utf8).write(to: sentinel)
        XCTAssertEqual(Darwin.chmod(sentinel.path, 0o644), 0)
        let originalPermissions = try permissions(at: sentinel)

        let destination = try ManagedUserAssetStore.importAsset(
            from: source,
            slot: "adversarial-publication",
            into: managed,
            afterPublication: { published in
                try FileManager.default.moveItem(
                    at: published,
                    to: displaced
                )
                try FileManager.default.createSymbolicLink(
                    at: published,
                    withDestinationURL: sentinel
                )
            }
        )

        XCTAssertEqual(
            try permissions(at: sentinel),
            originalPermissions,
            "No path-based chmod may occur after the atomic publication."
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType,
            .typeSymbolicLink
        )
        XCTAssertEqual(
            try Data(contentsOf: displaced),
            Data("selected".utf8)
        )
    }

    func testReplacementInSameSlotGetsContentAddressedPath() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let firstSource = fixture.appendingPathComponent("first.png")
        let secondSource = fixture.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let first = try ManagedUserAssetStore.importAsset(
            from: firstSource,
            slot: "shared-slot",
            into: managed
        )
        let second = try ManagedUserAssetStore.importAsset(
            from: secondSource,
            slot: "shared-slot",
            into: managed
        )
        let firstAgain = try ManagedUserAssetStore.importAsset(
            from: firstSource,
            slot: "shared-slot",
            into: managed
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, firstAgain)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testManagedSourceIsRecopiedIntoTheRequestedSlot() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let source = fixture.appendingPathComponent("selected.png")
        try Data("selected".utf8).write(to: source)
        let first = try ManagedUserAssetStore.importAsset(
            from: source,
            slot: "slot-a",
            into: managed
        )
        let second = try ManagedUserAssetStore.importAsset(
            from: first,
            slot: "slot-b",
            into: managed
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            try Data(contentsOf: second),
            Data("selected".utf8)
        )
        XCTAssertEqual(
            try ManagedUserAssetStore.pruneUnreferencedAssets(
                forSlot: "slot-a",
                preservingPaths: [second.path],
                within: managed
            ),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            try ManagedUserAssetStore.pruneUnreferencedAssets(
                forSlot: "slot-b",
                preservingPaths: [],
                within: managed
            ),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testPruneRemovesOnlyUnreferencedVersionsForRequestedSlot() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let firstSource = fixture.appendingPathComponent("first.png")
        let secondSource = fixture.appendingPathComponent("second.png")
        let otherSource = fixture.appendingPathComponent("other.png")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        try Data("other".utf8).write(to: otherSource)

        let first = try ManagedUserAssetStore.importAsset(
            from: firstSource,
            slot: "shared-slot",
            into: managed
        )
        let second = try ManagedUserAssetStore.importAsset(
            from: secondSource,
            slot: "shared-slot",
            into: managed
        )
        let other = try ManagedUserAssetStore.importAsset(
            from: otherSource,
            slot: "other-slot",
            into: managed
        )

        XCTAssertEqual(
            try ManagedUserAssetStore.pruneUnreferencedAssets(
                forSlot: "shared-slot",
                preservingPaths: [second.path, other.path],
                within: managed
            ),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testPrunePreservesReferencedSharedPathAndNeverFollowsSymlink() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let source = fixture.appendingPathComponent("selected.png")
        let external = fixture.appendingPathComponent("external.png")
        try Data("selected".utf8).write(to: source)
        try Data("external".utf8).write(to: external)

        let imported = try ManagedUserAssetStore.importAsset(
            from: source,
            slot: "shared-slot",
            into: managed
        )
        let prefix = imported.lastPathComponent.split(
            separator: "-",
            maxSplits: 1
        )[0]
        let maliciousLink = managed.appendingPathComponent(
            "\(prefix)-malicious.png"
        )
        try FileManager.default.createSymbolicLink(
            at: maliciousLink,
            withDestinationURL: external
        )

        XCTAssertEqual(
            try ManagedUserAssetStore.pruneUnreferencedAssets(
                forSlot: "shared-slot",
                preservingPaths: [imported.path],
                within: managed
            ),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: maliciousLink.path
            ),
            external.path
        )
    }

    func testAbandonedImportRemovalHonorsCurrentReferences() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let source = fixture.appendingPathComponent("selected.png")
        try Data("selected".utf8).write(to: source)
        let imported = try ManagedUserAssetStore.importAsset(
            from: source,
            slot: "shared-slot",
            into: managed
        )

        XCTAssertFalse(
            ManagedUserAssetStore.removeUnreferencedAsset(
                atPath: imported.path,
                preservingPaths: [imported.path],
                within: managed
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertTrue(
            ManagedUserAssetStore.removeUnreferencedAsset(
                atPath: imported.path,
                preservingPaths: [],
                within: managed
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
    }

    func testImportRejectsEmptyAndOversizeAssets() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let empty = fixture.appendingPathComponent("empty.png")
        let oversize = fixture.appendingPathComponent("oversize.png")
        try Data().write(to: empty)
        try Data(repeating: 0x41, count: 9).write(to: oversize)

        XCTAssertThrowsError(
            try ManagedUserAssetStore.importAsset(
                from: empty,
                slot: "empty",
                into: managed,
                maximumBytes: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedUserAssetError,
                .emptyAsset
            )
        }
        XCTAssertThrowsError(
            try ManagedUserAssetStore.importAsset(
                from: oversize,
                slot: "oversize",
                into: managed,
                maximumBytes: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedUserAssetError,
                .assetTooLarge(maximumBytes: 8)
            )
        }
    }

    func testImportRejectsSymlinksFIFOsDirectoriesAndDevices() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let regular = fixture.appendingPathComponent("regular.png")
        let symlink = fixture.appendingPathComponent("symlink.png")
        let fifo = fixture.appendingPathComponent("named-pipe.png")
        let directory = fixture.appendingPathComponent(
            "directory.png",
            isDirectory: true
        )
        try Data("selected".utf8).write(to: regular)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: regular
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            fifo.path.withCString { Darwin.mkfifo($0, 0o600) },
            0
        )

        for source in [
            symlink,
            fifo,
            directory,
            URL(fileURLWithPath: "/dev/null"),
        ] {
            XCTAssertThrowsError(
                try ManagedUserAssetStore.importAsset(
                    from: source,
                    slot: "unsafe-\(UUID().uuidString)",
                    into: managed
                ),
                "Expected to reject \(source.path)"
            ) { error in
                XCTAssertEqual(
                    error as? ManagedUserAssetError,
                    .invalidSourceAsset
                )
            }
        }
    }

    func testOffMainImportReturnsSendableSuccessAndFailureResults() async throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appendingPathComponent("selected.png")
        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        try Data("selected".utf8).write(to: source)

        let success = await ManagedUserAssetStore.importAssetOffMain(
            from: source,
            slot: "async-test",
            into: managed
        )
        XCTAssertTrue(success.succeeded)
        XCTAssertNotNil(success.destinationPath)
        XCTAssertNil(success.errorDomain)
        XCTAssertNil(success.errorCode)

        let missing = await ManagedUserAssetStore.importAssetOffMain(
            from: fixture.appendingPathComponent("missing.png"),
            slot: "async-missing",
            into: managed
        )
        XCTAssertFalse(missing.succeeded)
        XCTAssertNil(missing.destinationPath)
        XCTAssertNotNil(missing.errorDomain)
        XCTAssertNotNil(missing.errorCode)
    }

    func testPendingOffMainImportIsProtectedUntilResolved() async throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appendingPathComponent("selected.png")
        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        try Data("selected".utf8).write(to: source)

        let result = await ManagedUserAssetStore.importAssetOffMain(
            from: source,
            slot: "pending-test",
            into: managed
        )
        let importedPath = try XCTUnwrap(result.destinationPath)

        let removedWhilePending =
            await ManagedUserAssetStore.pruneUnreferencedAssetsOffMain(
                forSlot: "pending-test",
                preservingPaths: [],
                within: managed
            )
        XCTAssertEqual(
            removedWhilePending,
            0
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: importedPath)
        )

        let removedAfterResolution =
            await ManagedUserAssetStore.resolvePendingImportOffMain(
                atPath: importedPath,
                forSlot: "pending-test",
                preservingPaths: [],
                within: managed
            )
        XCTAssertEqual(
            removedAfterResolution,
            1
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: importedPath)
        )
    }

    func testInstallAndPendingRegistrationHaveNoCancellationGap() throws {
        let source = try sourceFile(
            "Docky/Models/ManagedUserAssetStore.swift"
        )
        let install = try XCTUnwrap(
            source.range(of: "let destination = try install(")
        )
        let registration = try XCTUnwrap(
            source.range(
                of: "coordinator.registerPending(",
                range: install.upperBound..<source.endIndex
            )
        )
        let between = source[install.upperBound..<registration.lowerBound]

        XCTAssertFalse(
            between.contains("cancellation.check()"),
            "Installed assets must be leased before cancellation can escape."
        )
    }

    func testReverseCleanupCompletionUsesNewestReferenceSnapshot() async throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let managed = fixture.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        let firstSource = fixture.appendingPathComponent("first.png")
        let secondSource = fixture.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let slot = "reverse-cleanup-\(UUID().uuidString)"

        let firstResult =
            await ManagedUserAssetStore.importAssetOffMain(
                from: firstSource,
                slot: slot,
                into: managed
            )
        let secondResult =
            await ManagedUserAssetStore.importAssetOffMain(
                from: secondSource,
                slot: slot,
                into: managed
            )
        let firstPath = try XCTUnwrap(firstResult.destinationPath)
        let secondPath = try XCTUnwrap(secondResult.destinationPath)

        ManagedUserAssetStore.announceCleanupPlan(
            forSlot: slot,
            revision: 1,
            preservingPaths: [firstPath]
        )
        ManagedUserAssetStore.announceCleanupPlan(
            forSlot: slot,
            revision: 2,
            preservingPaths: [secondPath]
        )

        _ = await ManagedUserAssetStore.resolvePendingImportOffMain(
            atPath: secondPath,
            forSlot: slot,
            preservingPaths: [secondPath],
            cleanupRevision: 2,
            within: managed
        )
        _ = await ManagedUserAssetStore.resolvePendingImportOffMain(
            atPath: firstPath,
            forSlot: slot,
            preservingPaths: [firstPath],
            cleanupRevision: 1,
            within: managed
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath))
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DockyManagedAssetTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
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

    private func permissions(at url: URL) throws -> mode_t {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        return metadata.st_mode & mode_t(0o777)
    }
}
