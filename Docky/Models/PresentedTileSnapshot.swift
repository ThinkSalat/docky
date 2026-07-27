//
//  PresentedTileSnapshot.swift
//  Docky
//
//  Immutable presentation state shared by rendering and window measurement.
//  Keeping transient composition and axis measurement pure gives every
//  presentation consumer the same deterministic inputs.
//

import Foundation

nonisolated struct PresentedTileSnapshot<Item: Equatable>: Equatable {
    let items: [Item]
    let revision: UInt64

    init(items: [Item] = [], revision: UInt64 = 0) {
        self.items = items
        self.revision = revision
    }

    func replacingItems(_ items: [Item]) -> Self {
        guard items != self.items else {
            return self
        }

        return Self(
            items: items,
            revision: revision &+ 1
        )
    }
}

nonisolated enum PresentedTileReducer {
    static func applyingTransient<Item>(
        to items: [Item],
        transient: Item?,
        transientID: String,
        insertionBeforeID: String?,
        id: (Item) -> String
    ) -> [Item] {
        var presentedItems = items.filter {
            id($0) != transientID
        }

        guard let transient else {
            return presentedItems
        }

        let insertionIndex = insertionBeforeID.flatMap { insertionBeforeID in
            presentedItems.firstIndex {
                id($0) == insertionBeforeID
            }
        } ?? presentedItems.endIndex
        presentedItems.insert(transient, at: insertionIndex)
        return presentedItems
    }
}

nonisolated enum PresentedTileAxisMetrics {
    static func extent(
        itemExtents: [CGFloat],
        spacing: CGFloat,
        edgePadding: CGFloat
    ) -> CGFloat {
        let spacingCount = CGFloat(max(0, itemExtents.count - 1))
        return itemExtents.reduce(0, +)
            + spacingCount * spacing
            + edgePadding * 2
    }
}

/// A pure partition of the canonical presentation snapshot into independently
/// rendered dock surfaces. The items remain in their original relative order,
/// and every input item belongs to exactly one surface.
nonisolated struct PresentedTileDockPartition<Item: Equatable>: Equatable {
    let mainItems: [Item]
    let handoffItems: [Item]

    /// Resolves the user-facing Handoff presentation mode without changing
    /// canonical tile membership or order. Inline mode keeps the entire
    /// snapshot on the primary surface; separate mode moves only Handoff
    /// items to the accessory surface.
    static func presenting(
        _ items: [Item],
        separatesHandoff: Bool,
        isHandoff: (Item) -> Bool
    ) -> Self {
        guard separatesHandoff else {
            return Self(
                mainItems: items,
                handoffItems: []
            )
        }

        return splitting(
            items,
            isHandoff: isHandoff
        )
    }

    static func splitting(
        _ items: [Item],
        isHandoff: (Item) -> Bool
    ) -> Self {
        var mainItems: [Item] = []
        var handoffItems: [Item] = []
        mainItems.reserveCapacity(items.count)

        for item in items {
            if isHandoff(item) {
                handoffItems.append(item)
            } else {
                mainItems.append(item)
            }
        }

        return Self(
            mainItems: mainItems,
            handoffItems: handoffItems
        )
    }
}

/// Axis measurement for a main dock plus an optional, independently padded
/// Handoff mini-dock. The inter-dock gap exists only when both surfaces exist.
nonisolated struct PresentedTileDockAxisLayout: Equatable {
    let mainDockExtent: CGFloat
    let handoffDockExtent: CGFloat
    let interDockGap: CGFloat
    let totalExtent: CGFloat
}

nonisolated enum PresentedTileDockAxisMetrics {
    static func measure(
        mainItemExtents: [CGFloat],
        handoffItemExtents: [CGFloat],
        itemSpacing: CGFloat,
        mainEdgePadding: CGFloat,
        handoffEdgePadding: CGFloat,
        interDockGap: CGFloat
    ) -> PresentedTileDockAxisLayout {
        let mainDockExtent = segmentExtent(
            itemExtents: mainItemExtents,
            spacing: itemSpacing,
            edgePadding: mainEdgePadding
        )
        let handoffDockExtent = segmentExtent(
            itemExtents: handoffItemExtents,
            spacing: itemSpacing,
            edgePadding: handoffEdgePadding
        )
        let effectiveGap = mainItemExtents.isEmpty
            || handoffItemExtents.isEmpty
            ? 0
            : interDockGap

        return PresentedTileDockAxisLayout(
            mainDockExtent: mainDockExtent,
            handoffDockExtent: handoffDockExtent,
            interDockGap: effectiveGap,
            totalExtent: mainDockExtent + effectiveGap + handoffDockExtent
        )
    }

    private static func segmentExtent(
        itemExtents: [CGFloat],
        spacing: CGFloat,
        edgePadding: CGFloat
    ) -> CGFloat {
        guard !itemExtents.isEmpty else {
            return 0
        }

        return PresentedTileAxisMetrics.extent(
            itemExtents: itemExtents,
            spacing: spacing,
            edgePadding: edgePadding
        )
    }
}

/// Placement of two already-measured dock surfaces within the available
/// screen axis. The primary surface remains centered when trailing room can
/// hold the Handoff surface; otherwise the pair clamps to the trailing edge.
nonisolated struct PresentedTileDockSurfacePlacement:
    Equatable {
    let primaryDockExtent: CGFloat
    let handoffDockExtent: CGFloat
    let interDockGap: CGFloat
    let totalExtent: CGFloat
    let primaryCenterOffset: CGFloat
}

nonisolated enum PresentedTileDockSurfacePlacementMetrics {
    static func resolve(
        primaryNaturalExtent: CGFloat,
        handoffExtent: CGFloat,
        interDockGap: CGFloat,
        availableExtent: CGFloat,
        constrainsPrimary: Bool
    ) -> PresentedTileDockSurfacePlacement {
        let availableExtent = max(0, availableExtent)
        let handoffExtent = max(0, handoffExtent)
        let effectiveGap =
            primaryNaturalExtent > 0 && handoffExtent > 0
            ? max(0, interDockGap)
            : 0
        let primaryExtent =
            constrainsPrimary
            ? max(
                0,
                availableExtent
                    - handoffExtent
                    - effectiveGap
            )
            : max(0, primaryNaturalExtent)
        let totalExtent =
            primaryExtent
            + effectiveGap
            + handoffExtent
        let desiredPrimaryStart = max(
            0,
            (availableExtent - primaryExtent) / 2
        )
        let latestPrimaryStart = max(
            0,
            availableExtent - totalExtent
        )
        let primaryStart = min(
            desiredPrimaryStart,
            latestPrimaryStart
        )
        let primaryCenterOffset =
            primaryStart
            + primaryExtent / 2
            - availableExtent / 2

        return PresentedTileDockSurfacePlacement(
            primaryDockExtent: primaryExtent,
            handoffDockExtent: handoffExtent,
            interDockGap: effectiveGap,
            totalExtent: totalExtent,
            primaryCenterOffset: primaryCenterOffset
        )
    }
}
