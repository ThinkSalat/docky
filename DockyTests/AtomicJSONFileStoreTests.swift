import Foundation
import XCTest

final class AtomicJSONFileStoreTests: XCTestCase {
    private enum FixtureError: Error {
        case unsupportedVersion
        case durabilityFailure
    }

    private struct Fixture: Codable, Equatable {
        var version: Int
        var value: String

        init(version: Int, value: String) {
            self.version = version
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else {
                // Matches the production document's decode-schema-first
                // behavior: an older reader rejects a newer payload before
                // it can consider replacing it with an older backup.
                throw FixtureError.unsupportedVersion
            }
            value = try container.decode(String.self, forKey: .value)
        }
    }

    private struct VersionedFixture: Codable, Equatable {
        let version: Int
        let value: String
    }

    func testExplicitMigrationCanReplaceValidatedOlderSchema() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let primary = directory.appendingPathComponent("primary.json")
        let backup = directory.appendingPathComponent("backup.json")
        let store = AtomicJSONFileStore<VersionedFixture>(
            primaryURL: primary,
            backupURL: backup
        )
        let legacy = VersionedFixture(
            version: 1,
            value: "preserved"
        )
        let migrated = VersionedFixture(
            version: 2,
            value: "preserved"
        )
        try store.save(legacy) { value in
            guard value.version == 1 else {
                throw FixtureError.unsupportedVersion
            }
        }

