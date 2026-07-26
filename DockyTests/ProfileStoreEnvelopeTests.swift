import Foundation
import XCTest

final class ProfileStoreEnvelopeTests: XCTestCase {
    private struct FixtureProfile: Codable, Equatable, Identifiable {
        let id: String
        let name: String
    }

    private typealias Document = ProfileStoreEnvelope<FixtureProfile>

    func testValidDocumentRoundTripsAndValidates() throws {
        let document = Document(
            revision: 7,
            activeProfileID: "work",
            profiles: [
                FixtureProfile(id: "default", name: "Default"),
                FixtureProfile(id: "work", name: "Work"),
            ]
        )

        let decoded = try JSONDecoder().decode(
            Document.self,
            from: JSONEncoder().encode(document)
        )

        XCTAssertEqual(decoded, document)
        XCTAssertNoThrow(try Document.validate(decoded))
    }

    func testFutureSchemaIsRejectedBeforeVersionSpecificPayload() throws {
        let data = try XCTUnwrap(
            """
            {
              "schemaVersion": 99,
              "revision": "not-a-number",
              "activeProfileID": false,
              "profiles": "future-payload"
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(Document.self, from: data)
        ) { error in
            XCTAssertEqual(
                error as? ProfileStoreValidationError,
                .unsupportedSchemaVersion(
                    found: 99,
                    supported: Document.currentSchemaVersion
                )
            )
            XCTAssertTrue(
                (error as? ProfileStoreValidationError)?
                    .isForwardIncompatible == true
            )
        }
    }

    func testValidationRejectsOlderSchemaWithoutMarkingItForwardIncompatible() {
        let document = Document(
            schemaVersion: 0,
            revision: 1,
            activeProfileID: "default",
            profiles: [FixtureProfile(id: "default", name: "Default")]
        )

        XCTAssertThrowsError(try Document.validate(document)) { error in
            guard let validationError = error as? ProfileStoreValidationError else {
                XCTFail("Expected ProfileStoreValidationError, got \(error)")
                return
            }
            XCTAssertEqual(
                validationError,
                .unsupportedSchemaVersion(
                    found: 0,
                    supported: Document.currentSchemaVersion
                )
            )
            XCTAssertFalse(validationError.isForwardIncompatible)
        }
    }

    func testValidationRejectsEveryBrokenIdentityInvariant() {
        assertValidationError(
            in: Document(
                revision: 0,
                activeProfileID: "default",
                profiles: [FixtureProfile(id: "default", name: "Default")]
            ),
            equals: .invalidRevision
        )
        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: "",
                profiles: []
            ),
            equals: .emptyProfiles
        )
        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: "",
                profiles: [FixtureProfile(id: "", name: "Broken")]
            ),
            equals: .emptyProfileID(index: 0)
        )
        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: "same",
                profiles: [
                    FixtureProfile(id: "same", name: "One"),
                    FixtureProfile(id: "same", name: "Two"),
                ]
            ),
            equals: .duplicateProfileID("same")
        )
        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: "missing",
                profiles: [FixtureProfile(id: "default", name: "Default")]
            ),
            equals: .activeProfileMissing("missing")
        )
    }

    func testValidationRejectsOversizedProfileCollections() {
        let profiles = (0...Document.maximumProfileCount).map {
            FixtureProfile(id: "profile-\($0)", name: "Profile")
        }
        let document = Document(
            revision: 1,
            activeProfileID: profiles[0].id,
            profiles: profiles
        )

        assertValidationError(
            in: document,
            equals: .limitExceeded(
                field: "profiles",
                maximum: Document.maximumProfileCount
            )
        )
    }

    func testValidationRejectsOversizedIdentifiers() {
        let oversizedID = String(
            repeating: "x",
            count: Document.maximumIdentifierBytes + 1
        )

        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: oversizedID,
                profiles: [
                    FixtureProfile(id: oversizedID, name: "Profile"),
                ]
            ),
            equals: .limitExceeded(
                field: "activeProfileIDBytes",
                maximum: Document.maximumIdentifierBytes
            )
        )

        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: "valid",
                profiles: [
                    FixtureProfile(id: "valid", name: "Profile"),
                    FixtureProfile(id: oversizedID, name: "Profile"),
                ]
            ),
            equals: .limitExceeded(
                field: "profileIDBytes",
                maximum: Document.maximumIdentifierBytes
            )
        )
    }

    func testLegacyMigrationKeepsValidStoredActiveProfile() throws {
        let profiles = [
            FixtureProfile(id: "default", name: "Default"),
            FixtureProfile(id: "work", name: "Work"),
        ]

        let selection = try LegacyProfileMigration.reconcileActiveProfile(
            profiles: profiles,
            storedActiveProfileID: "work"
        )

        XCTAssertEqual(
            selection,
            LegacyProfileActiveSelection(
                activeProfileID: "work",
                storedActiveWasValid: true
            )
        )
    }

    func testLegacyMigrationFallsBackDeterministicallyToFirstProfile() throws {
        let profiles = [
            FixtureProfile(id: "default", name: "Default"),
            FixtureProfile(id: "work", name: "Work"),
        ]

        for storedID in ["missing", nil] as [String?] {
            let selection = try LegacyProfileMigration
                .reconcileActiveProfile(
                    profiles: profiles,
                    storedActiveProfileID: storedID
                )
            XCTAssertEqual(selection.activeProfileID, "default")
            XCTAssertFalse(selection.storedActiveWasValid)
        }
    }

    func testLegacyMigrationRejectsEmptyProfileList() {
        XCTAssertThrowsError(
            try LegacyProfileMigration.reconcileActiveProfile(
                profiles: [FixtureProfile](),
                storedActiveProfileID: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileStoreValidationError,
                .emptyProfiles
            )
        }
    }

    func testReadOnlyBootstrapStillAppliesAuthoritativeProfile() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/ProfileService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "    func completeBootstrap()")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    @discardableResult\n    func setActiveProfile(",
                range: start.upperBound..<source.endIndex
            )
        )
        let bootstrap = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(bootstrap.contains("if let profile = activeProfile"))
        XCTAssertTrue(bootstrap.contains("preferences?.applyProfile(profile)"))
        XCTAssertFalse(
            bootstrap.contains(
                "if !persistenceIsBlocked, let profile = activeProfile"
            )
        )
        XCTAssertTrue(
            bootstrap.contains(
                "if !persistenceIsBlocked {\n" +
                "            persistLegacyCompatibilitySnapshot()"
            )
        )
    }

    func testProfileBackedEditsAvoidMainActorJSONCompatibilityWrites() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferencesSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/DockyPreferences.swift"
            ),
            encoding: .utf8
        )
        let serviceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/ProfileService.swift"
            ),
            encoding: .utf8
        )

        for legacyHelper in [
            "persistPinnedItems(",
            "persistWidgetPlacements(",
            "persistAppWidgetDisplays(",
            "persistTrailingItems(",
        ] {
            XCTAssertFalse(preferencesSource.contains(legacyHelper))
        }

        let methodStart = try XCTUnwrap(
            serviceSource.range(
                of: "    private func persistLegacyCompatibilitySnapshot(\n" +
                    "        document:"
            )
        )
        let handlerStart = try XCTUnwrap(
            serviceSource.range(
                of: "    private func handleLegacySnapshotEvent(",
                range: methodStart.upperBound..<serviceSource.endIndex
            )
        )
        let submitMethod = serviceSource[
            methodStart.lowerBound..<handlerStart.lowerBound
        ]
        XCTAssertTrue(
            submitMethod.contains("legacySnapshotCoordinator.submit(document)")
        )
        XCTAssertFalse(submitMethod.contains("encoder.encode"))
        XCTAssertFalse(submitMethod.contains("defaults.set"))

        XCTAssertTrue(
            serviceSource.contains(
                "private lazy var legacySnapshotCoordinator"
            )
        )
        XCTAssertTrue(
            serviceSource.contains(
                "persistenceCoordinator.flush()\n" +
                "        legacySnapshotCoordinator.flush()"
            )
        )
    }

    private func assertValidationError(
        in document: Document,
        equals expected: ProfileStoreValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try Document.validate(document),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ProfileStoreValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
