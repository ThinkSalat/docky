//
//  DockDropMutationPolicy.swift
//  Docky
//
//  Pure drag/drop mutation rules. Keeping these rules independent of AppKit,
//  SwiftUI, and persisted preference types makes it possible to verify the
//  authoritative layout transformations without launching Docky.
//

import Foundation

/// Reconciles a reordered visible subset with its authoritative collection.
///
/// A rendered dock can omit authoritative items (for example, filtered or
/// temporarily unavailable items). Replacing the authoritative collection
/// with the visible preview would silently delete those items. This policy
/// instead treats the positions occupied by the requested IDs as mutable
/// slots and leaves every other position untouched.
nonisolated enum DockDropMutationPolicy {
    /// Applies an already-computed visible order to an authoritative item list.
    ///
    /// - Returns: The reordered authoritative list, or `nil` when IDs are
    ///   duplicated or the requested subset contains an unknown ID.
    static func reorderingVisibleSubset<Item>(
        authoritative: [Item],
        requestedVisibleIDs: [String],
        id: (Item) -> String
    ) -> [Item]? {
        let authoritativeIDs = authoritative.map(id)
        let authoritativeIDSet = Set(authoritativeIDs)
        guard authoritativeIDSet.count == authoritativeIDs.count else {
            return nil
        }

        let requestedIDSet = Set(requestedVisibleIDs)
        guard requestedIDSet.count == requestedVisibleIDs.count,
              requestedIDSet.isSubset(of: authoritativeIDSet) else {
            return nil
        }

        guard !requestedVisibleIDs.isEmpty else {
            return authoritative
        }

        let mutableSlots = authoritativeIDs.indices.filter {
            requestedIDSet.contains(authoritativeIDs[$0])
        }
        guard mutableSlots.count == requestedVisibleIDs.count else {
            return nil
        }

        let itemsByID = Dictionary(
            uniqueKeysWithValues: zip(authoritativeIDs, authoritative)
        )
        var reordered = authoritative
        for (slot, requestedID) in zip(
            mutableSlots,
            requestedVisibleIDs
        ) {
            guard let item = itemsByID[requestedID] else {
                return nil
            }
            reordered[slot] = item
        }
        return reordered
    }

    /// Moves one visible ID to an insertion index measured after removing the
    /// source, then reconciles that requested order with the authoritative
    /// slots. Out-of-range destination indices are clamped to either edge.
    static func reorderingVisibleSubset(
        authoritativeIDs: [String],
        visibleIDs: [String],
        sourceID: String,
        destinationIndex: Int
    ) -> [String]? {
        guard Set(visibleIDs).count == visibleIDs.count,
              let sourceIndex = visibleIDs.firstIndex(of: sourceID) else {
            return nil
        }

        var requestedVisibleIDs = visibleIDs
        requestedVisibleIDs.remove(at: sourceIndex)
        let clampedDestinationIndex = min(
            max(destinationIndex, 0),
            requestedVisibleIDs.count
        )
        requestedVisibleIDs.insert(
            sourceID,
            at: clampedDestinationIndex
        )

        return reorderingVisibleSubset(
            authoritative: authoritativeIDs,
            requestedVisibleIDs: requestedVisibleIDs,
            id: { $0 }
        )
    }

    /// Resolves an insertion index expressed in rendered/visible coordinates
    /// into the authoritative collection without collapsing invisible items.
    ///
    /// A destination before a visible item anchors immediately before that
    /// item. A destination after the final visible item anchors immediately
    /// after it, leaving any later invisible slots in place. When no target
    /// items are visible, insertion appends so an unresolved saved layout is
    /// never displaced by a newly dropped item.
    static func authoritativeInsertionIndex<Item>(
        authoritative: [Item],
        visibleIDs: [String],
        visibleDestinationIndex: Int,
        id: (Item) -> String
    ) -> Int? {
        let authoritativeIDs = authoritative.map(id)
        guard Set(authoritativeIDs).count == authoritativeIDs.count,
              Set(visibleIDs).count == visibleIDs.count,
              Set(visibleIDs).isSubset(of: Set(authoritativeIDs)) else {
            return nil
        }

        guard !visibleIDs.isEmpty else {
            return authoritative.count
        }

        let clampedDestinationIndex = min(
            max(visibleDestinationIndex, 0),
            visibleIDs.count
        )
        if clampedDestinationIndex < visibleIDs.count {
            return authoritativeIDs.firstIndex(
                of: visibleIDs[clampedDestinationIndex]
            )
        }

        guard let finalVisibleIndex = authoritativeIDs.firstIndex(
            of: visibleIDs[visibleIDs.count - 1]
        ) else {
            return nil
        }
        return finalVisibleIndex + 1
    }

    /// Maps a visible insertion boundary through a structural transformation
    /// of the authoritative prefix preceding that boundary.
    ///
    /// This is useful when the mutation that precedes insertion can change
    /// item identity or cardinality. Removing an app from a two-member folder,
    /// for example, replaces the folder with a standalone app. Resolving an
    /// anchor by its old ID after that transformation would fail and tempt the
    /// caller to fall back to a raw visible index, displacing hidden items.
    ///
    /// The destination is first resolved against the original authoritative
    /// collection. Only the prefix before that boundary is transformed, and
    /// its resulting count is the insertion index in the fully transformed
    /// collection.
    static func authoritativeInsertionIndexAfterTransformingPrefix<
        Item,
        TransformedItem
    >(
        authoritative: [Item],
        visibleIDs: [String],
        visibleDestinationIndex: Int,
        id: (Item) -> String,
        transformPrefix: ([Item]) -> [TransformedItem]
    ) -> Int? {
        guard let originalBoundary =
                authoritativeInsertionIndex(
                    authoritative: authoritative,
                    visibleIDs: visibleIDs,
                    visibleDestinationIndex:
                        visibleDestinationIndex,
                    id: id
                )
        else {
            return nil
        }

        return transformPrefix(
            Array(authoritative.prefix(originalBoundary))
        ).count
    }
}

