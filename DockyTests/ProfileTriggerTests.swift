import Foundation
import XCTest

final class ProfileTriggerTests: XCTestCase {
    func testStartupDockImportRejectsSpaceActivatedProfile()
    {
        var layouts = [
            "empty": [String](),
            "messaging": [
                "net.whatsapp.WhatsApp",
                "com.spotify.client",
            ],
        ]
        var importComplete = false
        let credentials =
            ProfileMutationCredentials(
                profileID: "empty",
                revision: 41
            )

        // The plist read is in flight when a Space trigger activates the
        // WhatsApp/Spotify profile.
        let applied = applySimulatedSystemDockSync(
            credentials: credentials,
            activeProfileID: "messaging",
            currentRevision: 41,
            importedBundleIdentifiers: [
                "com.apple.Safari",
            ],
            marksInitialImportComplete: true,
            layouts: &layouts,
            importComplete: &importComplete
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(layouts["empty"], [])
        XCTAssertEqual(
            layouts["messaging"],
            [
                "net.whatsapp.WhatsApp",
                "com.spotify.client",
            ]
        )
        XCTAssertFalse(importComplete)
    }

    func testEditorDockSyncRejectsSpaceActivationDuringWorkerAwait()
    {
        var layouts = [
            "work": ["com.apple.dt.Xcode"],
            "gaming": ["com.valvesoftware.steam"],
        ]
        var importComplete = false
        let credentials =
            ProfileMutationCredentials(
                profileID: "work",
                revision: 73
            )

        // DockEditorService captured Work before awaiting its plist worker;
        // Gaming is active by the time TileStore receives the result.
        let applied = applySimulatedSystemDockSync(
            credentials: credentials,
            activeProfileID: "gaming",
            currentRevision: 73,
            importedBundleIdentifiers: [
                "com.apple.dt.Xcode",
                "com.apple.Safari",
            ],
            marksInitialImportComplete: false,
            layouts: &layouts,
            importComplete: &importComplete
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(
            layouts["work"],
            ["com.apple.dt.Xcode"]
        )
        XCTAssertEqual(
            layouts["gaming"],
            ["com.valvesoftware.steam"]
        )
        XCTAssertFalse(importComplete)
    }

    func testSystemDockSyncAcceptsOnlyExactProfileRevision()
    {
        let credentials =
            ProfileMutationCredentials(
                profileID: "work",
                revision: 9
            )

        XCTAssertEqual(
            credentials.validation(
                activeProfileID: "other",
                currentRevision: 9
            ),
            .profileChanged
        )
        XCTAssertEqual(
            credentials.validation(
                activeProfileID: "work",
                currentRevision: 10
            ),
            .revisionChanged
        )
        XCTAssertEqual(
            credentials.validation(
                activeProfileID: "work",
                currentRevision: 9
            ),
            .current
        )
    }

    func testTimeTriggerWeekdaysHaveCanonicalEncoding()
        throws {
        let trigger = TimeOfDayTrigger(
            id: "hours",
            startMinuteOfDay: 540,
            endMinuteOfDay: 1020,
            weekdays: [6, 2, 5, 3, 4]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let first = try encoder.encode(trigger)
        let second = try encoder.encode(trigger)
        XCTAssertEqual(first, second)
        XCTAssertTrue(
            try XCTUnwrap(
                String(data: first, encoding: .utf8)
            ).contains(
                "\"weekdays\":[2,3,4,5,6]"
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                TimeOfDayTrigger.self,
                from: first
            ),
            trigger
        )
    }

    func testTriggerEditorImmediateRejectKeepsCanonicalTimeValue() {
        let identity = ProfileTriggerEditorIdentity(
            profileID: "work",
            triggerID: "hours"
        )
        let canonical = TimeOfDayTrigger(
            id: "hours",
            startMinuteOfDay: 9 * 60,
            endMinuteOfDay: 17 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        let rejectedDraft = TimeOfDayTrigger(
            id: "hours",
            startMinuteOfDay: 12 * 60,
            endMinuteOfDay: 20 * 60,
            weekdays: [1, 7]
        )

        // A rejected service update never enters the canonical collection.
        // The editor projection therefore cannot display the attempted draft.
        XCTAssertNotEqual(canonical, rejectedDraft)
        XCTAssertEqual(
            identity.resolve(
                canonicalProfileID: "work",
                triggers: [.timeOfDay(canonical)]
            ),
            .timeOfDay(canonical)
        )
    }

    func testTriggerEditorLaterRollbackRestoresCanonicalAppValue() {
        let identity = ProfileTriggerEditorIdentity(
            profileID: "music",
            triggerID: "frontmost"
        )
        let durable = FrontmostAppTrigger(
            id: "frontmost",
            bundleIdentifier: "com.spotify.client"
        )
        let optimistic = FrontmostAppTrigger(
            id: "frontmost",
            bundleIdentifier: "net.whatsapp.WhatsApp"
        )

        XCTAssertEqual(
            identity.resolve(
                canonicalProfileID: "music",
                triggers: [.frontmostApp(optimistic)]
            ),
            .frontmostApp(optimistic)
        )

        // Persistence failure republishes the durable profile document. The
        // same stable editor identity resolves that restored value.
        XCTAssertEqual(
            identity.resolve(
                canonicalProfileID: "music",
                triggers: [.frontmostApp(durable)]
            ),
            .frontmostApp(durable)
        )
    }

    func testTriggerEditorSuccessTracksCanonicalSpaceValue() {
        let identity = ProfileTriggerEditorIdentity(
            profileID: "chat",
            triggerID: "space-app"
        )
        let original = SpaceTrigger(
            id: "space-app",
            bundleIdentifier: "com.spotify.client"
        )
        let accepted = SpaceTrigger(
            id: "space-app",
            bundleIdentifier: "net.whatsapp.WhatsApp"
        )

        XCTAssertEqual(
            identity.resolve(
                canonicalProfileID: "chat",
                triggers: [.space(original)]
            ),
            .space(original)
        )
        XCTAssertEqual(
            identity.resolve(
                canonicalProfileID: "chat",
                triggers: [.space(accepted)]
            ),
            .space(accepted)
        )
    }

    func testResolvedApplicationNameCannotCrossCanonicalRollback() {
        let optimisticResult = ProfileApplicationNameResolution(
            bundleIdentifier: "net.whatsapp.WhatsApp",
            displayName: "WhatsApp"
        )

        XCTAssertEqual(
            optimisticResult.displayName(
                forCanonicalBundleIdentifier:
                    "net.whatsapp.WhatsApp"
            ),
            "WhatsApp"
        )
        XCTAssertNil(
            optimisticResult.displayName(
                forCanonicalBundleIdentifier:
                    "com.spotify.client"
            ),
            "A stale async result must not label a restored canonical app."
        )
    }

    func testOvernightTimeRangeIncludesStartAndExcludesEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let trigger = TimeOfDayTrigger(
            id: "overnight",
            startMinuteOfDay: 22 * 60,
            endMinuteOfDay: 6 * 60,
            weekdays: [2, 3]
        )

        XCTAssertFalse(
            trigger.matches(
                date: date(2024, 1, 1, 21, 59, calendar),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            trigger.matches(
                date: date(2024, 1, 1, 22, 0, calendar),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            trigger.matches(
                date: date(2024, 1, 2, 5, 59, calendar),
                calendar: calendar
            )
        )
        XCTAssertFalse(
            trigger.matches(
                date: date(2024, 1, 2, 6, 0, calendar),
                calendar: calendar
            )
        )
    }

    func testLegacyNumericExactTriggerDecodesButNeverMatches() throws {
        let data = try XCTUnwrap(
            """
            {
              "exactSpace": {
                "_0": {
                  "id": "legacy",
                  "spaceID": 413
                }
              }
            }
            """.data(using: .utf8)
        )

        let trigger = try JSONDecoder().decode(
            ProfileTrigger.self,
            from: data
        )
        guard case .exactSpace(let exact) = trigger else {
            return XCTFail("Expected a legacy exact trigger")
        }
        XCTAssertEqual(exact.spaceID, 413)
        XCTAssertNil(exact.identity)
        XCTAssertFalse(exact.matches(identity("DISPLAY-A", "SPACE-A")))
    }

    func testAssignmentRoundTripPreservesDurableIdentity() throws {
        let assignment = SpaceProfileAssignment(
            identity: identity("DISPLAY-A", "SPACE-A"),
            profileID: "work"
        )
        let decoded = try JSONDecoder().decode(
            SpaceProfileAssignment.self,
            from: JSONEncoder().encode(assignment)
        )
        XCTAssertEqual(decoded, assignment)
    }

    func testAssigningOneSpacePreservesEveryOtherAssignment() {
        let home = identity("DISPLAY-A", "HOME")
        let work = identity("DISPLAY-A", "WORK")
        let original = [
            SpaceProfileAssignment(
                identity: home,
                profileID: "home"
            ),
            SpaceProfileAssignment(
                identity: work,
                profileID: "work"
            ),
        ]

        let updated = SpaceProfileAssignmentPolicy.assigning(
            work,
            to: "music",
            in: original
        )

        XCTAssertEqual(
            SpaceProfileAssignmentPolicy.profileID(
                for: home,
                in: updated
            ),
            "home"
        )
        XCTAssertEqual(
            SpaceProfileAssignmentPolicy.profileID(
                for: work,
                in: updated
            ),
            "music"
        )
        XCTAssertEqual(updated.count, 2)
    }

    func testAssigningExistingOwnerIsExactlyIdempotent() {
        let owned = identity("DISPLAY-A", "OWNED")
        let other = identity("DISPLAY-A", "OTHER")
        let original = [
            SpaceProfileAssignment(
                identity: owned,
                profileID: "music"
            ),
            SpaceProfileAssignment(
                identity: other,
                profileID: "work"
            ),
        ]

        XCTAssertEqual(
            SpaceProfileAssignmentPolicy.assigning(
                owned,
                to: "music",
                in: original
            ),
            original
        )
    }

    func testConflictingAssignmentInputFailsClosed() {
        let space = identity("DISPLAY-A", "SPACE-A")
        let conflicting = [
            SpaceProfileAssignment(
                identity: space,
                profileID: "one"
            ),
            SpaceProfileAssignment(
                identity: space,
                profileID: "two"
            ),
        ]

        XCTAssertNil(
            SpaceProfileAssignmentPolicy.profileID(
                for: space,
                in: conflicting
            )
        )
    }

    func testExactAssignmentWinsOverGenericTrigger() {
        let profiles = [
            evaluationProfile(
                "generic",
                triggers: [
                    .frontmostApp(
                        FrontmostAppTrigger(
                            bundleIdentifier: "com.example.editor"
                        )
                    ),
                ]
            ),
            evaluationProfile("assigned", triggers: []),
        ]

        XCTAssertEqual(
            ProfileTriggerResolver.resolve(
                profiles: profiles,
                context: context(
                    frontmost: "com.example.editor",
                    state: .assigned(profileID: "assigned")
                )
            ),
            ProfileTriggerResolution(
                profileID: "assigned",
                specificity: 4,
                usedUnassignedSpaceFallback: false
            )
        )
    }

    func testNewUnassignedRegularSpaceRejectsMatchingGenericTrigger() {
        XCTAssertNil(
            ProfileTriggerResolver.resolve(
                profiles: [
                    evaluationProfile(
                        "generic",
                        triggers: [
                            .frontmostApp(
                                FrontmostAppTrigger(
                                    bundleIdentifier:
                                        "com.example.editor"
                                )
                            ),
                        ]
                    ),
                ],
                context: context(
                    frontmost: "com.example.editor",
                    state: .unassignedRegular
                )
            )
        )
    }

    func testLaterRevalidatedEventCanUseGenericRuleOnUnassignedSpace() {
        XCTAssertEqual(
            ProfileTriggerResolver.resolve(
                profiles: [
                    evaluationProfile(
                        "generic",
                        triggers: [
                            .frontmostApp(
                                FrontmostAppTrigger(
                                    bundleIdentifier:
                                        "com.example.editor"
                                )
                            ),
                        ]
                    ),
                ],
                context: context(
                    frontmost: "com.example.editor",
                    state: .unassignedRegular,
                    allowsGenericRules: true
                )
            ),
            ProfileTriggerResolution(
                profileID: "generic",
                specificity: 2,
                usedUnassignedSpaceFallback: true
            )
        )
    }

    func testAssignmentToMissingProfileRejectsMatchingGenericTrigger() {
        XCTAssertNil(
            ProfileTriggerResolver.resolve(
                profiles: [
                    evaluationProfile(
                        "generic",
                        triggers: [
                            .frontmostApp(
                                FrontmostAppTrigger(
                                    bundleIdentifier:
                                        "com.example.editor"
                                )
                            ),
                        ]
                    ),
                ],
                context: context(
                    frontmost: "com.example.editor",
                    state: .assigned(profileID: "deleted")
                )
            )
        )
    }

    func testNonassignableSpaceCanUseMatchingGenericTrigger() {
        XCTAssertEqual(
            ProfileTriggerResolver.resolve(
                profiles: [
                    evaluationProfile(
                        "fullscreen",
                        triggers: [
                            .space(
                                SpaceTrigger(
                                    bundleIdentifier:
                                        "com.example.player"
                                )
                            ),
                        ]
                    ),
                ],
                context: context(
                    spaceApps: ["com.example.player"],
                    state: .nonassignable
                )
            ),
            ProfileTriggerResolution(
                profileID: "fullscreen",
                specificity: 3,
                usedUnassignedSpaceFallback: false
            )
        )
    }

    func testLegacyExactTriggerIsInertUntilRepaired() {
        let legacy = ExactSpaceTrigger(
            identity: identity("DISPLAY-A", "SPACE-A")
        )
        XCTAssertNil(
            ProfileTriggerResolver.resolve(
                profiles: [
                    evaluationProfile(
                        "legacy",
                        triggers: [.exactSpace(legacy)]
                    ),
                ],
                context: context(
                    state: .unresolved
                )
            )
        )
    }

    func testUnresolvedSpaceRejectsMatchingGenericTrigger() {
        XCTAssertNil(
            ProfileTriggerResolver.resolve(
                profiles: [
                    evaluationProfile(
                        "generic",
                        triggers: [
                            .frontmostApp(
                                FrontmostAppTrigger(
                                    bundleIdentifier:
                                        "com.example.player"
                                )
                            ),
                        ]
                    ),
                ],
                context: context(
                    frontmost: "com.example.player",
                    state: .unresolved
                )
            )
        )
    }

    func testLegacyMigrationExtractsNamedUUIDButRetainsNumericRow() {
        let named = identity("DISPLAY-A", "SPACE-Z")
        let plan = LegacyExactSpaceAssignmentMigrationPolicy.makePlan(
            profiles: [
                LegacyExactSpaceMigrationProfileInput(
                    profileID: "music",
                    triggers: [
                        .exactSpace(
                            ExactSpaceTrigger(
                                id: "named",
                                identity: named
                            )
                        ),
                        .exactSpace(
                            ExactSpaceTrigger(
                                id: "numeric",
                                spaceID: 413
                            )
                        ),
                    ]
                ),
            ]
        )

        XCTAssertEqual(
            plan.assignments,
            [
                SpaceProfileAssignment(
                    identity: named,
                    profileID: "music"
                ),
            ]
        )
        XCTAssertEqual(
            plan.migratedIdentities(for: "music"),
            [named]
        )
        XCTAssertEqual(
            plan.assignments.count,
            1,
            "The numeric-only row must remain outside the migration plan."
        )
    }

    func testLegacyMigrationRetainsCrossProfileConflict() {
        let sharedIdentity = identity("DISPLAY-A", "SAME-SPACE")
        let plan = LegacyExactSpaceAssignmentMigrationPolicy.makePlan(
            profiles: ["music", "gaming"].map { profileID in
                LegacyExactSpaceMigrationProfileInput(
                    profileID: profileID,
                    triggers: [
                        .exactSpace(
                            ExactSpaceTrigger(
                                id: "\(profileID)-trigger",
                                identity: sharedIdentity
                            )
                        ),
                    ]
                )
            }
        )

        XCTAssertEqual(plan.assignments, [])
        XCTAssertEqual(
            plan.migratedIdentities(for: "music"),
            []
        )
        XCTAssertEqual(
            plan.migratedIdentities(for: "gaming"),
            []
        )
    }

    func testLegacyMigrationCanonicalizesRootToSharedScope() {
        let physicalRoot = identity("DISPLAY-A", "")
        let sharedRoot = identity(
            MissionControlSpaceIdentity.sharedDisplayScope,
            ""
        )
        let plan = LegacyExactSpaceAssignmentMigrationPolicy.makePlan(
            profiles: [
                LegacyExactSpaceMigrationProfileInput(
                    profileID: "main",
                    triggers: [
                        .exactSpace(
                            ExactSpaceTrigger(
                                id: "root",
                                identity: physicalRoot
                            )
                        ),
                    ]
                ),
            ],
            rootDisplayScopeOverride:
                MissionControlSpaceIdentity.sharedDisplayScope
        )

        XCTAssertEqual(
            plan.assignments,
            [
                SpaceProfileAssignment(
                    identity: sharedRoot,
                    profileID: "main"
                ),
            ]
        )
        XCTAssertEqual(
            plan.migratedIdentities(for: "main"),
            [sharedRoot]
        )
    }

    func testLegacyMigrationIdentityUsesThePlanCanonicalizationContract() {
        let named = identity("DISPLAY-A", "NAMED")
        let physicalRoot = identity("DISPLAY-A", "")
        let sharedRoot = identity(
            MissionControlSpaceIdentity.sharedDisplayScope,
            ""
        )

        XCTAssertEqual(
            LegacyExactSpaceAssignmentMigrationPolicy.migrationIdentity(
                for: ExactSpaceTrigger(identity: named),
                rootDisplayScopeOverride:
                    MissionControlSpaceIdentity.sharedDisplayScope
            ),
            named,
            "A display-scope override must not change a named Space."
        )
        XCTAssertEqual(
            LegacyExactSpaceAssignmentMigrationPolicy.migrationIdentity(
                for: ExactSpaceTrigger(identity: physicalRoot),
                rootDisplayScopeOverride:
                    MissionControlSpaceIdentity.sharedDisplayScope
            ),
            sharedRoot
        )
        XCTAssertNil(
            LegacyExactSpaceAssignmentMigrationPolicy.migrationIdentity(
                for: ExactSpaceTrigger(spaceID: 413),
                rootDisplayScopeOverride:
                    MissionControlSpaceIdentity.sharedDisplayScope
            )
        )
    }

    func testLegacyMigrationPlanOrderingIsStable() {
        let firstInput = LegacyExactSpaceMigrationProfileInput(
            profileID: "z-profile",
            triggers: [
                .exactSpace(
                    ExactSpaceTrigger(
                        id: "z",
                        identity: identity("DISPLAY-A", "Z-SPACE")
                    )
                ),
                .exactSpace(
                    ExactSpaceTrigger(
                        id: "a",
                        identity: identity("DISPLAY-A", "A-SPACE")
                    )
                ),
            ]
        )
        let secondInput = LegacyExactSpaceMigrationProfileInput(
            profileID: "a-profile",
            triggers: [
                .exactSpace(
                    ExactSpaceTrigger(
                        id: "m",
                        identity: identity("DISPLAY-A", "M-SPACE")
                    )
                ),
            ]
        )

        let forward = LegacyExactSpaceAssignmentMigrationPolicy.makePlan(
            profiles: [firstInput, secondInput]
        )
        let reversed = LegacyExactSpaceAssignmentMigrationPolicy.makePlan(
            profiles: [
                LegacyExactSpaceMigrationProfileInput(
                    profileID: secondInput.profileID,
                    triggers: Array(secondInput.triggers.reversed())
                ),
                LegacyExactSpaceMigrationProfileInput(
                    profileID: firstInput.profileID,
                    triggers: Array(firstInput.triggers.reversed())
                ),
            ]
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            forward.assignments.map(\.identity.storageKey),
            [
                "space:a-space",
                "space:m-space",
                "space:z-space",
            ]
        )
        XCTAssertEqual(
            forward.profileResults.map(\.profileID),
            ["a-profile", "z-profile"]
        )
        XCTAssertEqual(
            forward.migratedIdentities(for: "z-profile")
                .map(\.storageKey),
            ["space:a-space", "space:z-space"]
        )
    }

    func testManualOverrideSurvivesSpuriousSameTargetTransition() {
        var state = ProfileManualOverrideState()
        let desktop = snapshot("DISPLAY-A", "MUSIC", spaceID: 4)
        state.record(profileID: "music", observedTarget: desktop)

        state.reconcileCommittedTarget(desktop)

        XCTAssertEqual(state.profileID, "music")
        XCTAssertEqual(
            state.recordedTarget,
            ProfileManualOverrideTarget(desktop)
        )
    }

    func testManualOverrideClearsOnlyForLaterDifferentTarget() {
        var state = ProfileManualOverrideState()
        state.record(
            profileID: "music",
            observedTarget:
                snapshot("DISPLAY-A", "MUSIC", spaceID: 4)
        )

        state.reconcileCommittedTarget(
            snapshot("DISPLAY-A", "WORK", spaceID: 5)
        )

        XCTAssertNil(state.profileID)
        XCTAssertNil(state.recordedTarget)
    }

    func testManualOverrideWithUnresolvedObservationBindsNextCommit() {
        var state = ProfileManualOverrideState()
        state.record(profileID: "music", observedTarget: nil)

        let desktop = snapshot("DISPLAY-A", "MUSIC", spaceID: 5)
        state.reconcileCommittedTarget(desktop)

        XCTAssertEqual(state.profileID, "music")
        XCTAssertEqual(
            state.recordedTarget,
            ProfileManualOverrideTarget(desktop)
        )
        XCTAssertFalse(state.awaitsTargetBinding)
    }

    func testManualOverrideDuringPendingClearsIfObservedTargetChanges() {
        var state = ProfileManualOverrideState()
        state.record(
            profileID: "music",
            observedTarget:
                snapshot("DISPLAY-A", "OLD", spaceID: 4)
        )

        state.reconcileCommittedTarget(
            snapshot("DISPLAY-A", "NEW", spaceID: 5)
        )

        XCTAssertNil(state.profileID)
    }

    func testManualOverrideUpgradesMissingIdentityOnSameObservedTarget() {
        var state = ProfileManualOverrideState()
        let unidentified = ActiveSpaceSnapshot(
            spaceID: 44,
            rawType: 0,
            displayIdentifier: "DISPLAY-A",
            displayOrdinal: 2
        )
        let identified = ActiveSpaceSnapshot(
            spaceID: 44,
            identity: identity("DISPLAY-A", "MUSIC"),
            rawType: 0,
            displayIdentifier: "DISPLAY-A",
            displayOrdinal: 2
        )

        state.record(
            profileID: "music",
            observedTarget: unidentified
        )
        state.reconcileCommittedTarget(identified)

        XCTAssertEqual(state.profileID, "music")
        XCTAssertEqual(
            state.recordedTarget,
            ProfileManualOverrideTarget(identified)
        )
    }

    func testManualOverrideNeverDowngradesKnownIdentity() {
        var state = ProfileManualOverrideState()
        let identified = snapshot(
            "DISPLAY-A",
            "MUSIC",
            spaceID: 44
        )
        state.record(
            profileID: "music",
            observedTarget: identified
        )

        state.reconcileCommittedTarget(
            ActiveSpaceSnapshot(
                spaceID: 44,
                rawType: 0,
                displayIdentifier: "DISPLAY-A",
                displayOrdinal: 1
            )
        )

        XCTAssertEqual(state.profileID, "music")
        XCTAssertEqual(
            state.recordedTarget,
            ProfileManualOverrideTarget(identified)
        )
    }

    func testManualOverrideClearsForDifferentDurableIdentityEvenIfIDReused() {
        var state = ProfileManualOverrideState()
        state.record(
            profileID: "music",
            observedTarget:
                snapshot("DISPLAY-A", "OLD", spaceID: 44)
        )

        state.reconcileCommittedTarget(
            snapshot("DISPLAY-A", "NEW", spaceID: 44)
        )

        XCTAssertNil(state.profileID)
        XCTAssertNil(state.recordedTarget)
    }

    func testLatestUnboundManualIntentBindsNextCoherentCommit() {
        var state = ProfileManualOverrideState()
        state.recordUnbound(profileID: "music")
        state.recordUnbound(profileID: "work")
        let destination =
            snapshot("DISPLAY-A", "DESTINATION", spaceID: 55)

        state.reconcileCommittedTarget(destination)

        XCTAssertEqual(state.profileID, "work")
        XCTAssertEqual(
            state.recordedTarget,
            ProfileManualOverrideTarget(destination)
        )
        XCTAssertFalse(state.awaitsTargetBinding)
    }

    func testCurrentResidencyDefersNewAssignmentUntilReentry() {
        var residency = ProfileSpaceResidencyState()
        let desktop =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)

        residency.reconcileCommittedTarget(
            desktop,
            targetChanged: true,
            liveAssignedProfileID: nil
        )
        XCTAssertEqual(
            residency.evaluationState(for: desktop),
            .unassignedRegular
        )

        // This models an assignment followed by app, minute, or watchdog
        // reconciliation on the same still-resident Desktop.
        residency.reconcileCommittedTarget(
            desktop,
            targetChanged: false,
            liveAssignedProfileID: "gaming"
        )
        XCTAssertEqual(
            residency.evaluationState(for: desktop),
            .unassignedRegular
        )
    }

    func testCurrentResidencyDefersReassignmentAndRemoval() {
        var residency = ProfileSpaceResidencyState()
        let desktop =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)
        residency.reconcileCommittedTarget(
            desktop,
            targetChanged: true,
            liveAssignedProfileID: "original"
        )

        for editedOwner in ["replacement", nil] as [String?] {
            residency.reconcileCommittedTarget(
                desktop,
                targetChanged: false,
                liveAssignedProfileID: editedOwner
            )
            XCTAssertEqual(
                residency.evaluationState(for: desktop),
                .assigned(profileID: "original")
            )
        }
    }

    func testLeavingAndReturningRelatchesCurrentAssignmentOwner() {
        var residency = ProfileSpaceResidencyState()
        let first =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)
        let second =
            snapshot("DISPLAY-A", "DESKTOP-B", spaceID: 11)
        residency.reconcileCommittedTarget(
            first,
            targetChanged: true,
            liveAssignedProfileID: "original"
        )
        residency.reconcileCommittedTarget(
            first,
            targetChanged: false,
            liveAssignedProfileID: "replacement"
        )

        residency.reconcileCommittedTarget(
            second,
            targetChanged: true,
            liveAssignedProfileID: "other"
        )
        residency.reconcileCommittedTarget(
            first,
            targetChanged: true,
            liveAssignedProfileID: "replacement"
        )

        XCTAssertEqual(
            residency.evaluationState(for: first),
            .assigned(profileID: "replacement")
        )
    }

    func testEngineRestartRelatchesCurrentAssignmentOwner() {
        var residency = ProfileSpaceResidencyState()
        let desktop =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)
        residency.reconcileCommittedTarget(
            desktop,
            targetChanged: true,
            liveAssignedProfileID: "original"
        )
        residency.reconcileCommittedTarget(
            desktop,
            targetChanged: false,
            liveAssignedProfileID: "replacement"
        )

        residency.reset()
        residency.reconcileCommittedTarget(
            desktop,
            targetChanged: true,
            liveAssignedProfileID: "replacement"
        )

        XCTAssertEqual(
            residency.evaluationState(for: desktop),
            .assigned(profileID: "replacement")
        )
    }

    func testRegularDesktopWithoutDurableIdentityIsUnresolved() {
        var residency = ProfileSpaceResidencyState()
        let unidentified = ActiveSpaceSnapshot(
            spaceID: 10,
            rawType: 0,
            displayIdentifier: "DISPLAY-A",
            displayOrdinal: 1
        )
        residency.reconcileCommittedTarget(
            unidentified,
            targetChanged: true,
            liveAssignedProfileID: nil
        )

        XCTAssertEqual(
            residency.evaluationState(for: unidentified),
            .unresolved
        )
    }

    func testRecoveredIdentityLatchesOnceAndSurvivesTemporaryLoss() {
        var residency = ProfileSpaceResidencyState()
        let unidentified = ActiveSpaceSnapshot(
            spaceID: 10,
            rawType: 0,
            displayIdentifier: "DISPLAY-A",
            displayOrdinal: 1
        )
        let identified =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)

        residency.reconcileCommittedTarget(
            unidentified,
            targetChanged: true,
            liveAssignedProfileID: nil
        )
        residency.reconcileCommittedTarget(
            identified,
            targetChanged: false,
            liveAssignedProfileID: "owner"
        )
        XCTAssertEqual(
            residency.evaluationState(for: identified),
            .assigned(profileID: "owner")
        )

        residency.reconcileCommittedTarget(
            unidentified,
            targetChanged: false,
            liveAssignedProfileID: "replacement"
        )
        XCTAssertEqual(
            residency.evaluationState(for: unidentified),
            .unresolved
        )

        residency.reconcileCommittedTarget(
            identified,
            targetChanged: false,
            liveAssignedProfileID: "replacement"
        )
        XCTAssertEqual(
            residency.evaluationState(for: identified),
            .assigned(profileID: "owner")
        )
    }

