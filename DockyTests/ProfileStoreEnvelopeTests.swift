import Foundation
import XCTest

final class ProfileStoreEnvelopeTests: XCTestCase {
    private struct FixtureProfile: Codable, Equatable, Identifiable {
        let id: String
        let name: String
    }

    private struct ContentFixtureProfile:
        Codable,
        Equatable,
        Identifiable {
        let id: String
        let name: String
        let pinned: [String]
        let trailing: [String]
        let widgets: [String]
        let hidden: [String]
    }

    private struct RepairFixtureProfile:
        Codable,
        Equatable,
        Identifiable,
        ProfileStoreLegacyExactSpaceRepairable {
        let id: String
        let name: String
        let symbolName: String
        let dateCreated: Date
        let hidden: [String]
        var triggers: [ProfileTrigger]
    }

    private typealias Document = ProfileStoreEnvelope<FixtureProfile>
    private typealias ContentDocument =
        ProfileStoreEnvelope<ContentFixtureProfile>

    func testRepeatedManualActivationEmitsIntentWithoutDurableOrLayoutMutation() {
        let disposition =
            ManualActivationDispositionPolicy.resolve(
                runtimeAlreadyActive: true,
                durableAlreadySelected: true
            )

        XCTAssertTrue(disposition.shouldEmitIntentNotification)
        XCTAssertFalse(disposition.shouldPersistDefault)
        XCTAssertFalse(disposition.shouldApplyLayout)
        XCTAssertTrue(disposition.isVisuallyAndDurablyIdempotent)
    }

    func testManualActivationSideEffectsRemainIndependent() {
        XCTAssertEqual(
            ManualActivationDispositionPolicy.resolve(
                runtimeAlreadyActive: true,
                durableAlreadySelected: false
            ),
            ManualActivationDisposition(
                shouldEmitIntentNotification: true,
                shouldPersistDefault: true,
                shouldApplyLayout: false
            )
        )
        XCTAssertEqual(
            ManualActivationDispositionPolicy.resolve(
                runtimeAlreadyActive: false,
                durableAlreadySelected: true
            ),
            ManualActivationDisposition(
                shouldEmitIntentNotification: true,
                shouldPersistDefault: false,
                shouldApplyLayout: true
            )
        )
    }

