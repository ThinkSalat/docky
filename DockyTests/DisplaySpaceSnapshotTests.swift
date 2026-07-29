import Foundation
import XCTest

final class DisplaySpaceSnapshotTests: XCTestCase {
    func testSeparateSpacesRequiresExactPhysicalDisplayMatch() {
        let records = [
            record("DISPLAY-A", id: 11, uuid: "SPACE-A"),
            record("DISPLAY-B", id: 22, uuid: "SPACE-B"),
        ]

        let result = DisplaySpaceSnapshotResolver.resolve(
            records: records,
            targetDisplayUUID: "{display-b}",
            spacesHaveSeparateSpaces: true
        )

        XCTAssertEqual(result?.spaceID, 22)
        XCTAssertEqual(
            result?.identity,
            identity("IGNORED-DISPLAY", "SPACE-B")
        )
    }

    func testSeparateSpacesNeverUsesSingleRecordFallback() {
        XCTAssertNil(
            DisplaySpaceSnapshotResolver.resolve(
                records: [
                    record("UNKNOWN", id: 41, uuid: "SPACE-A"),
                ],
                targetDisplayUUID: "DISPLAY-A",
                spacesHaveSeparateSpaces: true
            )
        )
    }

    func testSeparateSpacesRejectsDuplicateTargetRecords() {
        XCTAssertNil(
            DisplaySpaceSnapshotResolver.resolve(
                records: [
                    record("DISPLAY-A", id: 41, uuid: "SPACE-A"),
                    record("display-a", id: 42, uuid: "SPACE-B"),
                ],
                targetDisplayUUID: "{DISPLAY-A}",
                spacesHaveSeparateSpaces: true
            )
        )
    }

    func testSharedSpacesRequiresMainSentinel() {
        let records = [
            record("DISPLAY-A", id: 30, uuid: "WRONG"),
            record("Main", id: 31, uuid: ""),
        ]

        let result = DisplaySpaceSnapshotResolver.resolve(
            records: records,
            targetDisplayUUID: "DISPLAY-A",
            spacesHaveSeparateSpaces: false
        )

        XCTAssertEqual(result?.spaceID, 31)
        XCTAssertEqual(
            result?.identity,
            identity(
                MissionControlSpaceIdentity.sharedDisplayScope,
                ""
            )
        )
    }

    func testSharedSpacesFailsClosedWithoutMainSentinel() {
        XCTAssertNil(
            DisplaySpaceSnapshotResolver.resolve(
                records: [
                    record("DISPLAY-A", id: 31, uuid: ""),
                ],
                targetDisplayUUID: "DISPLAY-A",
                spacesHaveSeparateSpaces: false
            )
        )
    }

    func testSharedSpacesRejectsDuplicateMainRecords() {
        XCTAssertNil(
            DisplaySpaceSnapshotResolver.resolve(
                records: [
                    record("Main", id: 31, uuid: ""),
                    record("main", id: 32, uuid: "SPACE-A"),
                ],
                targetDisplayUUID: "DISPLAY-A",
                spacesHaveSeparateSpaces: false
            )
        )
    }

    func testRawTargetSelectionFindsOneExactPhysicalDisplay() {
        let selection = ManagedDisplayTargetSelectionPolicy.select(
            displayIdentifiers: [
                "DISPLAY-A",
                "{display-b}",
            ],
            targetDisplayUUID: "DISPLAY-B",
            spacesHaveSeparateSpaces: true
        )

        XCTAssertEqual(selection?.index, 1)
        XCTAssertEqual(selection?.identityDisplayScope, "display-b")
    }

    func testRawTargetSelectionRejectsDuplicateBeforeRecordParsing() {
        XCTAssertNil(
            ManagedDisplayTargetSelectionPolicy.select(
                displayIdentifiers: [
                    "DISPLAY-A",
                    "{display-a}",
                ],
                targetDisplayUUID: "DISPLAY-A",
                spacesHaveSeparateSpaces: true
            )
        )
    }

    func testRawTargetSelectionRejectsMissingPhysicalDisplay() {
        XCTAssertNil(
            ManagedDisplayTargetSelectionPolicy.select(
                displayIdentifiers: [
                    nil,
                    "DISPLAY-B",
                ],
                targetDisplayUUID: "DISPLAY-A",
                spacesHaveSeparateSpaces: true
            )
        )
    }