/// The along-axis region currently under an internal tile drag.
nonisolated enum DockDropAxisRegion: Equatable, Sendable {
    case pinned(insertionIndex: Int)
    case running
    case trailing(insertionIndex: Int)
}

/// The authoritative membership of the internally dragged tile.
nonisolated enum DockDropAxisSource: Equatable, Sendable {
    case pinned
    case trailing
    case unpinnedApp
    case unsupported
}

/// A persistence-capable destination. The running strip is deliberately not
/// represented because it is derived from live applications rather than an
/// authoritative user-managed collection.
nonisolated enum DockDropAxisDestination: Equatable, Sendable {
    case pinned(index: Int)
    case trailing(index: Int)
}

/// Converts rendered axis regions into persistence-capable destinations.
nonisolated enum DockDropAxisRegionPolicy {
    static func destination(
        for source: DockDropAxisSource,
        over region: DockDropAxisRegion?,
        canDropIntoPinned: Bool,
        canDropIntoTrailing: Bool,
        authoritativePinnedCount: Int,
        authoritativeTrailingCount: Int
    ) -> DockDropAxisDestination? {
        guard let region else {
            return nil
        }

        switch region {
        case .pinned(let insertionIndex):
            guard canDropIntoPinned else {
                return nil
            }
            return .pinned(
                index: clampedInsertionIndex(
                    insertionIndex,
                    itemCount: authoritativePinnedCount
                )
            )
        case .running:
            // Running tiles have no directly reorderable persisted collection.
            // Treating this as an append-to-pinned gesture gives an unpinned
            // app a stable user-managed position instead of accepting a drag
            // that can never mutate anything.
            guard source == .unpinnedApp,
                  canDropIntoPinned else {
                return nil
            }
            return .pinned(index: max(0, authoritativePinnedCount))
        case .trailing(let insertionIndex):
            guard canDropIntoTrailing else {
                return nil
            }
            return .trailing(
                index: clampedInsertionIndex(
                    insertionIndex,
                    itemCount: authoritativeTrailingCount
                )
            )
        }
    }

    private static func clampedInsertionIndex(
        _ insertionIndex: Int,
        itemCount: Int
    ) -> Int {
        min(max(insertionIndex, 0), max(itemCount, 0))
    }
}

/// An app or app-folder target that can receive dragged applications.
nonisolated enum DockAppGroupTarget: Equatable, Sendable {
    case pinnedApp(
        itemID: String,
        bundleIdentifier: String
    )
    case pinnedFolder(
        itemID: String,
        bundleIdentifiers: [String]
    )
    case runningApp(bundleIdentifier: String)
}

/// The authoritative anchor at which the caller applies a grouping plan.
nonisolated enum DockAppGroupPlacement: Equatable, Sendable {
    case replacingPinnedItem(itemID: String)
    case updatingPinnedFolder(itemID: String)
    case appendPinned
}

