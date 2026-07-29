import XCTest

final class DockDropMutationPolicyTests: XCTestCase {
    private struct Item: Equatable {
        let id: String
        let payload: String
    }

    func testRequestedVisibleOrderPreservesInvisibleAuthoritativeSlots() {
        let authoritative = [
            Item(id: "a", payload: "A"),
            Item(id: "hidden-1", payload: "H1"),
            Item(id: "b", payload: "B"),
            Item(id: "hidden-2", payload: "H2"),
            Item(id: "c", payload: "C"),
        ]

        let reordered = DockDropMutationPolicy.reorderingVisibleSubset(
            authoritative: authoritative,
            requestedVisibleIDs: ["c", "a", "b"],
            id: \.id
        )

        XCTAssertEqual(
            reordered,
            [
                Item(id: "c", payload: "C"),
                Item(id: "hidden-1", payload: "H1"),
                Item(id: "a", payload: "A"),
                Item(id: "hidden-2", payload: "H2"),
                Item(id: "b", payload: "B"),
            ]
        )
    }

    func testRequestedVisibleOrderPreservesOriginalItemValues() {
        let authoritative = [
            Item(id: "first", payload: "original-first"),
            Item(id: "second", payload: "original-second"),
        ]

        let reordered = DockDropMutationPolicy.reorderingVisibleSubset(
            authoritative: authoritative,
            requestedVisibleIDs: ["second", "first"],
            id: \.id
        )

        XCTAssertEqual(
            reordered,
            [
                Item(id: "second", payload: "original-second"),
                Item(id: "first", payload: "original-first"),
            ]
        )
    }

    func testEmptyRequestedSubsetIsIdentity() {
        let authoritative = [
            Item(id: "a", payload: "A"),
            Item(id: "b", payload: "B"),
        ]

        let reordered = DockDropMutationPolicy.reorderingVisibleSubset(
            authoritative: authoritative,
            requestedVisibleIDs: [],
            id: \.id
        )

        XCTAssertEqual(reordered, authoritative)
    }

    func testRequestedVisibleOrderRejectsUnknownID() {
        XCTAssertNil(
            DockDropMutationPolicy.reorderingVisibleSubset(
                authoritative: ["a", "b"],
                requestedVisibleIDs: ["a", "missing"],
                id: { $0 }
            )
        )
    }

    func testRequestedVisibleOrderRejectsDuplicateRequestedID() {
        XCTAssertNil(
            DockDropMutationPolicy.reorderingVisibleSubset(
                authoritative: ["a", "b"],
                requestedVisibleIDs: ["a", "a"],
                id: { $0 }
            )
        )
    }

    func testRequestedVisibleOrderRejectsDuplicateAuthoritativeID() {
        XCTAssertNil(
            DockDropMutationPolicy.reorderingVisibleSubset(
                authoritative: ["a", "a"],
                requestedVisibleIDs: ["a"],
                id: { $0 }
            )
        )
    }

    func testSourceDestinationMoveUsesVisibleListAfterSourceRemoval() {
        let reordered = DockDropMutationPolicy.reorderingVisibleSubset(
            authoritativeIDs: ["a", "hidden", "b", "c"],
            visibleIDs: ["a", "b", "c"],
            sourceID: "a",
            destinationIndex: 2
        )

        XCTAssertEqual(reordered, ["b", "hidden", "c", "a"])
    }

    func testSourceDestinationMoveClampsBeforeLeadingEdge() {
        let reordered = DockDropMutationPolicy.reorderingVisibleSubset(
            authoritativeIDs: ["a", "b", "c"],
            visibleIDs: ["a", "b", "c"],
            sourceID: "c",
            destinationIndex: -100
        )

        XCTAssertEqual(reordered, ["c", "a", "b"])
    }

