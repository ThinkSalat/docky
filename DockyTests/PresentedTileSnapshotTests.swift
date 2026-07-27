import XCTest

final class PresentedTileSnapshotTests: XCTestCase {
    private struct Item: Equatable {
        let id: String
        let value: String
    }

    private let transientID = "handoff"
    private let trailingDividerID = "divider:trailing"

    func testNilTransientRemovesExistingTransient() {
        let items = [
            item("finder"),
            item("handoff"),
            item("divider:trailing"),
        ]

        let presented = applyingTransient(to: items, transient: nil)

        XCTAssertEqual(
            presented.map(\.id),
            ["finder", "divider:trailing"]
        )
    }

    func testTransientIsInsertedBeforeTrailingDivider() {
        let items = [
            item("finder"),
            item("app"),
            item("divider:trailing"),
            item("trash"),
        ]

        let presented = applyingTransient(
            to: items,
            transient: item("handoff")
        )

        XCTAssertEqual(
            presented.map(\.id),
            [
                "finder",
                "app",
                "handoff",
                "divider:trailing",
                "trash",
            ]
        )
    }

    func testExistingTransientIsReplaced() {
        let items = [
            item("finder"),
            item("handoff", value: "Firefox"),
            item("divider:trailing"),
        ]
        let replacement = item("handoff", value: "Safari")

        let presented = applyingTransient(
            to: items,
            transient: replacement
        )

        XCTAssertEqual(
            presented,
            [
                item("finder"),
                replacement,
                item("divider:trailing"),
            ]
        )
    }