        try store.save(
            migrated,
            validate: { value in
                guard value.version == 2 else {
                    throw FixtureError.unsupportedVersion
                }
            },
            validateExisting: { value in
                guard (1...2).contains(value.version) else {
                    throw FixtureError.unsupportedVersion
                }
            }
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                VersionedFixture.self,
                from: Data(contentsOf: primary)
            ),
            migrated
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VersionedFixture.self,
                from: Data(contentsOf: backup)
            ),
            legacy
        )
    }

    func testMigrationArchivesBothDurableGenerationsImmutably() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AtomicJSONFileStore<VersionedFixture>(
            primaryURL: directory.appendingPathComponent("primary.json"),
            backupURL: directory.appendingPathComponent("backup.json")
        )
        let legacyBackup = VersionedFixture(
            version: 1,
            value: "legacy-backup"
        )
        let legacyPrimary = VersionedFixture(
            version: 1,
            value: "legacy-primary"
        )
        let migrated = VersionedFixture(
            version: 2,
            value: "migrated"
        )
        try store.save(legacyBackup) { value in
            guard value.version == 1 else {
                throw FixtureError.unsupportedVersion
            }
        }
        try store.save(
            legacyPrimary,
            validate: { value in
                guard value.version == 1 else {
                    throw FixtureError.unsupportedVersion
                }
            },
            expectedPrimary: .value(legacyBackup)
        )

        try store.save(
            migrated,
            validate: { value in
                guard value.version == 2 else {
                    throw FixtureError.unsupportedVersion
                }
            },
            validateExisting: { value in
                guard (1...2).contains(value.version) else {
                    throw FixtureError.unsupportedVersion
                }
            },
            expectedPrimary: .value(legacyPrimary),
            archiveExistingGenerations: true
        )

        let archiveURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains(
                ".atomic-json.migration-archive."
            )
        }
        XCTAssertEqual(archiveURLs.count, 2)
        let primaryArchive = try XCTUnwrap(
            archiveURLs.first {
                $0.lastPathComponent.contains(".primary.")
            }
        )
        let backupArchive = try XCTUnwrap(
            archiveURLs.first {
                $0.lastPathComponent.contains(".backup.")
            }
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VersionedFixture.self,
                from: Data(contentsOf: primaryArchive)
            ),
            legacyPrimary
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VersionedFixture.self,
                from: Data(contentsOf: backupArchive)
            ),
            legacyBackup
        )
        let archivedBytes = try Dictionary(
            uniqueKeysWithValues: archiveURLs.map {
                ($0, try Data(contentsOf: $0))
            }
        )

        let later = VersionedFixture(version: 2, value: "later")
        try store.save(
            later,
            validate: { value in
                guard value.version == 2 else {
                    throw FixtureError.unsupportedVersion
                }
            },
            expectedPrimary: .value(migrated)
        )
        for (url, bytes) in archivedBytes {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testStaleWriterCannotOverwriteNewerPrimaryOrRotateBackups() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = makeStore(in: directory)
        let secondStore = makeStore(in: directory)
        let original = Fixture(version: 1, value: "original")
        let newer = Fixture(version: 1, value: "newer")
        let staleReplacement = Fixture(
            version: 1,
            value: "stale-replacement"
        )
        try firstStore.save(original, validate: validate)
        let firstLoad = try XCTUnwrap(
            try firstStore.load(validate: validate)
        )
        let secondLoad = try XCTUnwrap(
            try secondStore.load(validate: validate)
        )

        try secondStore.save(
            newer,
            validate: validate,
            expectedPrimary: .value(secondLoad.value)
        )
        let primaryBeforeStaleWrite = try Data(
            contentsOf: firstStore.primaryURL
        )
        let backupBeforeStaleWrite = try Data(
            contentsOf: firstStore.backupURL
        )

        XCTAssertThrowsError(
            try firstStore.save(
                staleReplacement,
                validate: validate,
                expectedPrimary: .value(firstLoad.value)
            )
        ) { error in
            guard case AtomicJSONFileStore<Fixture>.StoreError
                .primaryChangedSinceLoad = error else {
                return XCTFail(
                    "Expected primaryChangedSinceLoad, got \(error)"
                )
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: firstStore.primaryURL),
            primaryBeforeStaleWrite
        )
        XCTAssertEqual(
            try Data(contentsOf: firstStore.backupURL),
            backupBeforeStaleWrite
        )
    }

    func testFailedPrimaryPublishRetainsTwoDurablePredecessors() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writableStore = makeStore(in: directory)
        let oldest = Fixture(version: 1, value: "oldest")
        let current = Fixture(version: 1, value: "current")
        let replacement = Fixture(version: 1, value: "replacement")
        try writableStore.save(oldest, validate: validate)
        try writableStore.save(
            current,
            validate: validate,
            expectedPrimary: .value(oldest)
        )

        let failingStore = makeStore(
            in: directory,
            synchronizeFileBeforeRename: { temporaryURL in
                if temporaryURL.lastPathComponent.hasPrefix(
                    ".profiles.json."
                ) {
                    throw FixtureError.durabilityFailure
                }
            }
        )
        XCTAssertThrowsError(
            try failingStore.save(
                replacement,
                validate: validate,
                expectedPrimary: .value(current)
            )
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                Fixture.self,
                from: Data(contentsOf: failingStore.primaryURL)
            ),
            current
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                Fixture.self,
                from: Data(contentsOf: failingStore.backupURL)
            ),
            current
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                Fixture.self,
                from: Data(contentsOf: failingStore.previousBackupURL)
            ),
            oldest
        )
    }

    func testDirectoryTransactionLockSerializesIndependentDescriptors()
        throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstDirectory = try SecureOwnedDirectory.openOrCreate(
            at: directory
        )
        let secondDirectory = try SecureOwnedDirectory.openOrCreate(
            at: directory
        )
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAttempting = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let bothFinished = DispatchGroup()
        let queue = DispatchQueue(
            label: "com.docky.tests.atomic-json-lock",
            attributes: .concurrent
        )

        bothFinished.enter()
        queue.async {
            defer { bothFinished.leave() }
            do {
                try firstDirectory.withExclusiveLock {
                    firstEntered.signal()
                    _ = releaseFirst.wait(timeout: .now() + 2)
                }
            } catch {
                XCTFail("First lock failed: \(error)")
            }
        }
        XCTAssertEqual(
            firstEntered.wait(timeout: .now() + 2),
            .success
        )

        bothFinished.enter()
        queue.async {
            defer { bothFinished.leave() }
            secondAttempting.signal()
            do {
                try secondDirectory.withExclusiveLock {
                    _ = secondEntered.signal()
                }
            } catch {
                XCTFail("Second lock failed: \(error)")
            }
        }
        XCTAssertEqual(
            secondAttempting.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 0.1),
            .timedOut
        )

        releaseFirst.signal()
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(
            bothFinished.wait(timeout: .now() + 2),
            .success
        )
    }

    func testSecondSaveKeepsPreviousCompleteDocumentAsBackup() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let first = Fixture(version: 1, value: "first")
        let second = Fixture(version: 1, value: "second")

        try store.save(first, validate: validate)
        try store.save(second, validate: validate)

        let loaded = try XCTUnwrap(try store.load(validate: validate))
        XCTAssertEqual(loaded.source, .primary)
        XCTAssertEqual(loaded.value, second)

        let backupData = try Data(contentsOf: store.backupURL)
        XCTAssertEqual(try JSONDecoder().decode(Fixture.self, from: backupData), first)
    }

    func testFirstSaveSeedsCompleteRecoveryCopy() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Use the production hooks here so the real Darwin open/full-sync/
        // fsync path is exercised on the host test filesystem.
        let store = makeStore(in: directory)
        let fixture = Fixture(version: 1, value: "first")

        try store.save(fixture, validate: validate)

        let primary = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: store.primaryURL)
        )
        let backup = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: store.backupURL)
        )
        XCTAssertEqual(primary, fixture)
        XCTAssertEqual(backup, fixture)
    }

    func testCorruptPrimaryRecoversBackupAndRepairsPrimaryAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let first = Fixture(version: 1, value: "recoverable")
        let second = Fixture(version: 1, value: "newer")

        try store.save(first, validate: validate)
        try store.save(second, validate: validate)
        let corruptPrimary = Data("not-json".utf8)
        try corruptPrimary.write(to: store.primaryURL, options: .atomic)

        let recovered = try XCTUnwrap(try store.load(validate: validate))
        XCTAssertEqual(recovered.source, .backup)
        XCTAssertTrue(recovered.recoveredPrimary)
        XCTAssertEqual(recovered.value, first)
        let quarantineURL = try XCTUnwrap(
            recovered.quarantinedPrimaryURL
        )
        XCTAssertEqual(
            try Data(contentsOf: quarantineURL),
            corruptPrimary
        )

        let repaired = try XCTUnwrap(try store.load(validate: validate))
        XCTAssertEqual(repaired.source, .primary)
        XCTAssertEqual(repaired.value, first)

        try store.save(
            Fixture(version: 1, value: "after-recovery"),
            validate: validate,
            expectedPrimary: .value(first)
        )
        XCTAssertEqual(
            try Data(contentsOf: quarantineURL),
            corruptPrimary
        )
    }

    func testPrimaryReadFailureNeverConsultsBackupOrRepairsPrimary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writableStore = makeStore(in: directory)
        try writableStore.save(
            Fixture(version: 1, value: "backup"),
            validate: validate
        )
        try writableStore.save(
            Fixture(version: 1, value: "newer-primary"),
            validate: validate
        )
        let originalPrimary = try Data(contentsOf: writableStore.primaryURL)

        var readURLs: [URL] = []
        let unreadableStore = makeStore(
            in: directory,
            readData: { url in
                readURLs.append(url)
                if url == writableStore.primaryURL {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EACCES)
                    )
                }
                return try Data(contentsOf: url)
            }
        )
        var recoveryDecisionRequested = false

        XCTAssertThrowsError(
            try unreadableStore.load(
                validate: validate,
                canRecoverPrimaryFailure: { _ in
                    recoveryDecisionRequested = true
                    return true
                }
            )
        ) { error in
            guard case AtomicJSONFileStore<Fixture>.StoreError.primaryReadFailed = error else {
                return XCTFail("Expected primaryReadFailed, got \(error)")
            }
        }

        XCTAssertFalse(recoveryDecisionRequested)
        XCTAssertEqual(readURLs, [writableStore.primaryURL])
        XCTAssertEqual(
            try Data(contentsOf: writableStore.primaryURL),
            originalPrimary
        )
    }

    func testUnknownPrimaryPresenceNeverConsultsBackup() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let primaryURL = directory.appendingPathComponent("profiles.json")
        let backupURL = directory.appendingPathComponent(
            "profiles.backup.json"
        )
        var readURLs: [URL] = []
        let store = AtomicJSONFileStore<Fixture>(
            primaryURL: primaryURL,
            backupURL: backupURL,
            readData: { url in
                readURLs.append(url)
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOENT)
                )
            },
            pathEntryExists: { url in
                XCTAssertEqual(url, primaryURL)
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EACCES)
                )
            },
            synchronizeFileBeforeRename: { _ in },
            synchronizeDirectoryAfterRename: { _ in }
        )

        XCTAssertThrowsError(try store.load(validate: validate)) { error in
            guard case AtomicJSONFileStore<Fixture>.StoreError.primaryReadFailed =
                error else {
                return XCTFail("Expected primaryReadFailed, got \(error)")
            }
        }
        XCTAssertEqual(readURLs, [primaryURL])
    }

    func testDanglingPrimarySymlinkIsNotTreatedAsMissing() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        try FileManager.default.createSymbolicLink(
            at: store.primaryURL,
            withDestinationURL:
                directory.appendingPathComponent("missing-target.json")
        )
        try JSONEncoder().encode(
            Fixture(version: 1, value: "backup")
        ).write(to: store.backupURL)

        XCTAssertThrowsError(try store.load(validate: validate)) { error in
            guard case AtomicJSONFileStore<Fixture>.StoreError.primaryReadFailed =
                error else {
                return XCTFail("Expected primaryReadFailed, got \(error)")
            }
        }
        XCTAssertTrue(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: store.primaryURL.path
            ).contains("missing-target.json")
        )
    }

    func testSaveReadFailureNeverRotatesBackupOrOverwritesPrimary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writableStore = makeStore(in: directory)
        try writableStore.save(
            Fixture(version: 1, value: "backup"),
            validate: validate
        )
        try writableStore.save(
            Fixture(version: 1, value: "current"),
            validate: validate
        )
        let originalPrimary = try Data(contentsOf: writableStore.primaryURL)
        let originalBackup = try Data(contentsOf: writableStore.backupURL)

        let unreadableStore = makeStore(
            in: directory,
            readData: { url in
                if url == writableStore.primaryURL {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EIO)
                    )
                }
                return try Data(contentsOf: url)
            }
        )

        XCTAssertThrowsError(
            try unreadableStore.save(
                Fixture(version: 1, value: "replacement"),
                validate: validate
            )
        ) { error in
            guard case AtomicJSONFileStore<Fixture>.StoreError.primaryReadFailed = error else {
                return XCTFail("Expected primaryReadFailed, got \(error)")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: writableStore.primaryURL),
            originalPrimary
        )
        XCTAssertEqual(
            try Data(contentsOf: writableStore.backupURL),
            originalBackup
        )
    }

    func testForwardIncompatiblePrimaryIsNeverReplacedByOlderBackup() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        try store.save(Fixture(version: 1, value: "old"), validate: validate)
        try store.save(Fixture(version: 1, value: "current"), validate: validate)

        let futureData = try JSONEncoder().encode(Fixture(version: 2, value: "future"))
        try futureData.write(to: store.primaryURL, options: .atomic)

        XCTAssertThrowsError(
            try store.load(
                validate: validate,
                canRecoverPrimaryFailure: { !($0 is FixtureError) }
            )
        )
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), futureData)
    }

    func testValidBackupRemainsAvailableWhenPrimaryRepairFails() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writableStore = makeStore(in: directory)
        let backup = Fixture(version: 1, value: "recoverable")
        try writableStore.save(backup, validate: validate)
        try writableStore.save(
            Fixture(version: 1, value: "newer"),
            validate: validate
        )
        let corruptPrimary = Data("not-json".utf8)
        try corruptPrimary.write(to: writableStore.primaryURL)

        let repairBlockedStore = AtomicJSONFileStore<Fixture>(
            primaryURL: writableStore.primaryURL,
            backupURL: writableStore.backupURL,
            synchronizeFileBeforeRename: { _ in
                throw FixtureError.durabilityFailure
            },
            synchronizeDirectoryAfterRename: { _ in }
        )

        let loaded = try XCTUnwrap(
            try repairBlockedStore.load(validate: validate)
        )
        XCTAssertEqual(loaded.source, .backup)
        XCTAssertEqual(loaded.value, backup)
        XCTAssertFalse(loaded.recoveredPrimary)
        XCTAssertNotNil(loaded.primaryRepairFailureDescription)
        XCTAssertEqual(
            try Data(contentsOf: writableStore.primaryURL),
            corruptPrimary
        )
    }

    func testSaveRefusesToOverwriteInvalidExistingPrimary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        try store.save(Fixture(version: 1, value: "recoverable"), validate: validate)
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: store.primaryURL, options: .atomic)

        XCTAssertThrowsError(
            try store.save(Fixture(version: 1, value: "replacement"), validate: validate)
        )
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), corruptData)
    }

    func testMissingPrimaryMustRecoverBackupBeforeAcceptingSave() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let first = Fixture(version: 1, value: "recoverable")
        let second = Fixture(version: 1, value: "after-recovery")
        try store.save(first, validate: validate)
        try FileManager.default.removeItem(at: store.primaryURL)

        XCTAssertThrowsError(try store.save(second, validate: validate))

        let recovered = try XCTUnwrap(try store.load(validate: validate))
        XCTAssertEqual(recovered.source, .backup)
        XCTAssertEqual(recovered.value, first)

        try store.save(second, validate: validate)
        XCTAssertEqual(
            try XCTUnwrap(try store.load(validate: validate)).value,
            second
        )
    }

    func testPreRenameSyncFailureDoesNotPublishDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(
            in: directory,
            synchronizeFileBeforeRename: { temporaryURL in
                XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
                throw FixtureError.durabilityFailure
            }
        )

        XCTAssertThrowsError(
            try store.save(
                Fixture(version: 1, value: "not-published"),
                validate: validate
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testPostRenameDirectorySyncFailureDoesNotReportSaveFailure() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var directorySyncCount = 0
        let store = makeStore(
            in: directory,
            synchronizeDirectoryAfterRename: { synchronizedDirectory in
                XCTAssertEqual(synchronizedDirectory, directory)
                directorySyncCount += 1
                throw FixtureError.durabilityFailure
            }
        )
        let fixture = Fixture(version: 1, value: "committed")

        XCTAssertNoThrow(try store.save(fixture, validate: validate))
        XCTAssertEqual(directorySyncCount, 2)
        XCTAssertEqual(
            try XCTUnwrap(try store.load(validate: validate)).value,
            fixture
        )
    }

    func testSymlinkedProfilesParentIsRejectedWithoutTouchingTarget() throws {
        let fixture = temporaryDirectory()
        let linkedProfiles = fixture.appendingPathComponent(
            "Profiles",
            isDirectory: true
        )
        let targetProfiles = fixture.appendingPathComponent(
            "OutsideProfiles",
            isDirectory: true
        )
        let sentinel = targetProfiles.appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(
            at: targetProfiles,
            withIntermediateDirectories: true
        )
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: linkedProfiles,
            withDestinationURL: targetProfiles
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let store = makeStore(in: linkedProfiles)
        XCTAssertThrowsError(
            try store.save(
                Fixture(version: 1, value: "must-not-escape"),
                validate: validate
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("untouched".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: targetProfiles,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            ["sentinel.txt"]
        )
    }

    func testRetainedDirectoryDescriptorIgnoresLaterPathReplacement() throws {
        let fixture = temporaryDirectory()
        let profiles = fixture.appendingPathComponent(
            "Profiles",
            isDirectory: true
        )
        let retainedProfiles = fixture.appendingPathComponent(
            "RetainedProfiles",
            isDirectory: true
        )
        let attackerDirectory = fixture.appendingPathComponent(
            "Attacker",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let store = makeStore(in: profiles)
        try FileManager.default.moveItem(
            at: profiles,
            to: retainedProfiles
        )
        try FileManager.default.createDirectory(
            at: attackerDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: profiles,
            withDestinationURL: attackerDirectory
        )

        let value = Fixture(version: 1, value: "descriptor-owned")
        try store.save(value, validate: validate)

        XCTAssertEqual(
            try XCTUnwrap(try store.load(validate: validate)).value,
            value
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: attackerDirectory,
                includingPropertiesForKeys: nil
            ),
            []
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retainedProfiles
                    .appendingPathComponent("profiles.json").path
            )
        )
    }

    func testOversizedPrimaryIsAReadFailureAndNeverLoadsBackup() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AtomicJSONFileStore<Fixture>(
            primaryURL: directory.appendingPathComponent("profiles.json"),
            backupURL: directory.appendingPathComponent(
                "profiles.backup.json"
            ),
            maximumDocumentBytes: 32
        )
        let oversizedPrimary = Data(repeating: 0x41, count: 33)
        try oversizedPrimary.write(to: store.primaryURL)
        try JSONEncoder().encode(
            Fixture(version: 1, value: "backup")
        ).write(to: store.backupURL)

        XCTAssertThrowsError(try store.load(validate: validate)) { error in
            guard case AtomicJSONFileStore<Fixture>.StoreError
                .primaryReadFailed = error else {
                return XCTFail("Expected primaryReadFailed, got \(error)")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: store.primaryURL),
            oversizedPrimary
        )
    }

    func testDiagnosticsAppendRejectsCurrentLogSymlinkSentinel() throws {
        let fixture = temporaryDirectory()
        let diagnostics = fixture.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
        let sentinel = fixture.appendingPathComponent("sentinel.jsonl")
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: true
        )
        try Data("sentinel".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let logStore = SecureBoundedLogStore(
            directoryURL: diagnostics,
            currentName: "docky-events.jsonl",
            previousName: "docky-events.previous.jsonl",
            maximumFileBytes: 64
        )
        let current = diagnostics.appendingPathComponent(
            "docky-events.jsonl"
        )
        try FileManager.default.createSymbolicLink(
            at: current,
            withDestinationURL: sentinel
        )

        XCTAssertThrowsError(try logStore.append(Data("event\n".utf8)))
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("sentinel".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: current.path
            ),
            sentinel.path
        )
    }

    func testDiagnosticsRotationRejectsPreviousLogSymlinkSentinel() throws {
        let fixture = temporaryDirectory()
        let diagnostics = fixture.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
        let sentinel = fixture.appendingPathComponent("sentinel.jsonl")
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: true
        )
        try Data("sentinel".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let logStore = SecureBoundedLogStore(
            directoryURL: diagnostics,
            currentName: "docky-events.jsonl",
            previousName: "docky-events.previous.jsonl",
            maximumFileBytes: 16
        )
        let firstGeneration = Data("first-event\n".utf8)
        try logStore.append(firstGeneration)
        let previous = diagnostics.appendingPathComponent(
            "docky-events.previous.jsonl"
        )
        try FileManager.default.createSymbolicLink(
            at: previous,
            withDestinationURL: sentinel
        )

        XCTAssertThrowsError(
            try logStore.append(Data("second-event\n".utf8))
        )
        XCTAssertEqual(
            try Data(
                contentsOf: diagnostics.appendingPathComponent(
                    "docky-events.jsonl"
                )
            ),
            firstGeneration
        )
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("sentinel".utf8)
        )
    }

    func testDiagnosticsAppendRejectsHardLinkedSentinel() throws {
        let fixture = temporaryDirectory()
        let diagnostics = fixture.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
        let sentinel = fixture.appendingPathComponent("sentinel.jsonl")
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: true
        )
        try Data("sentinel".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let logStore = SecureBoundedLogStore(
            directoryURL: diagnostics,
            currentName: "docky-events.jsonl",
            previousName: "docky-events.previous.jsonl",
            maximumFileBytes: 64
        )
        let current = diagnostics.appendingPathComponent(
            "docky-events.jsonl"
        )
        try FileManager.default.linkItem(at: sentinel, to: current)

        XCTAssertThrowsError(try logStore.append(Data("event\n".utf8)))
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("sentinel".utf8)
        )
    }

    func testDiagnosticsRotationKeepsBothGenerationsWithinSizeCap() throws {
        let fixture = temporaryDirectory()
        let diagnostics = fixture.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let logStore = SecureBoundedLogStore(
            directoryURL: diagnostics,
            currentName: "docky-events.jsonl",
            previousName: "docky-events.previous.jsonl",
            maximumFileBytes: 16
        )
        let firstGeneration = Data("first-1234".utf8)
        let secondGeneration = Data("second-123".utf8)
        try logStore.append(firstGeneration)
        try logStore.append(secondGeneration)

        let previous = try Data(
            contentsOf: diagnostics.appendingPathComponent(
                "docky-events.previous.jsonl"
            )
        )
        let current = try Data(
            contentsOf: diagnostics.appendingPathComponent(
                "docky-events.jsonl"
            )
        )
        XCTAssertEqual(previous, firstGeneration)
        XCTAssertEqual(current, secondGeneration)
        XCTAssertLessThanOrEqual(previous.count, 16)
        XCTAssertLessThanOrEqual(current.count, 16)
        XCTAssertThrowsError(
            try logStore.append(Data(repeating: 0x41, count: 17))
        )
    }

    private func makeStore(
        in directory: URL
    ) -> AtomicJSONFileStore<Fixture> {
        AtomicJSONFileStore(
            primaryURL: directory.appendingPathComponent("profiles.json"),
            backupURL: directory.appendingPathComponent("profiles.backup.json")
        )
    }

    private func makeStore(
        in directory: URL,
        readData: @escaping (URL) throws -> Data
    ) -> AtomicJSONFileStore<Fixture> {
        AtomicJSONFileStore(
            primaryURL: directory.appendingPathComponent("profiles.json"),
            backupURL: directory.appendingPathComponent("profiles.backup.json"),
            readData: readData,
            synchronizeFileBeforeRename: { _ in },
            synchronizeDirectoryAfterRename: { _ in }
        )
    }

    private func makeStore(
        in directory: URL,
        synchronizeFileBeforeRename: @escaping (URL) throws -> Void
    ) -> AtomicJSONFileStore<Fixture> {
        AtomicJSONFileStore(
            primaryURL: directory.appendingPathComponent("profiles.json"),
            backupURL: directory.appendingPathComponent("profiles.backup.json"),
            synchronizeFileBeforeRename: synchronizeFileBeforeRename,
            synchronizeDirectoryAfterRename: { _ in }
        )
    }

    private func makeStore(
        in directory: URL,
        synchronizeDirectoryAfterRename: @escaping (URL) throws -> Void
    ) -> AtomicJSONFileStore<Fixture> {
        AtomicJSONFileStore(
            primaryURL: directory.appendingPathComponent("profiles.json"),
            backupURL: directory.appendingPathComponent("profiles.backup.json"),
            synchronizeFileBeforeRename: { _ in },
            synchronizeDirectoryAfterRename: synchronizeDirectoryAfterRename
        )
    }

    private func validate(_ fixture: Fixture) throws {
        guard fixture.version == 1 else {
            throw FixtureError.unsupportedVersion
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DockyTests-\(UUID().uuidString)", isDirectory: true)
    }
}