    func testSourceDestinationMoveClampsAfterTrailingEdge() {
        let reordered = DockDropMutationPolicy.reorderingVisibleSubset(
            authoritativeIDs: ["a", "b", "c"],
            visibleIDs: ["a", "b", "c"],
            sourceID: "a",
            destinationIndex: 100
        )

        XCTAssertEqual(reordered, ["b", "c", "a"])
    }

    func testSourceDestinationMoveRejectsMissingSource() {
        XCTAssertNil(
            DockDropMutationPolicy.reorderingVisibleSubset(
                authoritativeIDs: ["a", "b"],
                visibleIDs: ["a", "b"],
                sourceID: "missing",
                destinationIndex: 0
            )
        )
    }

    func testVisibleInsertionPreservesInvisibleItemsAroundAnchor() {
        let authoritative = ["hidden-leading", "a", "hidden-middle", "b", "hidden-tail"]

        XCTAssertEqual(
            DockDropMutationPolicy.authoritativeInsertionIndex(
                authoritative: authoritative,
                visibleIDs: ["a", "b"],
                visibleDestinationIndex: 0,
                id: { $0 }
            ),
            1
        )
        XCTAssertEqual(
            DockDropMutationPolicy.authoritativeInsertionIndex(
                authoritative: authoritative,
                visibleIDs: ["a", "b"],
                visibleDestinationIndex: 1,
                id: { $0 }
            ),
            3
        )
        XCTAssertEqual(
            DockDropMutationPolicy.authoritativeInsertionIndex(
                authoritative: authoritative,
                visibleIDs: ["a", "b"],
                visibleDestinationIndex: 2,
                id: { $0 }
            ),
            4
        )
    }

    func testVisibleInsertionBoundarySurvivesFolderCollapseTransformation() {
        struct LayoutItem: Equatable {
            let id: String
            let members: [String]
        }

        let authoritative = [
            LayoutItem(id: "hidden", members: []),
            LayoutItem(id: "folder", members: ["source", "other"]),
        ]

        let insertionIndex =
            DockDropMutationPolicy
            .authoritativeInsertionIndexAfterTransformingPrefix(
                authoritative: authoritative,
                visibleIDs: ["folder"],
                visibleDestinationIndex: 1,
                id: \.id,
                transformPrefix: { prefix in
                    prefix.map { item in
                        guard item.id == "folder" else {
                            return item
                        }
                        return LayoutItem(
                            id: "other",
                            members: ["other"]
                        )
                    }
                }
            )

        XCTAssertEqual(insertionIndex, 2)
    }

    func testVisibleInsertionAppendsWhenNoTargetItemsMaterialize() {
        XCTAssertEqual(
            DockDropMutationPolicy.authoritativeInsertionIndex(
                authoritative: ["hidden-a", "hidden-b"],
                visibleIDs: [],
                visibleDestinationIndex: 0,
                id: { $0 }
            ),
            2
        )
    }

    func testVisibleInsertionRejectsUnknownOrDuplicateIDs() {
        XCTAssertNil(
            DockDropMutationPolicy.authoritativeInsertionIndex(
                authoritative: ["a", "b"],
                visibleIDs: ["a", "missing"],
                visibleDestinationIndex: 1,
                id: { $0 }
            )
        )
        XCTAssertNil(
            DockDropMutationPolicy.authoritativeInsertionIndex(
                authoritative: ["a", "a"],
                visibleIDs: ["a"],
                visibleDestinationIndex: 1,
                id: { $0 }
            )
        )
        XCTAssertNil(
            DockDropMutationPolicy.authoritativeInsertionIndex(
                authoritative: ["a", "b"],
                visibleIDs: ["a", "a"],
                visibleDestinationIndex: 1,
                id: { $0 }
            )
        )
    }

    func testUnpinnedAppOverRunningStripAppendsToPinned() {
        let destination = DockDropAxisRegionPolicy.destination(
            for: .unpinnedApp,
            over: .running,
            canDropIntoPinned: true,
            canDropIntoTrailing: false,
            authoritativePinnedCount: 3,
            authoritativeTrailingCount: 2
        )

        XCTAssertEqual(destination, .pinned(index: 3))
    }