/// A persistence-neutral description of an app-group mutation.
nonisolated struct DockAppGroupLayoutPlan: Equatable, Sendable {
    /// Standalone apps or memberships that must be detached before inserting
    /// the resolved folder. Order is stable and duplicates are removed.
    let bundleIdentifiersToDetach: [String]

    /// Complete folder membership after the mutation. A new folder always
    /// places its target first, followed by dragged sources in pickup order.
    let folderBundleIdentifiers: [String]

    let placement: DockAppGroupPlacement
}

/// Plans app grouping for both persisted and derived running-app targets.
nonisolated enum DockAppGroupLayoutPolicy {
    static func plan(
        sourceBundleIdentifiers: [String],
        target: DockAppGroupTarget,
        finderBundleIdentifier: String = "com.apple.finder"
    ) -> DockAppGroupLayoutPlan? {
        let sources = normalizedSources(
            sourceBundleIdentifiers,
            finderBundleIdentifier: finderBundleIdentifier
        )

        switch target {
        case .pinnedApp(let itemID, let targetBundleIdentifier):
            guard !itemID.isEmpty,
                  isValidGroupableBundleIdentifier(
                    targetBundleIdentifier,
                    finderBundleIdentifier: finderBundleIdentifier
                  ) else {
                return nil
            }

            let additions = sources.filter {
                $0 != targetBundleIdentifier
            }
            guard !additions.isEmpty else {
                return nil
            }

            return DockAppGroupLayoutPlan(
                bundleIdentifiersToDetach: additions,
                folderBundleIdentifiers:
                    [targetBundleIdentifier] + additions,
                placement: .replacingPinnedItem(itemID: itemID)
            )

        case .pinnedFolder(
            let itemID,
            let existingBundleIdentifiers
        ):
            guard !itemID.isEmpty,
                  isValidExistingFolder(
                    existingBundleIdentifiers,
                    finderBundleIdentifier: finderBundleIdentifier
                  ) else {
                return nil
            }

            let existingSet = Set(existingBundleIdentifiers)
            let additions = sources.filter {
                !existingSet.contains($0)
            }
            guard !additions.isEmpty else {
                return nil
            }

            return DockAppGroupLayoutPlan(
                bundleIdentifiersToDetach: additions,
                folderBundleIdentifiers:
                    existingBundleIdentifiers + additions,
                placement: .updatingPinnedFolder(itemID: itemID)
            )

        case .runningApp(let targetBundleIdentifier):
            guard isValidGroupableBundleIdentifier(
                targetBundleIdentifier,
                finderBundleIdentifier: finderBundleIdentifier
            ) else {
                return nil
            }

            let additions = sources.filter {
                $0 != targetBundleIdentifier
            }
            guard !additions.isEmpty else {
                return nil
            }

            let folderBundleIdentifiers =
                [targetBundleIdentifier] + additions
            return DockAppGroupLayoutPlan(
                // The target is expected to be unpinned, but detaching the
                // complete membership also makes a stale hidden pin harmless.
                bundleIdentifiersToDetach: folderBundleIdentifiers,
                folderBundleIdentifiers: folderBundleIdentifiers,
                placement: .appendPinned
            )
        }
    }

    private static func normalizedSources(
        _ bundleIdentifiers: [String],
        finderBundleIdentifier: String
    ) -> [String] {
        var seen: Set<String> = []
        return bundleIdentifiers.filter {
            isValidGroupableBundleIdentifier(
                $0,
                finderBundleIdentifier: finderBundleIdentifier
            ) && seen.insert($0).inserted
        }
    }

    private static func isValidExistingFolder(
        _ bundleIdentifiers: [String],
        finderBundleIdentifier: String
    ) -> Bool {
        !bundleIdentifiers.isEmpty
            && Set(bundleIdentifiers).count == bundleIdentifiers.count
            && bundleIdentifiers.allSatisfy {
                isValidGroupableBundleIdentifier(
                    $0,
                    finderBundleIdentifier: finderBundleIdentifier
                )
            }
    }

    private static func isValidGroupableBundleIdentifier(
        _ bundleIdentifier: String,
        finderBundleIdentifier: String
    ) -> Bool {
        !bundleIdentifier.isEmpty
            && bundleIdentifier != finderBundleIdentifier
    }
}
