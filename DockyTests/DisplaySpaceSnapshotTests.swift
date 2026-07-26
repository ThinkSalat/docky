import XCTest

final class DisplaySpaceSnapshotTests: XCTestCase {
    func testResolvesTargetDisplayByUUIDInsteadOfRecordOrder() {
        let records = [
            ManagedDisplaySpaceRecord(
                displayIdentifier: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                spaceID: 11,
                rawType: 0
            ),
            ManagedDisplaySpaceRecord(
                displayIdentifier: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                spaceID: 22,
                rawType: 4
            ),
        ]

        let result = DisplaySpaceSnapshotResolver.resolve(
            records: records,
            targetDisplayUUID: "{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}",
            targetIsMainDisplay: false
        )

        XCTAssertEqual(
            result,
            ActiveSpaceSnapshot(spaceID: 22, rawType: 4)
        )
        XCTAssertEqual(result?.isFullscreen, true)
    }

    func testUsesMainSentinelForMainDisplay() {
        let records = [
            ManagedDisplaySpaceRecord(
                displayIdentifier: "Main",
                spaceID: 31,
                rawType: 0
            ),
            ManagedDisplaySpaceRecord(
                displayIdentifier: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                spaceID: 32,
                rawType: 4
            ),
        ]

        let result = DisplaySpaceSnapshotResolver.resolve(
            records: records,
            targetDisplayUUID: "UNMATCHED",
            targetIsMainDisplay: true
        )

        XCTAssertEqual(result?.spaceID, 31)
        XCTAssertEqual(result?.isFullscreen, false)
    }

    func testSingleManagedDisplayIsAnUnambiguousFallback() {
        let result = DisplaySpaceSnapshotResolver.resolve(
            records: [
                ManagedDisplaySpaceRecord(
                    displayIdentifier: "UNKNOWN-FORMAT",
                    spaceID: 41,
                    rawType: 4
                ),
            ],
            targetDisplayUUID: nil,
            targetIsMainDisplay: false
        )

        XCTAssertEqual(result?.spaceID, 41)
        XCTAssertEqual(result?.isFullscreen, true)
    }

    func testUnmatchedMultiDisplayStateFailsClosed() {
        let records = [
            ManagedDisplaySpaceRecord(
                displayIdentifier: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                spaceID: 51,
                rawType: 4
            ),
            ManagedDisplaySpaceRecord(
                displayIdentifier: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                spaceID: 52,
                rawType: 0
            ),
        ]

        XCTAssertNil(
            DisplaySpaceSnapshotResolver.resolve(
                records: records,
                targetDisplayUUID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
                targetIsMainDisplay: false
            )
        )
    }

    func testUnknownSpaceTypeRemainsUnknown() {
        let snapshot = ActiveSpaceSnapshot(spaceID: 61, rawType: 99)

        XCTAssertNil(snapshot.isFullscreen)
    }
}