    func testUnpinnedAppOverRunningStripSupportsEmptyPinnedLayout() {
        let destination = DockDropAxisRegionPolicy.destination(
            for: .unpinnedApp,
            over: .running,
            canDropIntoPinned: true,
            canDropIntoTrailing: false,
            authoritativePinnedCount: 0,
            authoritativeTrailingCount: 1
        )

        XCTAssertEqual(destination, .pinned(index: 0))
    }

    func testRunningStripDoesNotMoveAlreadyPinnedSource() {
        XCTAssertNil(
            DockDropAxisRegionPolicy.destination(
                for: .pinned,
                over: .running,
                canDropIntoPinned: true,
                canDropIntoTrailing: false,
                authoritativePinnedCount: 3,
                authoritativeTrailingCount: 1
            )
        )
    }

    func testRunningStripRequiresPinnedCapability() {
        XCTAssertNil(
            DockDropAxisRegionPolicy.destination(
                for: .unpinnedApp,
                over: .running,
                canDropIntoPinned: false,
                canDropIntoTrailing: false,
                authoritativePinnedCount: 3,
                authoritativeTrailingCount: 1
            )
        )
    }

    func testPinnedAndTrailingDestinationsClampToAuthoritativeBounds() {
        XCTAssertEqual(
            DockDropAxisRegionPolicy.destination(
                for: .trailing,
                over: .pinned(insertionIndex: 99),
                canDropIntoPinned: true,
                canDropIntoTrailing: true,
                authoritativePinnedCount: 4,
                authoritativeTrailingCount: 2
            ),
            .pinned(index: 4)
        )
        XCTAssertEqual(
            DockDropAxisRegionPolicy.destination(
                for: .pinned,
                over: .trailing(insertionIndex: -5),
                canDropIntoPinned: true,
                canDropIntoTrailing: true,
                authoritativePinnedCount: 4,
                authoritativeTrailingCount: 2
            ),
            .trailing(index: 0)
        )
    }

    func testAxisRegionRequiresMatchingDestinationCapability() {
        XCTAssertNil(
            DockDropAxisRegionPolicy.destination(
                for: .unpinnedApp,
                over: .pinned(insertionIndex: 1),
                canDropIntoPinned: false,
                canDropIntoTrailing: true,
                authoritativePinnedCount: 3,
                authoritativeTrailingCount: 2
            )
        )
        XCTAssertNil(
            DockDropAxisRegionPolicy.destination(
                for: .unpinnedApp,
                over: .trailing(insertionIndex: 1),
                canDropIntoPinned: true,
                canDropIntoTrailing: false,
                authoritativePinnedCount: 3,
                authoritativeTrailingCount: 2
            )
        )
    }

    func testPinnedAppGroupingUsesTargetFirstAndReplacementAnchor() {
        let plan = DockAppGroupLayoutPolicy.plan(
            sourceBundleIdentifiers: [
                "net.whatsapp.WhatsApp",
                "com.spotify.client",
                "net.whatsapp.WhatsApp",
            ],
            target: .pinnedApp(
                itemID: "app:com.spotify.client",
                bundleIdentifier: "com.spotify.client"
            )
        )

        XCTAssertEqual(
            plan,
            DockAppGroupLayoutPlan(
                bundleIdentifiersToDetach: [
                    "net.whatsapp.WhatsApp",
                ],
                folderBundleIdentifiers: [
                    "com.spotify.client",
                    "net.whatsapp.WhatsApp",
                ],
                placement: .replacingPinnedItem(
                    itemID: "app:com.spotify.client"
                )
            )
        )
    }

