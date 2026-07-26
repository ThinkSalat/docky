import Foundation
import XCTest

final class AtomicJSONFileStoreTests: XCTestCase {
    private enum FixtureError: Error {
        case unsupportedVersion
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
        try Data("not-json".utf8).write(to: store.primaryURL, options: .atomic)

        let recovered = try XCTUnwrap(try store.load(validate: validate))
        XCTAssertEqual(recovered.source, .backup)
        XCTAssertTrue(recovered.recoveredPrimary)
        XCTAssertEqual(recovered.value, first)

        let repaired = try XCTUnwrap(try store.load(validate: validate))
        XCTAssertEqual(repaired.source, .primary)
        XCTAssertEqual(repaired.value, first)
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

    private func makeStore(
        in directory: URL
    ) -> AtomicJSONFileStore<Fixture> {
        AtomicJSONFileStore(
            primaryURL: directory.appendingPathComponent("profiles.json"),
            backupURL: directory.appendingPathComponent("profiles.backup.json")
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