    func testSchemaOneLoadsOnlyThroughMigrationBoundary() throws {
        let data = try XCTUnwrap(
            """
            {
              "schemaVersion": 1,
              "revision": 7,
              "activeProfileID": "default",
              "profiles": [
                {"id": "default", "name": "Default"}
              ]
            }
            """.data(using: .utf8)
        )
        let document = try JSONDecoder().decode(
            Document.self,
            from: data
        )

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.spaceAssignments, [])
        XCTAssertNoThrow(try Document.validateForLoad(document))
        XCTAssertThrowsError(try Document.validate(document))
    }

    func testSchemaTwoRequiresSpaceAssignmentsField() throws {
        let data = try XCTUnwrap(
            """
            {
              "schemaVersion": 2,
              "revision": 7,
              "activeProfileID": "default",
              "profiles": [
                {"id": "default", "name": "Default"}
              ]
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(Document.self, from: data)
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail(
                    "Expected missing spaceAssignments, got \(error)"
                )
            }
            XCTAssertEqual(key.stringValue, "spaceAssignments")
        }
    }

    func testSpaceAssignmentMustBeUniqueAndReferenceAProfile() {
        let profile = FixtureProfile(id: "default", name: "Default")
        let identity = MissionControlSpaceIdentity(
            displayUUID: "DISPLAY-A",
            spaceUUID: "SPACE-A"
        )!

        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: profile.id,
                profiles: [profile],
                spaceAssignments: [
                    SpaceProfileAssignment(
                        identity: identity,
                        profileID: profile.id
                    ),
                    SpaceProfileAssignment(
                        identity: identity,
                        profileID: profile.id
                    ),
                ]
            ),
            equals: .duplicateSpaceAssignment(
                identity.storageKey
            )
        )

        assertValidationError(
            in: Document(
                revision: 1,
                activeProfileID: profile.id,
                profiles: [profile],
                spaceAssignments: [
                    SpaceProfileAssignment(
                        identity: identity,
                        profileID: "missing"
                    ),
                ]
            ),
            equals: .spaceAssignmentProfileMissing("missing")
        )
    }

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

    func testSpaceMutationPreservesEveryProfileContentField() throws {
        let root = MissionControlSpaceIdentity(
            displayUUID: "shared",
            spaceUUID: ""
        )!
        let music = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "MUSIC"
        )!
        let profiles = [
            ContentFixtureProfile(
                id: "main",
                name: "Main",
                pinned: ["Safari", "Mail"],
                trailing: ["Downloads"],
                widgets: ["Weather"],
                hidden: ["Calendar"]
            ),
            ContentFixtureProfile(
                id: "music",
                name: "WhatsApp + Spotify",
                pinned: ["WhatsApp", "Spotify"],
                trailing: [],
                widgets: ["Now Playing"],
                hidden: []
            ),
        ]
        let original = ContentDocument(
            revision: 8,
            activeProfileID: "main",
            profiles: profiles,
            spaceAssignments: [
                SpaceProfileAssignment(
                    identity: root,
                    profileID: "main"
                ),
            ]
        )

        let assigned = try XCTUnwrap(
            ProfileStoreDocumentMutationPolicy.assigningSpace(
                music,
                to: "music",
                in: original
            )
        )
        XCTAssertEqual(assigned.profiles, profiles)
        XCTAssertEqual(assigned.activeProfileID, "main")
        XCTAssertEqual(assigned.revision, 8)
        XCTAssertEqual(
            assigned.spaceAssignments,
            original.spaceAssignments + [
                SpaceProfileAssignment(
                    identity: music,
                    profileID: "music"
                ),
            ]
        )

        let removed =
            ProfileStoreDocumentMutationPolicy
            .removingSpaceAssignment(
                music,
                from: "music",
                in: assigned
            )
        XCTAssertEqual(removed, original)
    }

    func testProfileDeletionPreservesEveryUnrelatedValue() throws {
        let main = ContentFixtureProfile(
            id: "main",
            name: "Main",
            pinned: ["Safari"],
            trailing: ["Downloads"],
            widgets: ["Weather"],
            hidden: ["Mail"]
        )
        let music = ContentFixtureProfile(
            id: "music",
            name: "WhatsApp + Spotify",
            pinned: ["WhatsApp", "Spotify"],
            trailing: [],
            widgets: ["Now Playing"],
            hidden: []
        )
        let third = ContentFixtureProfile(
            id: "third",
            name: "Work",
            pinned: ["Xcode"],
            trailing: ["Projects"],
            widgets: [],
            hidden: ["Messages"]
        )
        let root = MissionControlSpaceIdentity(
            displayUUID: "shared",
            spaceUUID: ""
        )!
        let musicSpace = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "MUSIC"
        )!
        let workSpace = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "WORK"
        )!
        let original = ContentDocument(
            revision: 12,
            activeProfileID: "music",
            profiles: [main, music, third],
            spaceAssignments: [
                SpaceProfileAssignment(
                    identity: root,
                    profileID: "main"
                ),
                SpaceProfileAssignment(
                    identity: musicSpace,
                    profileID: "music"
                ),
                SpaceProfileAssignment(
                    identity: workSpace,
                    profileID: "third"
                ),
            ]
        )

        let deleted = try XCTUnwrap(
            ProfileStoreDocumentMutationPolicy.deletingProfile(
                "music",
                from: original
            )
        )

        XCTAssertEqual(deleted.profiles, [main, third])
        XCTAssertEqual(deleted.activeProfileID, "main")
        XCTAssertEqual(deleted.revision, 12)
        XCTAssertEqual(
            deleted.spaceAssignments,
            [
                original.spaceAssignments[0],
                original.spaceAssignments[2],
            ]
        )
    }

    func testRuntimeDeletionFallbackUsesDurableDefaultNotArrayOrder()
        throws {
        let candidate = Document(
            revision: 13,
            activeProfileID: "main",
            profiles: [
                FixtureProfile(id: "gaming", name: "Gaming"),
                FixtureProfile(id: "main", name: "Main"),
            ]
        )

        XCTAssertEqual(
            ProfileStoreDocumentMutationPolicy
                .runtimeProfileIDAfterDeleting(
                    "whatsapp",
                    previousRuntimeProfileID: "whatsapp",
                    from: candidate
                ),
            "main"
        )
        XCTAssertEqual(
            ProfileStoreDocumentMutationPolicy
                .runtimeProfileIDAfterDeleting(
                    "whatsapp",
                    previousRuntimeProfileID: "gaming",
                    from: candidate
                ),
            "gaming"
        )
    }

    func testLegacyExactRepairIsOneContentPreservingCandidate()
        throws {
        let currentSpace = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "CURRENT"
        )!
        let unrelatedSpace = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "UNRELATED"
        )!
        let gaming = RepairFixtureProfile(
            id: "gaming",
            name: "Gaming",
            symbolName: "gamecontroller.fill",
            dateCreated: Date(timeIntervalSince1970: 10),
            hidden: ["com.example.hidden"],
            triggers: []
        )
        let legacy = ProfileTrigger.exactSpace(
            ExactSpaceTrigger(id: "legacy", spaceID: 413)
        )
        let retained = ProfileTrigger.frontmostApp(
            FrontmostAppTrigger(
                id: "retained",
                bundleIdentifier: "net.whatsapp.WhatsApp"
            )
        )
        let music = RepairFixtureProfile(
            id: "music",
            name: "WhatsApp + Spotify",
            symbolName: "music.note",
            dateCreated: Date(timeIntervalSince1970: 20),
            hidden: [
                "com.example.preserved",
            ],
            triggers: [legacy, retained]
        )
        let original = ProfileStoreEnvelope<RepairFixtureProfile>(
            revision: 22,
            activeProfileID: "gaming",
            profiles: [gaming, music],
            spaceAssignments: [
                SpaceProfileAssignment(
                    identity: currentSpace,
                    profileID: "gaming"
                ),
                SpaceProfileAssignment(
                    identity: unrelatedSpace,
                    profileID: "gaming"
                ),
            ]
        )

        let repaired = try XCTUnwrap(
            ProfileStoreDocumentMutationPolicy
                .repairingLegacyExactSpaceBinding(
                    profileID: "music",
                    triggerID: "legacy",
                    assigning: currentSpace,
                    expectedOwnerProfileID: "gaming",
                    in: original
                )
        )

        XCTAssertEqual(repaired.revision, original.revision)
        XCTAssertEqual(
            repaired.activeProfileID,
            original.activeProfileID
        )
        XCTAssertEqual(repaired.profiles[0], gaming)
        var expectedMusic = music
        expectedMusic.triggers = [retained]
        XCTAssertEqual(repaired.profiles[1], expectedMusic)
        XCTAssertEqual(
            SpaceProfileAssignmentPolicy.profileID(
                for: currentSpace,
                in: repaired.spaceAssignments
            ),
            "music"
        )
        XCTAssertEqual(
            SpaceProfileAssignmentPolicy.profileID(
                for: unrelatedSpace,
                in: repaired.spaceAssignments
            ),
            "gaming"
        )

        XCTAssertNil(
            ProfileStoreDocumentMutationPolicy
                .repairingLegacyExactSpaceBinding(
                    profileID: "music",
                    triggerID: "legacy",
                    assigning: currentSpace,
                    expectedOwnerProfileID: nil,
                    in: original
                ),
            "A stale expected owner must reject the whole mutation."
        )
        XCTAssertNil(
            ProfileStoreDocumentMutationPolicy
                .repairingLegacyExactSpaceBinding(
                    profileID: "music",
                    triggerID: "retained",
                    assigning: currentSpace,
                    expectedOwnerProfileID: "gaming",
                    in: original
                ),
            "A non-exact trigger must never be consumed as a repair row."
        )
    }

    func testSavedLegacyRepairRejectsAReplacementIdentity() {
        let savedSpace = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "SAVED"
        )!
        let otherSpace = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "OTHER"
        )!
        let profile = RepairFixtureProfile(
            id: "music",
            name: "Music",
            symbolName: "music.note",
            dateCreated: Date(timeIntervalSince1970: 1),
            hidden: [],
            triggers: [
                .exactSpace(
                    ExactSpaceTrigger(
                        id: "saved",
                        identity: savedSpace
                    )
                ),
            ]
        )
        let document =
            ProfileStoreEnvelope<RepairFixtureProfile>(
            revision: 1,
            activeProfileID: profile.id,
            profiles: [profile]
        )

        XCTAssertNil(
            ProfileStoreDocumentMutationPolicy
                .repairingLegacyExactSpaceBinding(
                    profileID: profile.id,
                    triggerID: "saved",
                    assigning: otherSpace,
                    expectedOwnerProfileID: nil,
                    in: document
                )
        )
    }

    func testSchemaOneAssignmentMergePreservesExistingValues()
        throws {
        let existingIdentity = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "EXISTING"
        )!
        let migratedIdentity = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "MIGRATED"
        )!
        let existing = SpaceProfileAssignment(
            identity: existingIdentity,
            profileID: "main"
        )
        let migrated = SpaceProfileAssignment(
            identity: migratedIdentity,
            profileID: "music"
        )

        XCTAssertEqual(
            try ProfileStoreSchemaMigrationPolicy
                .mergingSpaceAssignments(
                    existing: [existing],
                    migrated: [migrated, existing]
                ),
            [existing, migrated]
        )
    }

    func testSchemaOneAssignmentMergeRejectsConflictingOwners() {
        let identity = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "SAME"
        )!

        XCTAssertThrowsError(
            try ProfileStoreSchemaMigrationPolicy
                .mergingSpaceAssignments(
                    existing: [
                        SpaceProfileAssignment(
                            identity: identity,
                            profileID: "gaming"
                        ),
                    ],
                    migrated: [
                        SpaceProfileAssignment(
                            identity: identity,
                            profileID: "music"
                        ),
                    ]
                )
        ) { error in
            XCTAssertEqual(
                error as? ProfileStoreValidationError,
                .conflictingSpaceAssignmentMigration(
                    identity.storageKey
                )
            )
        }
    }

    func testFullRecoverySnapshotRetainsSchemaRevisionAndAssignments()
        throws {
        let identity = MissionControlSpaceIdentity(
            displayUUID: "ignored",
            spaceUUID: "MUSIC"
        )!
        let document = Document(
            revision: 44,
            activeProfileID: "music",
            profiles: [
                FixtureProfile(id: "main", name: "Main"),
                FixtureProfile(
                    id: "music",
                    name: "WhatsApp + Spotify"
                ),
            ],
            spaceAssignments: [
                SpaceProfileAssignment(
                    identity: identity,
                    profileID: "music"
                ),
            ]
        )

        let data = try ProfileStoreRecoverySnapshotCodec.encode(
            document
        )
        let recovered = try ProfileStoreRecoverySnapshotCodec.decode(
            data,
            as: FixtureProfile.self
        )

        XCTAssertEqual(recovered, document)
        XCTAssertEqual(recovered.schemaVersion, 2)
        XCTAssertEqual(recovered.revision, 44)
        XCTAssertEqual(recovered.spaceAssignments.count, 1)
    }

    func testRecoverySnapshotEncodingHasStableSortedKeys() throws {
        let document = Document(
            revision: 44,
            activeProfileID: "main",
            profiles: [
                FixtureProfile(id: "main", name: "Main"),
            ]
        )

        let first = try ProfileStoreRecoverySnapshotCodec.encode(
            document
        )
        let second = try ProfileStoreRecoverySnapshotCodec.encode(
            document
        )
        XCTAssertEqual(first, second)

        let json = try XCTUnwrap(
            String(data: first, encoding: .utf8)
        )
        let orderedKeys = [
            "\"activeProfileID\"",
            "\"profiles\"",
            "\"revision\"",
            "\"schemaVersion\"",
            "\"spaceAssignments\"",
        ]
        var lowerBound = json.startIndex
        for key in orderedKeys {
            let range = try XCTUnwrap(
                json.range(
                    of: key,
                    range: lowerBound..<json.endIndex
                )
            )
            lowerBound = range.upperBound
        }
    }

    func testProfileMetadataRequiresSafeNamesAndUniqueTriggerIDs() {
        XCTAssertNoThrow(
            try ProfileStoreProfileMetadataPolicy.validate([
                ProfileStoreProfileMetadata(
                    profileID: "main",
                    name: "Main",
                    triggerIDs: ["main-trigger"]
                ),
                ProfileStoreProfileMetadata(
                    profileID: "music",
                    name: "WhatsApp + Spotify",
                    triggerIDs: ["music-trigger"]
                ),
            ])
        )

        let invalidCases: [(
            [ProfileStoreProfileMetadata],
            ProfileStoreValidationError
        )] = [
            (
                [
                    ProfileStoreProfileMetadata(
                        profileID: "blank",
                        name: " \n ",
                        triggerIDs: []
                    ),
                ],
                .emptyProfileName("blank")
            ),
            (
                [
                    ProfileStoreProfileMetadata(
                        profileID: "spaced",
                        name: " Main ",
                        triggerIDs: []
                    ),
                ],
                .profileNameNotTrimmed("spaced")
            ),
            (
                [
                    ProfileStoreProfileMetadata(
                        profileID: "one",
                        name: "Résumé",
                        triggerIDs: []
                    ),
                    ProfileStoreProfileMetadata(
                        profileID: "two",
                        name: "RESUME",
                        triggerIDs: []
                    ),
                ],
                .duplicateProfileName("RESUME")
            ),
            (
                [
                    ProfileStoreProfileMetadata(
                        profileID: "one",
                        name: "One",
                        triggerIDs: ["same"]
                    ),
                    ProfileStoreProfileMetadata(
                        profileID: "two",
                        name: "Two",
                        triggerIDs: ["same"]
                    ),
                ],
                .duplicateTriggerID("same")
            ),
            (
                [
                    ProfileStoreProfileMetadata(
                        profileID: "empty-trigger",
                        name: "Empty trigger",
                        triggerIDs: [""]
                    ),
                ],
                .emptyTriggerID("empty-trigger")
            ),
        ]

        for (profiles, expectedError) in invalidCases {
            XCTAssertThrowsError(
                try ProfileStoreProfileMetadataPolicy.validate(
                    profiles
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProfileStoreValidationError,
                    expectedError
                )
            }
        }
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

    func testProfileServiceWiresIdempotentManualIntentDisposition()
        throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/ProfileService.swift"
            ),
            encoding: .utf8
        )
        let branchStart = try XCTUnwrap(
            source.range(
                of:
                    "if let manualDisposition,\n" +
                    "           manualDisposition.isVisuallyAndDurablyIdempotent"
            )
        )
        let activationStart = try XCTUnwrap(
            source.range(
                of:
                    "diagnostics.record(.profiles, \"profileActivationBegan\"",
                range: branchStart.upperBound..<source.endIndex
            )
        )
        let idempotentBranch = source[
            branchStart.lowerBound..<activationStart.lowerBound
        ]

        XCTAssertTrue(
            idempotentBranch.contains(
                "manualDisposition.shouldEmitIntentNotification"
            )
        )
        XCTAssertTrue(
            idempotentBranch.contains("postActivationChange(")
        )
        XCTAssertFalse(idempotentBranch.contains("commit("))
        XCTAssertFalse(
            idempotentBranch.contains("activateRuntimeProfile(")
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

    func testUserDefaultsRecoverySnapshotStoresTheWholeDocument()
        throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/ProfileService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "\"docky.profileStoreSnapshotV2\""
            )
        )
        XCTAssertTrue(
            source.contains(
                "ProfileStoreRecoverySnapshotCodec.encode("
            )
        )
        XCTAssertTrue(
            source.contains(
                "ProfileStoreRecoverySnapshotCodec.decode("
            )
        )
        XCTAssertTrue(
            source.contains(
                "defaults.data(forKey: LegacyKeys.fullDocument)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "defaults.data(forKey: LegacyKeys.profiles)"
            )
        )
        let fullSnapshot = try XCTUnwrap(
            source.range(
                of:
                    "if let fullSnapshotObject = defaults.object("
            )
        )
        let profilesOnly = try XCTUnwrap(
            source.range(
                of:
                    "guard let legacyData = defaults.data(forKey: LegacyKeys.profiles)"
            )
        )
        XCTAssertLessThan(
            fullSnapshot.lowerBound,
            profilesOnly.lowerBound,
            "Full schema-2 recovery must take precedence over the lossy profiles-only snapshot."
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