    func testApplyingSameTransientIsIdempotentAndDoesNotDuplicateIt() {
        let baseItems = [
            item("finder"),
            item("divider:trailing"),
        ]
        let transient = item("handoff", value: "Firefox")
        let first = applyingTransient(
            to: baseItems,
            transient: transient
        )

        let second = applyingTransient(
            to: first,
            transient: transient
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(
            second.filter { $0.id == transientID }.count,
            1
        )
    }

    func testStaleTransientCopiesAreCollapsedAtCanonicalPosition() {
        let replacement = item("handoff", value: "Safari")
        let items = [
            item("handoff", value: "stale-leading"),
            item("finder"),
            item("divider:trailing"),
            item("handoff", value: "stale-trailing"),
            item("trash"),
        ]

        let presented = applyingTransient(
            to: items,
            transient: replacement
        )

        XCTAssertEqual(
            presented,
            [
                item("finder"),
                replacement,
                item("divider:trailing"),
                item("trash"),
            ]
        )
    }

    func testSnapshotRevisionAdvancesOnlyWhenItemsChange() {
        let original = PresentedTileSnapshot(
            items: [item("finder")],
            revision: 41
        )

        let unchanged = original.replacingItems([item("finder")])
        let changed = unchanged.replacingItems([
            item("finder"),
            item("app"),
        ])
        let unchangedAgain = changed.replacingItems([
            item("finder"),
            item("app"),
        ])

        XCTAssertEqual(unchanged.revision, 41)
        XCTAssertEqual(changed.revision, 42)
        XCTAssertEqual(unchangedAgain.revision, 42)
        XCTAssertEqual(unchangedAgain, changed)
    }

    func testAddingTileIncreasesExtentByTilePlusSpacingExactly() {
        let withoutTransient = PresentedTileAxisMetrics.extent(
            itemExtents: [64, 64],
            spacing: 5,
            edgePadding: 8
        )
        let withTransient = PresentedTileAxisMetrics.extent(
            itemExtents: [64, 64, 64],
            spacing: 5,
            edgePadding: 8
        )

        XCTAssertEqual(withTransient - withoutTransient, 69)
    }

    func testAddingTransientCrossesOverflowEdge() {
        let availableExtent: CGFloat = 217.5
        let withoutTransient = PresentedTileAxisMetrics.extent(
            itemExtents: [64, 64],
            spacing: 5,
            edgePadding: 8
        )
        let withTransient = PresentedTileAxisMetrics.extent(
            itemExtents: [64, 64, 64],
            spacing: 5,
            edgePadding: 8
        )

        XCTAssertLessThanOrEqual(withoutTransient, availableExtent)
        XCTAssertGreaterThan(withTransient, availableExtent)
    }

    func testDockPartitionMovesHandoffOutOfMainDockWithoutReorderingEitherSurface() {
        let items = [
            item("finder"),
            item("handoff", value: "Firefox"),
            item("app"),
            item("handoff", value: "Safari"),
            item("divider:trailing"),
            item("trash"),
        ]

        let partition = PresentedTileDockPartition.splitting(
            items,
            isHandoff: { $0.id == transientID }
        )

        XCTAssertEqual(
            partition.mainItems.map(\.id),
            [
                "finder",
                "app",
                "divider:trailing",
                "trash",
            ]
        )
        XCTAssertEqual(
            partition.handoffItems.map(\.value),
            ["Firefox", "Safari"]
        )
        XCTAssertEqual(
            partition.mainItems.count + partition.handoffItems.count,
            items.count
        )
    }

    func testInlineHandoffPresentationKeepsCanonicalOrderOnMainDock() {
        let items = [
            item("finder"),
            item("handoff", value: "Firefox"),
            item("divider:trailing"),
            item("trash"),
        ]

        let partition =
            PresentedTileDockPartition.presenting(
                items,
                separatesHandoff: false,
                isHandoff: {
                    $0.id == transientID
                }
            )

        XCTAssertEqual(partition.mainItems, items)
        XCTAssertTrue(partition.handoffItems.isEmpty)
    }

    func testSeparateHandoffPresentationSplitsCanonicalItems() {
        let items = [
            item("finder"),
            item("handoff", value: "Firefox"),
            item("divider:trailing"),
            item("trash"),
        ]

        let partition =
            PresentedTileDockPartition.presenting(
                items,
                separatesHandoff: true,
                isHandoff: {
                    $0.id == transientID
                }
            )

        XCTAssertEqual(
            partition.mainItems.map(\.id),
            [
                "finder",
                "divider:trailing",
                "trash",
            ]
        )
        XCTAssertEqual(
            partition.handoffItems,
            [item("handoff", value: "Firefox")]
        )
    }

    func testSeparateHandoffDockMeasuresBothCapsulesAndExactGap() {
        let layout = PresentedTileDockAxisMetrics.measure(
            mainItemExtents: [64, 64],
            handoffItemExtents: [64],
            itemSpacing: 5,
            mainEdgePadding: 8,
            handoffEdgePadding: 4,
            interDockGap: 10
        )

        XCTAssertEqual(layout.mainDockExtent, 149)
        XCTAssertEqual(layout.handoffDockExtent, 72)
        XCTAssertEqual(layout.interDockGap, 10)
        XCTAssertEqual(layout.totalExtent, 231)
    }

    func testAbsentHandoffDockAddsNeitherPaddingNorGap() {
        let layout = PresentedTileDockAxisMetrics.measure(
            mainItemExtents: [64, 64],
            handoffItemExtents: [],
            itemSpacing: 5,
            mainEdgePadding: 8,
            handoffEdgePadding: 4,
            interDockGap: 10
        )

        XCTAssertEqual(layout.mainDockExtent, 149)
        XCTAssertEqual(layout.handoffDockExtent, 0)
        XCTAssertEqual(layout.interDockGap, 0)
        XCTAssertEqual(layout.totalExtent, 149)
    }

    func testHandoffOnlyLayoutDoesNotReserveInterDockGap() {
        let layout = PresentedTileDockAxisMetrics.measure(
            mainItemExtents: [],
            handoffItemExtents: [64],
            itemSpacing: 5,
            mainEdgePadding: 8,
            handoffEdgePadding: 4,
            interDockGap: 10
        )

        XCTAssertEqual(layout.mainDockExtent, 0)
        XCTAssertEqual(layout.handoffDockExtent, 72)
        XCTAssertEqual(layout.interDockGap, 0)
        XCTAssertEqual(layout.totalExtent, 72)
    }

    func testDetachedHandoffPreservesPrimaryCenterWhenThereIsRoom() {
        let placement =
            PresentedTileDockSurfacePlacementMetrics.resolve(
                primaryNaturalExtent: 500,
                handoffExtent: 80,
                interDockGap: 8,
                availableExtent: 1_000,
                constrainsPrimary: false
            )

        XCTAssertEqual(placement.primaryDockExtent, 500)
        XCTAssertEqual(placement.totalExtent, 588)
        XCTAssertEqual(placement.primaryCenterOffset, 0)
    }

    func testDetachedHandoffClampsPairAtTrailingScreenEdge() {
        let placement =
            PresentedTileDockSurfacePlacementMetrics.resolve(
                primaryNaturalExtent: 500,
                handoffExtent: 80,
                interDockGap: 8,
                availableExtent: 600,
                constrainsPrimary: false
            )

        XCTAssertEqual(placement.totalExtent, 588)
        XCTAssertEqual(placement.primaryCenterOffset, -38)
    }

    func testFullAxisReservesHandoffExtentFromPrimarySurface() {
        let placement =
            PresentedTileDockSurfacePlacementMetrics.resolve(
                primaryNaturalExtent: 500,
                handoffExtent: 80,
                interDockGap: 8,
                availableExtent: 1_000,
                constrainsPrimary: true
            )

        XCTAssertEqual(placement.primaryDockExtent, 912)
        XCTAssertEqual(placement.totalExtent, 1_000)
        XCTAssertEqual(placement.primaryCenterOffset, -44)
    }

    private func applyingTransient(
        to items: [Item],
        transient: Item?
    ) -> [Item] {
        PresentedTileReducer.applyingTransient(
            to: items,
            transient: transient,
            transientID: transientID,
            insertionBeforeID: trailingDividerID,
            id: \.id
        )
    }

    private func item(
        _ id: String,
        value: String = ""
    ) -> Item {
        Item(id: id, value: value)
    }
}