    func testPinnedFolderGroupingPreservesMembersThenPickupOrder() {
        let plan = DockAppGroupLayoutPolicy.plan(
            sourceBundleIdentifiers: [
                "com.apple.Music",
                "com.spotify.client",
                "net.whatsapp.WhatsApp",
                "com.apple.Music",
            ],
            target: .pinnedFolder(
                itemID: "custom:media",
                bundleIdentifiers: [
                    "com.spotify.client",
                    "com.apple.podcasts",
                ]
            )
        )

        XCTAssertEqual(
            plan,
            DockAppGroupLayoutPlan(
                bundleIdentifiersToDetach: [
                    "com.apple.Music",
                    "net.whatsapp.WhatsApp",
                ],
                folderBundleIdentifiers: [
                    "com.spotify.client",
                    "com.apple.podcasts",
                    "com.apple.Music",
                    "net.whatsapp.WhatsApp",
                ],
                placement: .updatingPinnedFolder(
                    itemID: "custom:media"
                )
            )
        )
    }

    func testRunningAppGroupingCreatesAppendPinnedPlan() {
        let plan = DockAppGroupLayoutPolicy.plan(
            sourceBundleIdentifiers: [
                "net.whatsapp.WhatsApp",
            ],
            target: .runningApp(
                bundleIdentifier: "com.spotify.client"
            )
        )

        XCTAssertEqual(
            plan,
            DockAppGroupLayoutPlan(
                bundleIdentifiersToDetach: [
                    "com.spotify.client",
                    "net.whatsapp.WhatsApp",
                ],
                folderBundleIdentifiers: [
                    "com.spotify.client",
                    "net.whatsapp.WhatsApp",
                ],
                placement: .appendPinned
            )
        )
    }

    func testRunningAppGroupingDeduplicatesTargetFromSources() {
        let plan = DockAppGroupLayoutPolicy.plan(
            sourceBundleIdentifiers: [
                "com.spotify.client",
                "net.whatsapp.WhatsApp",
                "net.whatsapp.WhatsApp",
            ],
            target: .runningApp(
                bundleIdentifier: "com.spotify.client"
            )
        )

        XCTAssertEqual(
            plan?.folderBundleIdentifiers,
            [
                "com.spotify.client",
                "net.whatsapp.WhatsApp",
            ]
        )
    }

    func testGroupingFiltersEmptyAndFinderSourcesWithoutChangingOrder() {
        let plan = DockAppGroupLayoutPolicy.plan(
            sourceBundleIdentifiers: [
                "",
                "com.apple.finder",
                "net.whatsapp.WhatsApp",
                "com.apple.Music",
            ],
            target: .pinnedApp(
                itemID: "app:com.spotify.client",
                bundleIdentifier: "com.spotify.client"
            )
        )

        XCTAssertEqual(
            plan?.folderBundleIdentifiers,
            [
                "com.spotify.client",
                "net.whatsapp.WhatsApp",
                "com.apple.Music",
            ]
        )
    }

    func testGroupingRejectsTargetOnlyNoOp() {
        XCTAssertNil(
            DockAppGroupLayoutPolicy.plan(
                sourceBundleIdentifiers: [
                    "com.spotify.client",
                    "com.spotify.client",
                ],
                target: .runningApp(
                    bundleIdentifier: "com.spotify.client"
                )
            )
        )
    }

    func testGroupingRejectsFinderTarget() {
        XCTAssertNil(
            DockAppGroupLayoutPolicy.plan(
                sourceBundleIdentifiers: [
                    "net.whatsapp.WhatsApp",
                ],
                target: .runningApp(
                    bundleIdentifier: "com.apple.finder"
                )
            )
        )
    }

    func testGroupingRejectsCorruptExistingFolderMembership() {
        XCTAssertNil(
            DockAppGroupLayoutPolicy.plan(
                sourceBundleIdentifiers: [
                    "net.whatsapp.WhatsApp",
                ],
                target: .pinnedFolder(
                    itemID: "custom:media",
                    bundleIdentifiers: [
                        "com.spotify.client",
                        "com.spotify.client",
                    ]
                )
            )
        )
    }
}