    func testAssignmentAndManualSamplingCanNeverEvaluateAutomation() {
        XCTAssertFalse(
            ProfileTriggerSamplingPurpose
                .assignmentVerification
                .shouldEvaluateAutomation
        )
        XCTAssertFalse(
            ProfileTriggerSamplingPurpose
                .manualBinding
                .shouldEvaluateAutomation
        )
        for purpose in [
            ProfileTriggerSamplingPurpose.startup,
            .topology,
            .frontmostApplication,
            .minute,
        ] {
            XCTAssertTrue(purpose.shouldEvaluateAutomation)
        }
    }

    func testLateTopologyCallbackCannotEraseExplicitSamplingIntent() {
        XCTAssertEqual(
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .frontmostApplication,
                incoming: .topology
            ),
            .frontmostApplication
        )
        XCTAssertEqual(
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .minute,
                incoming: .topology
            ),
            .minute
        )
        XCTAssertEqual(
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .topology,
                incoming: .frontmostApplication
            ),
            .frontmostApplication
        )
        XCTAssertEqual(
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .frontmostApplication,
                incoming: .minute
            ),
            .minute
        )
    }

    func testObservationOnlySamplingCannotBeDemotedByCallbacks() {
        XCTAssertEqual(
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .manualBinding,
                incoming: .topology
            ),
            .manualBinding
        )
        XCTAssertEqual(
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .assignmentVerification,
                incoming: .frontmostApplication
            ),
            .assignmentVerification
        )
        XCTAssertEqual(
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .frontmostApplication,
                incoming: .manualBinding
            ),
            .manualBinding
        )
    }

    func testCoalescedAppIntentStillEnablesChangedAppRule() {
        let oldEvidence = ProfileTriggerSpaceEvidence(
            frontmostBundleID: "com.example.editor",
            spaceApps: ["com.example.editor"]
        )
        let newEvidence = ProfileTriggerSpaceEvidence(
            frontmostBundleID: "com.example.chat",
            spaceApps: [
                "com.example.editor",
                "com.example.chat",
            ]
        )
        let effectivePurpose =
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: .frontmostApplication,
                incoming: .topology
            )

        XCTAssertTrue(
            ProfileTriggerSpaceEvidencePolicy.genericRulesAllowed(
                currentlyAllowed: false,
                purpose: effectivePurpose,
                targetChanged: false,
                previousEvidence: oldEvidence,
                newEvidence: newEvidence
            )
        )
    }

    func testNewTargetSuppressionSurvivesEvidenceFailureRetry() {
        var epoch = ProfileTriggerSamplingEpochState()
        epoch.record(.minute)
        epoch.noteCommittedTargetChange(true)

        // The first evidence bracket failed, so the intent is deliberately
        // not consumed. A late topology callback starts the retry.
        epoch.record(.topology)

        let effectivePurpose = epoch.effectivePurpose(
            fallback: .topology
        )
        let effectiveTargetChanged =
            epoch.effectiveTargetChanged(
                currentCommitTargetChanged: false
            )
        XCTAssertEqual(effectivePurpose, .minute)
        XCTAssertTrue(effectiveTargetChanged)
        XCTAssertFalse(
            ProfileTriggerSpaceEvidencePolicy.genericRulesAllowed(
                currentlyAllowed: false,
                purpose: effectivePurpose,
                targetChanged: effectiveTargetChanged,
                previousEvidence: nil,
                newEvidence: ProfileTriggerSpaceEvidence(
                    frontmostBundleID: "com.example.chat",
                    spaceApps: ["com.example.chat"]
                )
            )
        )

        epoch.consumeAutomation()
        XCTAssertNil(epoch.purpose)
        XCTAssertFalse(epoch.crossedTarget)
    }

    func testAssignmentVerificationOverlayPreservesTopologyIntent() {
        var epoch = ProfileTriggerSamplingEpochState()
        epoch.record(.topology)
        epoch.noteCommittedTargetChange(true)

        // The engine supplies this fallback only while the matching fresh
        // verification token owns the sampler. It must not mutate or consume
        // the ordinary epoch underneath.
        XCTAssertEqual(
            epoch.effectivePurpose(
                fallback: .assignmentVerification
            ),
            .assignmentVerification
        )
        XCTAssertEqual(epoch.purpose, .topology)
        XCTAssertTrue(epoch.crossedTarget)

        let effectivePurpose = epoch.effectivePurpose(
            fallback: .topology
        )
        XCTAssertEqual(effectivePurpose, .topology)
        XCTAssertTrue(effectivePurpose.shouldEvaluateAutomation)
    }

    func testFailedFreshVerificationCannotPoisonNextCommit() {
        let epoch = ProfileTriggerSamplingEpochState()
        XCTAssertNil(epoch.purpose)
        let nextPurpose = epoch.effectivePurpose(
            fallback: .topology
        )
        XCTAssertEqual(nextPurpose, .topology)
        XCTAssertTrue(nextPurpose.shouldEvaluateAutomation)
    }

    func testVerificationDiscoveredTargetCrossingForcesTopology()
        throws {
        var epoch = ProfileTriggerSamplingEpochState()
        epoch.noteCommittedTargetChange(true)

        XCTAssertNil(epoch.purpose)
        XCTAssertTrue(epoch.crossedTarget)
        let resumePurpose =
            epoch.purpose
                ?? (
                    epoch.crossedTarget
                    ? ProfileTriggerSamplingPurpose.topology
                    : nil
                )
        XCTAssertEqual(resumePurpose, .topology)
        XCTAssertTrue(
            try XCTUnwrap(resumePurpose)
                .shouldEvaluateAutomation
        )
    }

    func testManualObservationPreservesDeferredAutomationLane() {
        var epoch = ProfileTriggerSamplingEpochState()
        epoch.record(.manualBinding)
        epoch.record(.minute)
        epoch.noteCommittedTargetChange(true)

        XCTAssertEqual(
            epoch.effectivePurpose(fallback: .topology),
            .manualBinding
        )
        XCTAssertEqual(
            epoch.consumeObservation(.manualBinding),
            .minute
        )
        XCTAssertEqual(epoch.purpose, .minute)
        XCTAssertTrue(epoch.crossedTarget)

        epoch.consumeAutomation()
        XCTAssertNil(epoch.purpose)
        XCTAssertFalse(epoch.crossedTarget)
    }

    func testAutomationSignalsDeferDuringFreshVerification() {
        var deferral =
            ProfileTriggerAutomationSignalDeferral()

        XCTAssertNil(
            deferral.receive(
                .frontmostApplication,
                verificationInProgress: true
            )
        )
        XCTAssertNil(
            deferral.receive(
                .minute,
                verificationInProgress: true
            )
        )
        XCTAssertEqual(deferral.deferredPurpose, .minute)
        XCTAssertEqual(
            deferral.verificationDidFinish(),
            .minute
        )
        XCTAssertNil(deferral.deferredPurpose)
        XCTAssertEqual(
            deferral.receive(
                .frontmostApplication,
                verificationInProgress: false
            ),
            .frontmostApplication
        )
    }

    func testFreshReconciliationGateRejectsOverlap() throws {
        var gate = ProfileFreshReconciliationGate()
        let token = try XCTUnwrap(
            gate.begin(runEpoch: 1)
        )

        XCTAssertTrue(gate.isInProgress)
        XCTAssertNil(gate.begin(runEpoch: 1))

        gate.finish(token)
        XCTAssertFalse(gate.isInProgress)
        XCTAssertNotNil(gate.begin(runEpoch: 1))
    }

    func testLateFreshCompletionCannotReleaseNewEpochLease()
        throws {
        var gate = ProfileFreshReconciliationGate()
        let oldToken = try XCTUnwrap(
            gate.begin(runEpoch: 1)
        )
        gate.invalidate()
        let newToken = try XCTUnwrap(
            gate.begin(runEpoch: 2)
        )

        gate.finish(oldToken)

        XCTAssertTrue(gate.isInProgress)
        XCTAssertEqual(gate.activeToken, newToken)
        gate.finish(newToken)
        XCTAssertFalse(gate.isInProgress)
    }

    func testCoherentEvidenceUsesLiveFrontmostAndWindowApps() throws {
        let committed =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)
        let evidence = try XCTUnwrap(
            ProfileTriggerSpaceEvidencePolicy.validated(
                committedSnapshot: committed,
                postQuerySnapshot: committed,
                frontmostBefore: "com.example.editor",
                frontmostAfter: "com.example.editor",
                spaceApps: [
                    "com.example.editor",
                    "com.example.chat",
                ]
            )
        )

        XCTAssertEqual(
            evidence.frontmostBundleID,
            "com.example.editor"
        )
        XCTAssertEqual(
            evidence.spaceApps,
            [
                "com.example.editor",
                "com.example.chat",
            ]
        )
    }

    func testEvidenceRejectsSpaceChangeDuringWindowQuery() {
        XCTAssertNil(
            ProfileTriggerSpaceEvidencePolicy.validated(
                committedSnapshot:
                    snapshot(
                        "DISPLAY-A",
                        "DESKTOP-A",
                        spaceID: 10
                    ),
                postQuerySnapshot:
                    snapshot(
                        "DISPLAY-A",
                        "DESKTOP-B",
                        spaceID: 11
                    ),
                frontmostBefore: "com.example.editor",
                frontmostAfter: "com.example.editor",
                spaceApps: ["com.example.editor"]
            )
        )
    }

    func testEvidenceRejectsFrontmostChangeDuringWindowQuery() {
        let committed =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)
        XCTAssertNil(
            ProfileTriggerSpaceEvidencePolicy.validated(
                committedSnapshot: committed,
                postQuerySnapshot: committed,
                frontmostBefore: "com.example.old",
                frontmostAfter: "com.example.new",
                spaceApps: [
                    "com.example.old",
                    "com.example.new",
                ]
            )
        )
    }

    func testEvidenceRejectsIdentityLossDuringWindowQuery() {
        let committed =
            snapshot("DISPLAY-A", "DESKTOP-A", spaceID: 10)
        let unidentified = ActiveSpaceSnapshot(
            spaceID: 10,
            rawType: 0,
            displayIdentifier: "DISPLAY-A",
            displayOrdinal: 1
        )
        XCTAssertNil(
            ProfileTriggerSpaceEvidencePolicy.validated(
                committedSnapshot: committed,
                postQuerySnapshot: unidentified,
                frontmostBefore: "com.example.editor",
                frontmostAfter: "com.example.editor",
                spaceApps: ["com.example.editor"]
            )
        )
    }

    func testDelayedDuplicateAppSignalDoesNotEnableGenericRules() {
        let evidence = ProfileTriggerSpaceEvidence(
            frontmostBundleID: "com.example.editor",
            spaceApps: ["com.example.editor"]
        )

        XCTAssertFalse(
            ProfileTriggerSpaceEvidencePolicy
                .genericRulesAllowed(
                    currentlyAllowed: false,
                    purpose: .frontmostApplication,
                    targetChanged: false,
                    previousEvidence: evidence,
                    newEvidence: evidence
                )
        )
        XCTAssertFalse(
            ProfileTriggerSpaceEvidencePolicy
                .genericRulesAllowed(
                    currentlyAllowed: false,
                    purpose: .frontmostApplication,
                    targetChanged: false,
                    previousEvidence: evidence,
                    newEvidence: ProfileTriggerSpaceEvidence(
                        frontmostBundleID:
                            "com.example.editor",
                        spaceApps: [
                            "com.example.editor",
                            "com.example.late-window",
                        ]
                    )
                )
        )
        XCTAssertTrue(
            ProfileTriggerSpaceEvidencePolicy
                .genericRulesAllowed(
                    currentlyAllowed: false,
                    purpose: .frontmostApplication,
                    targetChanged: false,
                    previousEvidence: evidence,
                    newEvidence: ProfileTriggerSpaceEvidence(
                        frontmostBundleID: "com.example.chat",
                        spaceApps: [
                            "com.example.editor",
                            "com.example.chat",
                        ]
                    )
                )
        )
    }

    func testNewResidencyAlwaysDisablesGenericFallback() {
        XCTAssertFalse(
            ProfileTriggerSpaceEvidencePolicy
                .genericRulesAllowed(
                    currentlyAllowed: true,
                    purpose: .minute,
                    targetChanged: true,
                    previousEvidence: nil,
                    newEvidence: ProfileTriggerSpaceEvidence(
                        frontmostBundleID: nil,
                        spaceApps: []
                    )
                )
        )
    }

    func testStaleSpaceAssignmentProposalCannotAuthorizeAnotherDesktop() {
        let oldDesktop = identity("DISPLAY-A", "OLD")
        let newDesktop = identity("DISPLAY-A", "NEW")

        XCTAssertFalse(
            CurrentSpaceAssignmentAuthorizationPolicy
                .permitsCommit(
                    proposedIdentity: oldDesktop,
                    proposedOwnerProfileID: nil,
                    freshlyObservedIdentity: newDesktop,
                    currentOwnerProfileID: nil
                )
        )
    }

    func testSpaceAssignmentProposalFailsIfOwnerChangedDuringReview() {
        let desktop = identity("DISPLAY-A", "MUSIC")

        XCTAssertFalse(
            CurrentSpaceAssignmentAuthorizationPolicy
                .permitsCommit(
                    proposedIdentity: desktop,
                    proposedOwnerProfileID: "old-owner",
                    freshlyObservedIdentity: desktop,
                    currentOwnerProfileID: "other-owner"
                )
        )
        XCTAssertTrue(
            CurrentSpaceAssignmentAuthorizationPolicy
                .permitsCommit(
                    proposedIdentity: desktop,
                    proposedOwnerProfileID: "old-owner",
                    freshlyObservedIdentity: desktop,
                    currentOwnerProfileID: "old-owner"
                )
        )
    }

    func testAssignmentEditsCannotImmediatelySwitchVisibleProfile() throws {
        let source = try profileTriggerEngineSource()

        XCTAssertFalse(
            source.contains(
                ".publisher(for: .profileSpaceAssignmentsDidChange)"
            )
        )
        let bestMatchStart = try XCTUnwrap(
            source.range(of: "    private func bestMatch()")
        )
        let currentRunStart = try XCTUnwrap(
            source.range(
                of: "    private func isCurrentRun(",
                range: bestMatchStart.upperBound..<source.endIndex
            )
        )
        let bestMatchBody = source[
            bestMatchStart.lowerBound..<currentRunStart.lowerBound
        ]
        XCTAssertTrue(
            bestMatchBody.contains(
                "residencyState.evaluationState("
            )
        )
        XCTAssertFalse(
            bestMatchBody.contains(
                "profileService.profileIDAssigned("
            )
        )
    }

    func testAppAndMinuteSignalsReconcileBeforeEvaluation() throws {
        let source = try profileTriggerEngineSource()
        let frontmostStart = try XCTUnwrap(
            source.range(of: "private func observeFrontmostApp")
        )
        let lifecycleStart = try XCTUnwrap(
            source.range(
                of: "private func observeSpaceLifecycle",
                range: frontmostStart.upperBound..<source.endIndex
            )
        )
        let frontmostBody = source[
            frontmostStart.lowerBound..<lifecycleStart.lowerBound
        ]
        XCTAssertTrue(
            frontmostBody.contains(
                "self.handleAutomationSignal("
            )
        )
        XCTAssertFalse(
            frontmostBody.contains(
                "self.evaluate(reason: \"frontmostApplication\")"
            )
        )
        XCTAssertFalse(frontmostBody.contains("notification.userInfo"))
        XCTAssertFalse(
            frontmostBody.contains(
                "NSWorkspace.applicationUserInfoKey"
            )
        )

        let minuteStart = try XCTUnwrap(
            source.range(of: "private func tickMinute")
        )
        let evaluateStart = try XCTUnwrap(
            source.range(
                of: "private func evaluate",
                range: minuteStart.upperBound..<source.endIndex
            )
        )
        let minuteBody = source[
            minuteStart.lowerBound..<evaluateStart.lowerBound
        ]
        XCTAssertTrue(
            minuteBody.contains(
                "handleAutomationSignal("
            )
        )
        XCTAssertFalse(
            minuteBody.contains(
                "evaluate(reason:"
            )
        )
    }

    func testEngineCoalescesPendingIntentAcrossCallbackOrder() throws {
        let source = try profileTriggerEngineSource()

        XCTAssertTrue(
            source.contains(
                "private var pendingSamplingEpoch ="
            )
        )
        XCTAssertTrue(
            source.contains(
                "pendingSamplingEpoch.record(purpose)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "purpose: effectivePurpose"
            )
        )
        XCTAssertTrue(
            source.contains(
                "lastCommittedEvidence = evidence\n            pendingSamplingEpoch.consumeAutomation()"
            )
        )
        XCTAssertTrue(
            source.contains(
                "targetChanged: effectiveTargetChanged"
            )
        )
    }

    func testFreshAssignmentReconciliationOwnsWatchdogWindow() throws {
        let source = try profileTriggerEngineSource()
        XCTAssertTrue(
            source.contains(
                "private var freshReconciliationGate ="
            )
        )
        XCTAssertTrue(
            source.contains(
                "!self.freshReconciliationGate.isInProgress"
            )
        )
        XCTAssertTrue(
            source.contains(
                "purpose: .assignmentVerification"
            )
        )
        XCTAssertTrue(
            source.contains(
                "recordPendingPurpose: false"
            )
        )
        XCTAssertTrue(
            source.contains(
                "verificationToken: verificationToken"
            )
        )
        XCTAssertTrue(
            source.contains(
                "pendingSamplingEpoch.crossedTarget\n                        || spaceTransitionPending"
            )
        )
        XCTAssertTrue(
            source.contains(
                "guard effectivePurpose.shouldEvaluateAutomation else"
            )
        )
        XCTAssertTrue(
            source.contains(
                "automationSignalDeferral.receive("
            )
        )
        XCTAssertTrue(
            source.contains(
                "finishFreshReconciliation("
            )
        )
    }

    func testEnginePublishesOnlyBracketedLiveEvidence() throws {
        let source = try profileTriggerEngineSource()
        XCTAssertTrue(source.contains("let frontmostBefore ="))
        XCTAssertTrue(source.contains("let frontmostAfter ="))
        XCTAssertTrue(source.contains("let postQuerySnapshot ="))
        XCTAssertTrue(
            source.contains(
                "ProfileTriggerSpaceEvidencePolicy.validated("
            )
        )
        XCTAssertTrue(
            source.contains(
                "manualOverride.recordUnbound("
            )
        )
    }

    func testPersistedAssignedSpaceCanUseImmediateActivationLane() {
        let destination = snapshot(
            "DISPLAY-A",
            "WORK",
            spaceID: 42
        )
        let durableAssignment =
            ProfileDurableSpaceAssignmentState(
                profileID: "work",
                currentOwnerMatchesDurable: true,
                targetProfileMatchesDurable: true,
                persistenceIsAuthoritative: true,
                currentRevision: 7,
                durableRevision: 7
            )

        XCTAssertEqual(
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: destination,
                purpose: .topology,
                targetChanged: true,
                durableAssignment: durableAssignment,
                availableProfileIDs: ["work", "personal"],
                verificationInProgress: false,
                manualOverrideAllowsTransition: true
            ),
            "work"
        )
        XCTAssertEqual(
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: destination,
                purpose: .startup,
                targetChanged: true,
                durableAssignment: durableAssignment,
                availableProfileIDs: ["work"],
                verificationInProgress: false,
                manualOverrideAllowsTransition: true
            ),
            "work"
        )
    }

    func testUnassignedOrNonauthoritativeSpaceCannotUseImmediateLane() {
        let destination = snapshot(
            "DISPLAY-A",
            "NEW",
            spaceID: 43
        )

        for assignment in [
            ProfileDurableSpaceAssignmentState(
                profileID: nil,
                currentOwnerMatchesDurable: true,
                targetProfileMatchesDurable: false,
                persistenceIsAuthoritative: true,
                currentRevision: 7,
                durableRevision: 7
            ),
            ProfileDurableSpaceAssignmentState(
                profileID: "work",
                currentOwnerMatchesDurable: false,
                targetProfileMatchesDurable: true,
                persistenceIsAuthoritative: true,
                currentRevision: 8,
                durableRevision: 7
            ),
            ProfileDurableSpaceAssignmentState(
                profileID: "work",
                currentOwnerMatchesDurable: true,
                targetProfileMatchesDurable: false,
                persistenceIsAuthoritative: true,
                currentRevision: 8,
                durableRevision: 7
            ),
            ProfileDurableSpaceAssignmentState(
                profileID: "work",
                currentOwnerMatchesDurable: true,
                targetProfileMatchesDurable: true,
                persistenceIsAuthoritative: false,
                currentRevision: 7,
                durableRevision: 7
            ),
        ] {
            XCTAssertNil(
                ProfileAssignedSpaceFastActivationPolicy.profileID(
                    snapshot: destination,
                    purpose: .topology,
                    targetChanged: true,
                    durableAssignment: assignment,
                    availableProfileIDs: ["work"],
                    verificationInProgress: false,
                    manualOverrideAllowsTransition: true
                )
            )
        }
    }

    func testUnrelatedPendingRevisionDoesNotDelayImmediateLane() {
        let destination = snapshot(
            "DISPLAY-A",
            "WORK",
            spaceID: 42
        )
        let durableAssignment =
            ProfileDurableSpaceAssignmentState(
                profileID: "work",
                currentOwnerMatchesDurable: true,
                targetProfileMatchesDurable: true,
                persistenceIsAuthoritative: true,
                currentRevision: 8,
                durableRevision: 7
            )

        XCTAssertEqual(
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: destination,
                purpose: .topology,
                targetChanged: true,
                durableAssignment: durableAssignment,
                availableProfileIDs: ["work"],
                verificationInProgress: false,
                manualOverrideAllowsTransition: true
            ),
            "work"
        )
    }

    func testIncompleteOrNonassignableSpaceCannotUseImmediateLane() {
        let durableAssignment =
            ProfileDurableSpaceAssignmentState(
                profileID: "work",
                currentOwnerMatchesDurable: true,
                targetProfileMatchesDurable: true,
                persistenceIsAuthoritative: true,
                currentRevision: 7,
                durableRevision: 7
            )
        let candidates = [
            ActiveSpaceSnapshot(
                spaceID: 0,
                identity: identity("DISPLAY-A", "WORK"),
                rawType: 0
            ),
            ActiveSpaceSnapshot(
                spaceID: 42,
                identity: identity("DISPLAY-A", "WORK"),
                rawType: 0,
                isAnimating: true
            ),
            ActiveSpaceSnapshot(
                spaceID: 42,
                identity: nil,
                rawType: 0
            ),
            ActiveSpaceSnapshot(
                spaceID: 42,
                identity: identity("DISPLAY-A", "WORK"),
                rawType: 4
            ),
            ActiveSpaceSnapshot(
                spaceID: 42,
                identity: identity("DISPLAY-A", "WORK"),
                rawType: nil
            ),
        ]

        for candidate in candidates {
            XCTAssertNil(
                ProfileAssignedSpaceFastActivationPolicy.profileID(
                    snapshot: candidate,
                    purpose: .topology,
                    targetChanged: true,
                    durableAssignment: durableAssignment,
                    availableProfileIDs: ["work"],
                    verificationInProgress: false,
                    manualOverrideAllowsTransition: true
                )
            )
        }
    }

    func testImmediateLaneRejectsObservationOnlyPurposesAndConflicts() {
        let destination = snapshot(
            "DISPLAY-A",
            "WORK",
            spaceID: 42
        )
        let durableAssignment =
            ProfileDurableSpaceAssignmentState(
                profileID: "work",
                currentOwnerMatchesDurable: true,
                targetProfileMatchesDurable: true,
                persistenceIsAuthoritative: true,
                currentRevision: 7,
                durableRevision: 7
            )

        for purpose in [
            ProfileTriggerSamplingPurpose.assignmentVerification,
            .manualBinding,
        ] {
            XCTAssertNil(
                ProfileAssignedSpaceFastActivationPolicy.profileID(
                    snapshot: destination,
                    purpose: purpose,
                    targetChanged: true,
                    durableAssignment: durableAssignment,
                    availableProfileIDs: ["work"],
                    verificationInProgress: false,
                    manualOverrideAllowsTransition: true
                )
            )
        }

        for purpose in [
            ProfileTriggerSamplingPurpose.frontmostApplication,
            .minute,
        ] {
            XCTAssertEqual(
                ProfileAssignedSpaceFastActivationPolicy.profileID(
                    snapshot: destination,
                    purpose: purpose,
                    targetChanged: true,
                    durableAssignment: durableAssignment,
                    availableProfileIDs: ["work"],
                    verificationInProgress: false,
                    manualOverrideAllowsTransition: true
                ),
                "work",
                "Any automation sampler that discovers a crossing must restore exact ownership immediately."
            )
        }

        XCTAssertNil(
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: destination,
                purpose: .topology,
                targetChanged: false,
                durableAssignment: durableAssignment,
                availableProfileIDs: ["work"],
                verificationInProgress: false,
                manualOverrideAllowsTransition: true
            )
        )
        XCTAssertNil(
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: destination,
                purpose: .topology,
                targetChanged: true,
                durableAssignment: durableAssignment,
                availableProfileIDs: ["work"],
                verificationInProgress: true,
                manualOverrideAllowsTransition: true
            )
        )
        XCTAssertNil(
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: destination,
                purpose: .topology,
                targetChanged: true,
                durableAssignment: durableAssignment,
                availableProfileIDs: ["work"],
                verificationInProgress: false,
                manualOverrideAllowsTransition: false
            )
        )
        XCTAssertNil(
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: destination,
                purpose: .topology,
                targetChanged: true,
                durableAssignment: durableAssignment,
                availableProfileIDs: ["deleted-profile"],
                verificationInProgress: false,
                manualOverrideAllowsTransition: true
            )
        )
    }

    func testEveryFastActivationBranchRejectsObservationOnlySampling() {
        for purpose in [
            ProfileTriggerSamplingPurpose.assignmentVerification,
            .manualBinding,
        ] {
            XCTAssertFalse(
                ProfileFastSpaceActivationAttemptPolicy.allowsAttempt(
                    purpose: purpose,
                    verificationInProgress: false
                ),
                "A bound manual override must not reactivate during an observation-only sample."
            )
        }

        for purpose in [
            ProfileTriggerSamplingPurpose.startup,
            .topology,
            .frontmostApplication,
            .minute,
        ] {
            XCTAssertTrue(
                ProfileFastSpaceActivationAttemptPolicy.allowsAttempt(
                    purpose: purpose,
                    verificationInProgress: false
                )
            )
            XCTAssertFalse(
                ProfileFastSpaceActivationAttemptPolicy.allowsAttempt(
                    purpose: purpose,
                    verificationInProgress: true
                ),
                "Fresh assignment verification must block both assigned and manual fast activation."
            )
        }
    }

    func testBoundManualOverrideAllowsDifferentAssignedDestination() {
        let origin = snapshot(
            "DISPLAY-A",
            "ORIGIN",
            spaceID: 41
        )
        let destination = snapshot(
            "DISPLAY-A",
            "DESTINATION",
            spaceID: 42
        )
        var override = ProfileManualOverrideState()
        override.record(
            profileID: "personal",
            observedTarget: origin
        )

        XCTAssertFalse(override.allowsFastTransition(to: origin))
        XCTAssertTrue(
            override.allowsFastTransition(to: destination)
        )
    }

    func testFastRoundTripRestoresManualProfileOnItsOrigin() {
        let origin = snapshot(
            "DISPLAY-A",
            "ORIGIN",
            spaceID: 41
        )
        let destination = snapshot(
            "DISPLAY-A",
            "DESTINATION",
            spaceID: 42
        )
        var override = ProfileManualOverrideState()
        override.record(
            profileID: "manual-profile",
            observedTarget: origin
        )

        XCTAssertEqual(
            override.fastReactivationProfileID(on: origin),
            "manual-profile"
        )
        XCTAssertNil(
            override.fastReactivationProfileID(
                on: destination
            )
        )

        override.recordUnbound(profileID: "new-intent")
        XCTAssertNil(
            override.fastReactivationProfileID(on: origin)
        )
    }

    func testUnboundManualOverrideBlocksImmediateActivation() {
        var override = ProfileManualOverrideState()
        override.recordUnbound(profileID: "personal")

        XCTAssertFalse(
            override.allowsFastTransition(
                to: snapshot(
                    "DISPLAY-A",
                    "DESTINATION",
                    spaceID: 42
                )
            )
        )
    }

    func testFastArrivalStateHandlesRoundTripInsideSettlementWindow() {
        let first = snapshot(
            "DISPLAY-A",
            "FIRST",
            spaceID: 41
        )
        let second = snapshot(
            "DISPLAY-A",
            "SECOND",
            spaceID: 42
        )
        var state = ProfileFastSpaceArrivalState()

        XCTAssertTrue(state.observe(first))
        state.markActivationSucceeded(for: first)
        XCTAssertFalse(state.observe(first))
        XCTAssertTrue(state.observe(second))
        state.markActivationSucceeded(for: second)
        XCTAssertFalse(state.observe(second))
        XCTAssertTrue(
            state.observe(first),
            "Returning before background settlement must still be a crossing."
        )
    }

    func testInvalidFastArrivalCannotEraseLastCoherentTarget() {
        let first = snapshot(
            "DISPLAY-A",
            "FIRST",
            spaceID: 41
        )
        let animatingSecond = ActiveSpaceSnapshot(
            spaceID: 42,
            identity: identity("DISPLAY-A", "SECOND"),
            rawType: 0,
            isAnimating: true,
            displayIdentifier: "DISPLAY-A",
            displayOrdinal: 2
        )
        var state = ProfileFastSpaceArrivalState()

        XCTAssertTrue(state.observe(first))
        state.markActivationSucceeded(for: first)
        XCTAssertFalse(state.observe(animatingSecond))
        XCTAssertFalse(state.observe(first))
    }

    func testIncompleteArrivalRemainsEligibleWhenPersistentNameResolves() {
        let unresolved = ActiveSpaceSnapshot(
            spaceID: 42,
            identity: nil,
            rawType: 0,
            displayIdentifier: "DISPLAY-A"
        )
        let resolved = snapshot(
            "DISPLAY-A",
            "WORK",
            spaceID: 42
        )
        var state = ProfileFastSpaceArrivalState()

        state.beginArrival()
        XCTAssertTrue(state.observe(unresolved))
        XCTAssertTrue(
            state.observe(resolved),
            "An identity-less first read must not consume the fast arrival."
        )
        state.markActivationSucceeded(for: resolved)
        XCTAssertFalse(state.observe(resolved))
    }

    func testLifecycleSignalReopensSameTargetForSafeRetry() {
        let destination = snapshot(
            "DISPLAY-A",
            "WORK",
            spaceID: 42
        )
        var state = ProfileFastSpaceArrivalState()

        XCTAssertTrue(state.observe(destination))
        state.markActivationSucceeded(for: destination)
        XCTAssertFalse(state.observe(destination))
        state.beginArrival()
        XCTAssertTrue(state.observe(destination))
    }

    func testAssignedFastPathRunsBeforeBackgroundSettlementAndEvidence()
        throws {
        let source = try profileTriggerEngineSource()
        let lifecycleStart = try XCTUnwrap(
            source.range(of: "private func observeSpaceLifecycle")
        )
        let targetChangesStart = try XCTUnwrap(
            source.range(
                of: "private func observeDockTargetChanges",
                range: lifecycleStart.upperBound..<source.endIndex
            )
        )
        let lifecycleBody = source[
            lifecycleStart.lowerBound..<targetChangesStart.lowerBound
        ]
        let fastActivation = try XCTUnwrap(
            lifecycleBody.range(
                of:
                    "activateDurablyAssignedSpaceImmediately("
            )
        )
        let invalidation = try XCTUnwrap(
            lifecycleBody.range(of: "self.invalidateSpace(")
        )
        XCTAssertLessThan(
            fastActivation.lowerBound,
            invalidation.lowerBound
        )

        let sampleStart = try XCTUnwrap(
            source.range(of: "private func sampleSpace(")
        )
        let evidenceStart = try XCTUnwrap(
            source.range(
                of: "let snapshot = activeSpaceSnapshot(",
                range: sampleStart.upperBound..<source.endIndex
            )
        )
        let earlyRetry = try XCTUnwrap(
            source.range(
                of:
                    "activateDurablyAssignedSpaceImmediately(",
                range:
                    sampleStart.upperBound..<evidenceStart.lowerBound
            )
        )
        XCTAssertLessThan(
            earlyRetry.lowerBound,
            evidenceStart.lowerBound
        )
        XCTAssertTrue(source.contains("16_000_000"))
        XCTAssertTrue(source.contains("34_000_000"))
        XCTAssertTrue(source.contains("50_000_000"))

        let helperStart = try XCTUnwrap(
            source.range(
                of:
                    "private func activateDurablyAssignedSpaceImmediately("
            )
        )
        let helperEnd = try XCTUnwrap(
            source.range(
                of: "private func finishFreshReconciliation(",
                range: helperStart.upperBound..<source.endIndex
            )
        )
        let helperBody = source[
            helperStart.lowerBound..<helperEnd.lowerBound
        ]
        XCTAssertFalse(
            helperBody.contains(
                "manualOverride.reconcileCommittedTarget("
            ),
            "An uncommitted fast observation must not clear manual intent."
        )

        let assignedBranch = try XCTUnwrap(
            source.range(of: "if case .assigned =")
        )
        let evidenceRead = try XCTUnwrap(
            source.range(
                of: "let previousEvidence = lastCommittedEvidence",
                range: assignedBranch.upperBound..<source.endIndex
            )
        )
        XCTAssertLessThan(
            assignedBranch.lowerBound,
            evidenceRead.lowerBound
        )
    }

    private func context(
        frontmost: String? = nil,
        spaceApps: Set<String> = [],
        state: ProfileSpaceAssignmentEvaluationState =
            .unassignedRegular,
        allowsGenericRules: Bool = false
    ) -> ProfileTriggerEvaluationContext {
        ProfileTriggerEvaluationContext(
            now: Date(timeIntervalSince1970: 1_000),
            frontmostBundleID: frontmost,
            spaceApps: spaceApps,
            spaceAssignmentState: state,
            allowsGenericRulesOnUnassignedRegular:
                allowsGenericRules
        )
    }

    private func evaluationProfile(
        _ id: String,
        triggers: [ProfileTrigger]
    ) -> ProfileTriggerEvaluationProfile {
        ProfileTriggerEvaluationProfile(
            id: id,
            dateCreated: Date(timeIntervalSince1970: 1),
            triggers: triggers
        )
    }

    private func applySimulatedSystemDockSync(
        credentials: ProfileMutationCredentials,
        activeProfileID: String,
        currentRevision: UInt64,
        importedBundleIdentifiers: [String],
        marksInitialImportComplete: Bool,
        layouts: inout [String: [String]],
        importComplete: inout Bool
    ) -> Bool {
        guard credentials.validation(
            activeProfileID: activeProfileID,
            currentRevision: currentRevision
        ) == .current else {
            return false
        }
        guard var layout =
            layouts[credentials.profileID] else {
            return false
        }
        for bundleIdentifier
            in importedBundleIdentifiers
            where !layout.contains(bundleIdentifier) {
            layout.append(bundleIdentifier)
        }
        layouts[credentials.profileID] = layout
        if marksInitialImportComplete {
            importComplete = true
        }
        return true
    }

    private func identity(
        _ display: String,
        _ space: String
    ) -> MissionControlSpaceIdentity {
        MissionControlSpaceIdentity(
            displayUUID: display,
            spaceUUID: space
        )!
    }

    private func snapshot(
        _ display: String,
        _ space: String,
        spaceID: UInt64
    ) -> ActiveSpaceSnapshot {
        ActiveSpaceSnapshot(
            spaceID: spaceID,
            identity: identity(display, space),
            rawType: 0,
            displayIdentifier: display,
            displayOrdinal: 1
        )
    }

    private func profileTriggerEngineSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Docky/Services/ProfileTriggerEngine.swift"
            )
        return try String(contentsOf: sourceURL)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