    func testRawTargetSelectionUsesUniqueMainInSharedMode() {
        let selection = ManagedDisplayTargetSelectionPolicy.select(
            displayIdentifiers: [
                "DISPLAY-A",
                "Main",
            ],
            targetDisplayUUID: nil,
            spacesHaveSeparateSpaces: false
        )

        XCTAssertEqual(selection?.index, 1)
        XCTAssertEqual(
            selection?.identityDisplayScope,
            MissionControlSpaceIdentity.sharedDisplayScope
        )
        XCTAssertNil(
            ManagedDisplayTargetSelectionPolicy.select(
                displayIdentifiers: [
                    "Main",
                    "main",
                ],
                targetDisplayUUID: nil,
                spacesHaveSeparateSpaces: false
            )
        )
    }

    func testNamedSpaceIdentitySurvivesDisplayMoveAndNumericIDChange() {
        let before = identity("DISPLAY-A", "PERSISTENT-SPACE")
        let after = identity("DISPLAY-B", "PERSISTENT-SPACE")

        XCTAssertEqual(before, after)
        XCTAssertEqual(before.storageKey, "space:persistent-space")
    }

    func testRootDesktopIsScopedPerPhysicalDisplay() {
        let first = identity("DISPLAY-A", "")
        let second = identity("DISPLAY-B", "")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.storageKey, "root:display-a")
    }

    func testIdentityDecoderRejectsUnscopedEmptyRoot() throws {
        let data = try XCTUnwrap(
            #"{"spaceUUID":""}"#.data(using: .utf8)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MissionControlSpaceIdentity.self,
                from: data
            )
        )
    }

    func testManagedDisplayParserRequiresCurrentSpace() {
        XCTAssertNil(
            ManagedDisplaySpaceRecordParser.parse(
                displayIdentifier: "DISPLAY-A",
                currentSpace: nil,
                listedSpaces: [
                    observed(id: 41, uuid: "COLLAPSED", type: 0),
                ],
                copiedSpaceName: nil,
                isAnimating: false
            )
        )
    }

    func testManagedDisplayParserRequiresExactlyOneCurrentMembership() {
        let current = observed(id: 41, uuid: "SPACE-A", type: 0)

        XCTAssertNil(
            ManagedDisplaySpaceRecordParser.parse(
                displayIdentifier: "DISPLAY-A",
                currentSpace: current,
                listedSpaces: [
                    observed(id: 42, uuid: "SPACE-B", type: 0),
                ],
                copiedSpaceName: nil,
                isAnimating: false
            )
        )
        XCTAssertNil(
            ManagedDisplaySpaceRecordParser.parse(
                displayIdentifier: "DISPLAY-A",
                currentSpace: current,
                listedSpaces: [current, current],
                copiedSpaceName: nil,
                isAnimating: false
            )
        )
    }

    func testManagedDisplayParserRejectsLossyRawSpacesConversion() {
        let current = observed(id: 41, uuid: "SPACE-A", type: 0)

        XCTAssertNil(
            ManagedDisplaySpaceRecordParser.parse(
                displayIdentifier: "DISPLAY-A",
                currentSpace: current,
                listedSpaces: [current],
                rawListedSpaceCount: 2,
                copiedSpaceName: "SPACE-A",
                isAnimating: false
            )
        )
    }

    func testManagedDisplayParserCountsOnlyRegularDesktopOrdinals() {
        let listed = [
            observed(id: 1, uuid: "", type: 0),
            observed(id: 90, uuid: "FULLSCREEN", type: 4),
            observed(id: 41, uuid: "SPACE-A", type: 0),
        ]
        let regular = ManagedDisplaySpaceRecordParser.parse(
            displayIdentifier: "DISPLAY-A",
            currentSpace: observed(
                id: 41,
                uuid: "{SPACE-A}",
                type: 0
            ),
            listedSpaces: listed,
            copiedSpaceName: "space-a",
            isAnimating: false
        )
        let fullscreen = ManagedDisplaySpaceRecordParser.parse(
            displayIdentifier: "DISPLAY-A",
            currentSpace: observed(
                id: 90,
                uuid: "FULLSCREEN",
                type: 4
            ),
            listedSpaces: listed,
            copiedSpaceName: nil,
            isAnimating: false
        )

        XCTAssertEqual(regular?.ordinal, 2)
        XCTAssertEqual(regular?.spaceUUID, "space-a")
        XCTAssertNil(fullscreen?.ordinal)
    }

    func testManagedDisplayParserRejectsConflictingIdentityEvidence() {
        let listed = [
            observed(id: 41, uuid: "SPACE-A", type: 0),
        ]

        XCTAssertNil(
            ManagedDisplaySpaceRecordParser.parse(
                displayIdentifier: "DISPLAY-A",
                currentSpace: observed(
                    id: 41,
                    uuid: "SPACE-B",
                    type: 0
                ),
                listedSpaces: listed,
                copiedSpaceName: nil,
                isAnimating: false
            )
        )
        XCTAssertNil(
            ManagedDisplaySpaceRecordParser.parse(
                displayIdentifier: "DISPLAY-A",
                currentSpace: listed[0],
                listedSpaces: listed,
                copiedSpaceName: "",
                isAnimating: false
            )
        )
    }

    func testManagedDisplayParserAcceptsNormalizedIdentityAgreement() {
        let result = ManagedDisplaySpaceRecordParser.parse(
            displayIdentifier: "DISPLAY-A",
            currentSpace: observed(
                id: 41,
                uuid: "{SPACE-A}",
                type: 0
            ),
            listedSpaces: [
                observed(id: 41, uuid: "space-a", type: 0),
            ],
            copiedSpaceName: "SPACE-A",
            isAnimating: false
        )

        XCTAssertEqual(result?.spaceUUID, "SPACE-A")
    }

    func testManagedDisplayParserRejectsConflictingTypeEvidence() {
        XCTAssertNil(
            ManagedDisplaySpaceRecordParser.parse(
                displayIdentifier: "DISPLAY-A",
                currentSpace: observed(
                    id: 41,
                    uuid: "SPACE-A",
                    type: 0
                ),
                listedSpaces: [
                    observed(id: 41, uuid: "SPACE-A", type: 4),
                ],
                copiedSpaceName: "SPACE-A",
                isAnimating: false
            )
        )
    }

    func testCatalogLabelsOnlyRegularDesktopsAndKeepsIdentitySeparate() {
        let presentations =
            MissionControlSpaceCatalogPolicy.presentations(
                displayIdentifier: "{DISPLAY-A}",
                displayName: "Studio Display",
                listedSpaces: [
                    observed(id: 1, uuid: "", type: 0),
                    observed(
                        id: 90,
                        uuid: "FULLSCREEN",
                        type: 4
                    ),
                    observed(
                        id: 41,
                        uuid: "NAMED",
                        type: 0
                    ),
                ],
                spacesHaveSeparateSpaces: true
            )

        XCTAssertEqual(presentations.count, 2)
        XCTAssertEqual(presentations.map(\.ordinal), [1, 2])
        XCTAssertEqual(
            presentations.map(\.displayName),
            ["Studio Display", "Studio Display"]
        )
        XCTAssertEqual(
            presentations[0].identity.storageKey,
            "root:display-a"
        )
        XCTAssertEqual(
            presentations[1].identity.storageKey,
            "space:named"
        )
    }

    func testSharedCatalogCanonicalizesRootDesktop() {
        let presentations =
            MissionControlSpaceCatalogPolicy.presentations(
                displayIdentifier: "Main",
                displayName: "All displays",
                listedSpaces: [
                    observed(id: 1, uuid: "", type: 0),
                ],
                spacesHaveSeparateSpaces: false
            )

        XCTAssertEqual(
            presentations.first?.identity.storageKey,
            "root:shared"
        )
    }

    func testReconcilerRequiresThreeSamplesAcrossHalfSecond() {
        var reconciler =
            SpaceTransitionReconciler(
                quietInterval: 0.1,
                requiredSampleCount: 1
            )
        let snapshot = active(id: 413, uuid: "SPACE-A")

        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 10),
            .pending
        )
        XCTAssertNil(reconciler.settledSnapshot)
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 10.25),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 10.5),
            .committed(snapshot)
        )
    }

    func testReconcilerRejectsTransitionBounce() {
        var reconciler =
            SpaceTransitionReconciler()
        let first = active(id: 413, uuid: "SPACE-A")
        let intermediate = active(id: 1_651, uuid: "SPACE-B")

        XCTAssertEqual(
            reconciler.observe(first, atUptime: 20),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(intermediate, atUptime: 20.05),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(first, atUptime: 20.1),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(first, atUptime: 20.35),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(first, atUptime: 20.61),
            .committed(first)
        )
    }

    func testReconcilerNeverCommitsBriefStableIntermediate() {
        var reconciler = SpaceTransitionReconciler()
        let intermediate = active(id: 1_651, uuid: "SPACE-B")
        let final = active(id: 413, uuid: "SPACE-A")

        XCTAssertEqual(
            reconciler.observe(intermediate, atUptime: 0),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(intermediate, atUptime: 0.13),
            .pending
        )
        XCTAssertNil(reconciler.settledSnapshot)

        XCTAssertEqual(
            reconciler.observe(final, atUptime: 0.2),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(final, atUptime: 0.45),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(final, atUptime: 0.71),
            .committed(final)
        )
        XCTAssertEqual(reconciler.settledSnapshot, final)
    }

    func testAnimatingObservationInvalidatesSettledIdentity() {
        var reconciler = SpaceTransitionReconciler()
        let snapshot = active(id: 413, uuid: "SPACE-A")
        _ = reconciler.observe(snapshot, atUptime: 30)
        _ = reconciler.observe(snapshot, atUptime: 30.25)
        _ = reconciler.observe(snapshot, atUptime: 30.5)
        XCTAssertNotNil(reconciler.settledSnapshot)

        let animating = ActiveSpaceSnapshot(
            spaceID: 1_651,
            identity: identity("DISPLAY-A", "SPACE-B"),
            rawType: 0,
            isAnimating: true
        )
        XCTAssertEqual(
            reconciler.observe(animating, atUptime: 30.6),
            .pending
        )
        XCTAssertNil(reconciler.settledSnapshot)

        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 30.7),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 30.95),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 31.21),
            .committed(snapshot)
        )
    }

    func testMalformedObservationNeverReusesPreviousIdentity() {
        var reconciler = SpaceTransitionReconciler()
        let snapshot = active(id: 413, uuid: "SPACE-A")
        _ = reconciler.observe(snapshot, atUptime: 40)
        _ = reconciler.observe(snapshot, atUptime: 40.25)
        _ = reconciler.observe(snapshot, atUptime: 40.5)

        XCTAssertEqual(
            reconciler.observe(.unknown, atUptime: 40.6),
            .pending
        )
        XCTAssertNil(reconciler.settledSnapshot)
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 40.7),
            .pending
        )
    }

    func testUnavailableObservationNeverReusesPreviousIdentity() {
        var reconciler = SpaceTransitionReconciler()
        let snapshot = active(id: 413, uuid: "SPACE-A")
        _ = reconciler.observe(snapshot, atUptime: 50)
        _ = reconciler.observe(snapshot, atUptime: 50.25)
        _ = reconciler.observe(snapshot, atUptime: 50.5)

        XCTAssertEqual(
            reconciler.observe(nil, atUptime: 50.6),
            .pending
        )
        XCTAssertNil(reconciler.settledSnapshot)
    }

    func testExplicitInvalidationResetsCandidateEvidence() {
        var reconciler = SpaceTransitionReconciler()
        let snapshot = active(id: 413, uuid: "SPACE-A")
        _ = reconciler.observe(snapshot, atUptime: 60)
        _ = reconciler.observe(snapshot, atUptime: 60.25)

        reconciler.invalidate()

        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 60.5),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 60.75),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 61),
            .committed(snapshot)
        )
    }

    func testBackwardUptimeFailsClosedAndResetsEvidence() {
        var reconciler = SpaceTransitionReconciler()
        let snapshot = active(id: 413, uuid: "SPACE-A")
        _ = reconciler.observe(snapshot, atUptime: 70)
        _ = reconciler.observe(snapshot, atUptime: 70.25)

        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 70.1),
            .pending
        )
        XCTAssertNil(reconciler.settledSnapshot)
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 70.2),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 70.45),
            .pending
        )
        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 70.71),
            .committed(snapshot)
        )
    }

    func testEqualSettledObservationIsUnchanged() {
        var reconciler = SpaceTransitionReconciler()
        let snapshot = active(id: 413, uuid: "SPACE-A")
        _ = reconciler.observe(snapshot, atUptime: 80)
        _ = reconciler.observe(snapshot, atUptime: 80.25)
        _ = reconciler.observe(snapshot, atUptime: 80.5)

        XCTAssertEqual(
            reconciler.observe(snapshot, atUptime: 80.51),
            .unchanged
        )
        XCTAssertEqual(reconciler.settledSnapshot, snapshot)
    }

    func testFullscreenCanSettleButCannotBeAssigned() {
        let snapshot = ActiveSpaceSnapshot(
            spaceID: 99,
            identity: identity("DISPLAY-A", "FULLSCREEN"),
            rawType: 4
        )
        XCTAssertEqual(snapshot.isFullscreen, true)
        XCTAssertNil(snapshot.assignableIdentity)
    }

    private func record(
        _ display: String,
        id: UInt64,
        uuid: String
    ) -> ManagedDisplaySpaceRecord {
        ManagedDisplaySpaceRecord(
            displayIdentifier: display,
            spaceID: id,
            spaceUUID: uuid,
            rawType: 0
        )
    }

    private func active(
        id: UInt64,
        uuid: String
    ) -> ActiveSpaceSnapshot {
        ActiveSpaceSnapshot(
            spaceID: id,
            identity: identity("DISPLAY-A", uuid),
            rawType: 0,
            displayIdentifier: "DISPLAY-A"
        )
    }

    private func observed(
        id: UInt64,
        uuid: String?,
        type: Int32?
    ) -> ManagedDisplaySpaceObservation {
        ManagedDisplaySpaceObservation(
            spaceID: id,
            spaceUUID: uuid,
            rawType: type
        )
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
}
