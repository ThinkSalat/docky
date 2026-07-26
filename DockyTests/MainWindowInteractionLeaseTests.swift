import XCTest

final class MainWindowInteractionLeaseTests: XCTestCase {
    func testExplicitInvalidationReleasesExactlyOnce() {
        var releasedIDs: [UUID] = []
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let lease = MainWindowInteractionLease(
            id: id,
            onRelease: { releasedIDs.append($0) }
        )

        lease.invalidate()
        lease.invalidate()

        XCTAssertEqual(releasedIDs, [id])
        XCTAssertFalse(lease.isActive)
    }

    func testDeinitializationReleasesExactlyOnce() {
        var releasedIDs: [UUID] = []
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var lease: MainWindowInteractionLease? = MainWindowInteractionLease(
            id: id,
            onRelease: { releasedIDs.append($0) }
        )

        XCTAssertNotNil(lease)
        lease = nil

        XCTAssertEqual(releasedIDs, [id])
    }

    func testOwnerCanMakeOutstandingLeaseInert() {
        var ownerContainsLease = true
        var releaseCount = 0
        let lease = MainWindowInteractionLease(
            onRelease: { _ in releaseCount += 1 },
            isActive: { ownerContainsLease }
        )

        XCTAssertTrue(lease.isActive)
        ownerContainsLease = false
        XCTAssertFalse(lease.isActive)

        lease.invalidate()
        XCTAssertEqual(releaseCount, 1)
    }
}
