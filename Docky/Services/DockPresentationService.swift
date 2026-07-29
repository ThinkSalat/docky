//
//  DockPresentationService.swift
//  Docky
//
//  Canonical owner of the exact ordered tile list presented by the dock.
//  SwiftUI rendering and AppKit window sizing both consume `snapshot.items`;
//  transient features must enter through the inputs below instead of splicing
//  their own private copy of the tile array.
//

import Combine
import Foundation
import Observation
import OSLog

@MainActor
final class DockPresentationService: ObservableObject {
    static let shared = DockPresentationService()

    /// One atomic value contains everything the renderer can use to derive
    /// tile membership or commit a previewed order. Keeping the auxiliary
    /// section arrays inside the published snapshot prevents a source
    /// callback from observing a new tile list with stale drag metadata (or
    /// vice versa).
    struct Snapshot: Equatable {
        fileprivate let presentedTiles:
            PresentedTileSnapshot<Tile>
        let pinnedBaseTiles: [Tile]
        let trailingTiles: [Tile]
        /// Captured alongside tile membership so rendering and AppKit
        /// measurement can never disagree about whether Handoff is inline
        /// or on its own surface.
        let separatesHandoffDock: Bool

        var items: [Tile] {
            presentedTiles.items
        }

        var revision: UInt64 {
            presentedTiles.revision
        }

        var dockPartition:
            PresentedTileDockPartition<Tile> {
            PresentedTileDockPartition.presenting(
                items,
                separatesHandoff: separatesHandoffDock,
                isHandoff: {
                    $0.id == DockBadgeService.handoffTileID
                }
            )
        }

        fileprivate init(
            presentedTiles:
                PresentedTileSnapshot<Tile>,
            pinnedBaseTiles: [Tile],
            trailingTiles: [Tile],
            separatesHandoffDock: Bool
        ) {
            self.presentedTiles = presentedTiles
            self.pinnedBaseTiles = pinnedBaseTiles
            self.trailingTiles = trailingTiles
            self.separatesHandoffDock =
                separatesHandoffDock
        }
    }

    struct InternalDragState: Equatable {
        var tileID: String?
        var pinnedDestinationIndex: Int?
        var trailingDestinationIndex: Int?
        var additionalTileIDs: [String] = []
    }

    @Published private(set) var snapshot = Snapshot(
        presentedTiles: PresentedTileSnapshot(),
        pinnedBaseTiles: [],
        trailingTiles: [],
        separatesHandoffDock: false
    )
    @Published private(set) var internalDrag = InternalDragState() {
        didSet {
            guard internalDrag != oldValue else { return }
            rebuildSnapshot()
        }
    }

    private let store = TileStore.shared
    private let editMode = DockEditModeService.shared
    private let dockDrag = DockDragService.shared
    private let dockBadges = DockBadgeService.shared
    private let preferences = DockyPreferences.shared
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        rebuildSnapshot()
        observeInputs()
        observePresentationInputs()
    }

    var draggedTileID: String? {
        get { internalDrag.tileID }
        set {
            updateInternalDrag { $0.tileID = newValue }
        }
    }

    var draggedPinnedTileDestinationIndex: Int? {
        get { internalDrag.pinnedDestinationIndex }
        set {
            updateInternalDrag {
                $0.pinnedDestinationIndex = newValue
            }
        }
    }

    var draggedTrailingTileDestinationIndex: Int? {
        get { internalDrag.trailingDestinationIndex }
        set {
            updateInternalDrag {
                $0.trailingDestinationIndex = newValue
            }
        }
    }

    var draggedAdditionalTileIDs: [String] {
        get { internalDrag.additionalTileIDs }
        set {
            updateInternalDrag { $0.additionalTileIDs = newValue }
        }
    }

    func beginInternalDrag(
        tileID: String,
        pinnedDestinationIndex: Int?,
        trailingDestinationIndex: Int?
    ) {
        updateInternalDrag {
            $0.tileID = tileID
            $0.pinnedDestinationIndex = pinnedDestinationIndex
            $0.trailingDestinationIndex = trailingDestinationIndex
            $0.additionalTileIDs = []
        }
    }

    func clearInternalDrag() {
        internalDrag = InternalDragState()
    }

    func setInternalDragDestinations(
        pinned: Int?,
        trailing: Int?
    ) {
        updateInternalDrag {
            $0.pinnedDestinationIndex = pinned
            $0.trailingDestinationIndex = trailing
        }
    }

    private func updateInternalDrag(
        _ update: (inout InternalDragState) -> Void
    ) {
        var next = internalDrag
        update(&next)
        guard next != internalDrag else { return }
        internalDrag = next
    }

    /// Palette hit-testing runs from SwiftUI's source `onChange`, which can
    /// precede the Combine delivery that rebuilds `snapshot`. Derive this
    /// value directly from the callback payload so no run-loop ordering can
    /// produce a stale nil preview.
    static func palettePreviewTile(
        for paletteDrag: DockEditPaletteDrag
    ) -> Tile {
        DockPresentationComposer.palettePreviewTile(
            for: paletteDrag
        )
    }

    private func observeInputs() {
        let signals: [AnyPublisher<Void, Never>] = [
            store.$tiles
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            editMode.$paletteDrag
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            editMode.$paletteDropDestination
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            dockDrag.$kind
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            dockDrag.$destinationIndex
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            dockDrag.$destinationSection
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            dockDrag.$documentTargetTileID
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            dockBadges.$handoffSuggestion
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(signals)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSnapshot()
            }
            .store(in: &cancellables)
    }

    private func observePresentationInputs() {
        withObservationTracking {
            _ = ThemeManager.shared.activeManifest
            _ = preferences.separateHandoffDock
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rebuildSnapshot()
                self.observePresentationInputs()
            }
        }
    }

    private func rebuildSnapshot() {
        let baseTiles = store.tiles
        let pinnedIDs = Set(
            baseTiles.lazy
                .filter {
                    self.store.isPinnedReorderable(
                        tileID: $0.id
                    )
                }
                .map(\.id)
        )
        let trailingIDs = Set(
            baseTiles.lazy
                .filter {
                    self.store.isTrailingReorderable(
                        tileID: $0.id
                    )
                }
                .map(\.id)
        )
        let draggedTile = internalDrag.tileID.flatMap { tileID in
            baseTiles.first { $0.id == tileID }
        }
        let composition = DockPresentationComposer.compose(
            baseTiles: baseTiles,
            pinnedTileIDs: pinnedIDs,
            trailingTileIDs: trailingIDs,
            draggedTile: draggedTile,
            draggedPinnedDestinationIndex:
                internalDrag.pinnedDestinationIndex,
            draggedTrailingDestinationIndex:
                internalDrag.trailingDestinationIndex,
            draggedAdditionalTileIDs:
                internalDrag.additionalTileIDs,
            draggedTileCanBecomePinned:
                draggedTile.flatMap(store.makePinnedItem(from:)) != nil,
            draggedTileCanBecomeTrailing:
                draggedTile.flatMap(store.makeTrailingItem(from:)) != nil,
            paletteDrag: editMode.paletteDrag,
            paletteDropDestination:
                editMode.paletteDropDestination,
            externalDragKind: dockDrag.kind,
            externalDestinationIndex: dockDrag.destinationIndex,
            externalDestinationSection:
                dockDrag.destinationSection,
            externalDocumentTargetTileID:
                dockDrag.documentTargetTileID,
            handoffSuggestion: dockBadges.handoffSuggestion
        )

        let nextPresentedTiles =
            snapshot.presentedTiles.replacingItems(
                composition.tiles
            )
        let nextSnapshot = Snapshot(
            presentedTiles: nextPresentedTiles,
            pinnedBaseTiles: composition.pinnedBaseTiles,
            trailingTiles: composition.trailingTiles,
            separatesHandoffDock:
                preferences.separateHandoffDock
        )
        if nextSnapshot != snapshot {
            snapshot = nextSnapshot
        }
    }
}

@MainActor
private enum DockPresentationComposer {
    private static let logger = Logger(
        subsystem: "gt.quintero.Docky",
        category: "DockPresentation"
    )

    struct Composition {
        let tiles: [Tile]
        let pinnedBaseTiles: [Tile]
        let trailingTiles: [Tile]
    }

    static func compose(
        baseTiles: [Tile],
        pinnedTileIDs: Set<String>,
        trailingTileIDs: Set<String>,
        draggedTile: Tile?,
        draggedPinnedDestinationIndex: Int?,
        draggedTrailingDestinationIndex: Int?,
        draggedAdditionalTileIDs: [String],
        draggedTileCanBecomePinned: Bool,
        draggedTileCanBecomeTrailing: Bool,
        paletteDrag: DockEditPaletteDrag?,
        paletteDropDestination: DockEditDropDestination?,
        externalDragKind: DockDragService.Kind?,
        externalDestinationIndex: Int?,
        externalDestinationSection: DockDragService.Section?,
        externalDocumentTargetTileID: String?,
        handoffSuggestion: DockHandoffSuggestion?
    ) -> Composition {
        let draggedTileID = draggedTile?.id
        let additionalTileIDs = Set(draggedAdditionalTileIDs)
        let palettePreview = paletteDrag.flatMap(
            palettePreviewTile(for:)
        )

        let pinnedTiles = baseTiles.filter {
            pinnedTileIDs.contains($0.id)
        }
        let trailingTiles = baseTiles.filter {
            trailingTileIDs.contains($0.id)
        }

        let activePinnedDestinationIndex: Int? = {
            if draggedTileID != nil {
                return draggedPinnedDestinationIndex
            }
            if externalDestinationSection == .pinned {
                return externalDestinationIndex
            }
            guard paletteDropDestination?.section == .pinned else {
                return nil
            }
            return paletteDropDestination?.index
        }()

        var pinnedBaseTiles = pinnedTiles.filter {
            !additionalTileIDs.contains($0.id)
        }
        // A cross-section move has one canonical placeholder: the
        // destination. Remove the source-section copy before insertion so
        // stable identity and natural extent cannot depend on duplicate IDs.
        if let draggedTileID,
           draggedTrailingDestinationIndex != nil {
            pinnedBaseTiles.removeAll {
                $0.id == draggedTileID
            }
        }
        if let activePinnedDestinationIndex {
            if let draggedTileID {
                pinnedBaseTiles.removeAll { $0.id == draggedTileID }
            }
            let index = min(
                max(activePinnedDestinationIndex, 0),
                pinnedBaseTiles.count
            )
            if let draggedTile,
               pinnedTileIDs.contains(draggedTile.id)
                    || draggedTileCanBecomePinned {
                pinnedBaseTiles.insert(draggedTile, at: index)
            } else if let palettePreview {
                pinnedBaseTiles.insert(palettePreview, at: index)
            } else if case let .app(_, appTile) = externalDragKind {
                pinnedBaseTiles.insert(
                    Tile(
                        id: "drop-preview",
                        content: .app(appTile)
                    ),
                    at: index
                )
            }
        }

        let groupedOpenedAppTilesByFolderID =
            Dictionary(
                grouping: baseTiles.compactMap {
                    tile -> (String, Tile)? in
                    guard case .app = tile.content,
                          let folderID =
                            groupedOpenedAppFolderID(
                                for: tile.id
                            ) else {
                        return nil
                    }
                    return (folderID, tile)
                },
                by: { $0.0 }
            )
            .mapValues { $0.map(\.1) }

        let draggedAppFolderIdentifier: String? = {
            guard let draggedTile,
                  case .appFolder(let folder) =
                    draggedTile.content else {
                return nil
            }
            return folder.identifier
        }()

        var expandedPinnedTiles: [Tile] = []
        for tile in pinnedBaseTiles {
            expandedPinnedTiles.append(tile)
            guard case .appFolder(let folder) = tile.content,
                  folder.identifier
                    != draggedAppFolderIdentifier else {
                continue
            }
            expandedPinnedTiles.append(
                contentsOf:
                    (groupedOpenedAppTilesByFolderID[
                        folder.identifier
                    ] ?? [])
                    .filter {
                        $0.id != draggedTileID
                            && !additionalTileIDs.contains($0.id)
                    }
            )
        }

        let activeTrailingDestinationIndex: Int? = {
            if draggedTileID != nil {
                return draggedTrailingDestinationIndex
            }
            if externalDestinationSection == .trailing {
                return externalDestinationIndex
            }
            guard paletteDropDestination?.section == .trailing else {
                return nil
            }
            return paletteDropDestination?.index
        }()

        var previewTrailingTiles = trailingTiles.filter {
            !additionalTileIDs.contains($0.id)
        }
        if let draggedTileID,
           draggedPinnedDestinationIndex != nil {
            previewTrailingTiles.removeAll {
                $0.id == draggedTileID
            }
        }
        if let activeTrailingDestinationIndex {
            if let draggedTileID {
                previewTrailingTiles.removeAll {
                    $0.id == draggedTileID
                }
            }
            let index = min(
                max(activeTrailingDestinationIndex, 0),
                previewTrailingTiles.count
            )
            if let draggedTile,
               draggedTileCanBecomeTrailing {
                previewTrailingTiles.insert(draggedTile, at: index)
            } else if let palettePreview,
                      paletteDragCanBecomeTrailing(paletteDrag) {
                previewTrailingTiles.insert(
                    palettePreview,
                    at: index
                )
            } else if externalDocumentTargetTileID == nil,
                      case let .folder(_, folderTile) =
                        externalDragKind {
                previewTrailingTiles.insert(
                    Tile(
                        id: "drop-preview",
                        content: .folder(folderTile)
                    ),
                    at: index
                )
            }
        }

        let minimizedWindowTiles = baseTiles.filter {
            if case .minimizedWindow = $0.content {
                return true
            }
            return false
        }
        var trailingSectionTiles: [Tile] = []
        var insertedMinimizedWindows = false
        for tile in previewTrailingTiles {
            if !insertedMinimizedWindows,
               case .trash = tile.content {
                trailingSectionTiles.append(
                    contentsOf: minimizedWindowTiles
                )
                insertedMinimizedWindows = true
            }
            trailingSectionTiles.append(tile)
        }
        if !insertedMinimizedWindows {
            trailingSectionTiles.append(
                contentsOf: minimizedWindowTiles
            )
        }

        var resolvedTiles: [Tile] = []
        if let firstTile = baseTiles.first {
            let leadsWithFinder =
                firstTile.id == "pinned:com.apple.finder"
            if leadsWithFinder {
                resolvedTiles.append(firstTile)
            }
            resolvedTiles.append(contentsOf: expandedPinnedTiles)

            var appendedTrailingSection = false
            let remainingTiles: ArraySlice<Tile> =
                leadsWithFinder
                    ? baseTiles.dropFirst()
                    : baseTiles[...]
            for tile in remainingTiles {
                if appendedTrailingSection {
                    continue
                }
                if draggedPinnedDestinationIndex
                    != nil,
                   (
                    tile.id == draggedTileID
                        || additionalTileIDs
                        .contains(tile.id)
                   ) {
                    // A running/unpinned app being promoted has one preview
                    // identity in `pinnedBaseTiles`. Suppress its original
                    // running-strip copy instead of relying on `uniqueTiles`
                    // to discard a duplicate after composition.
                    continue
                }
                if groupedOpenedAppFolderID(for: tile.id) != nil {
                    continue
                }
                if tile.id == "divider:trailing" {
                    resolvedTiles.append(tile)
                    resolvedTiles.append(
                        contentsOf: trailingSectionTiles
                    )
                    appendedTrailingSection = true
                    continue
                }
                if pinnedTileIDs.contains(tile.id)
                    || trailingTileIDs.contains(tile.id) {
                    continue
                }
                resolvedTiles.append(tile)
            }
        }

        resolvedTiles =
            TileStore.applyingThemeLayoutInsertions(
                to: resolvedTiles
            )

        let handoffTile = handoffSuggestion.map {
            Tile(
                id: DockBadgeService.handoffTileID,
                content: .app(
                    AppTile(
                        bundleIdentifier: $0.bundleIdentifier,
                        displayName: $0.displayName
                    )
                )
            )
        }
        resolvedTiles = PresentedTileReducer.applyingTransient(
            to: resolvedTiles,
            transient: handoffTile,
            transientID: DockBadgeService.handoffTileID,
            insertionBeforeID: "divider:trailing",
            id: \.id
        )

        return Composition(
            tiles: uniqueTiles(resolvedTiles),
            pinnedBaseTiles: pinnedBaseTiles,
            trailingTiles: previewTrailingTiles
        )
    }

    private static func uniqueTiles(_ tiles: [Tile]) -> [Tile] {
        var seen: Set<String> = []
        var duplicateIDs: [String] = []
        let unique = tiles.filter { tile in
            let inserted = seen.insert(tile.id).inserted
            if !inserted {
                duplicateIDs.append(tile.id)
            }
            return inserted
        }
        if !duplicateIDs.isEmpty {
            logger.fault(
                "Canonical presentation rejected duplicate tile IDs: \(duplicateIDs.joined(separator: ","), privacy: .public)"
            )
        }
        return unique
    }

    private static func groupedOpenedAppFolderID(
        for tileID: String
    ) -> String? {
        guard tileID.hasPrefix("folder-running:") else {
            return nil
        }
        let suffix = tileID.dropFirst("folder-running:".count)
        guard let separatorIndex = suffix.lastIndex(of: ":") else {
            return nil
        }
        return String(suffix[..<separatorIndex])
    }

    private static func paletteDragCanBecomeTrailing(
        _ paletteDrag: DockEditPaletteDrag?
    ) -> Bool {
        guard let paletteDrag else { return false }
        switch paletteDrag.item {
        case .launchpad, .startMenu:
            return false
        case .spacer, .flexibleSpacer, .divider,
             .widget, .smartStack:
            return true
        }
    }

    fileprivate static func palettePreviewTile(
        for paletteDrag: DockEditPaletteDrag
    ) -> Tile {
        switch paletteDrag.item {
        case .launchpad:
            return Tile(
                id: "editor-preview:launchpad",
                content: .launchpad(
                    LaunchpadTile(
                        identifier: "editor-preview:launchpad"
                    )
                )
            )
        case .startMenu:
            return Tile(
                id: "editor-preview:start-menu",
                content: .startMenu(
                    StartMenuTile(
                        identifier: "editor-preview:start-menu"
                    )
                )
            )
        case .spacer:
            return Tile(
                id: "editor-preview:spacer",
                content: .spacer
            )
        case .flexibleSpacer:
            return Tile(
                id: "editor-preview:flexible-spacer",
                content: .spacer
            )
        case .divider:
            return Tile(
                id: "editor-preview:divider",
                content: .divider
            )
        case .widget(let ownerBundleIdentifier, let kind):
            return Tile(
                id: "editor-preview:widget",
                content: .widget(
                    WidgetTile(
                        identifier: "editor-preview:widget",
                        title: kind.title,
                        kind: kind,
                        ownerBundleIdentifier:
                            ownerBundleIdentifier,
                        span: resolvedPaletteWidgetSpan(
                            ownerBundleIdentifier:
                                ownerBundleIdentifier,
                            kind: kind,
                            requestedSpan:
                                paletteDrag.widgetSpan
                        )
                    )
                )
            )
        case .smartStack:
            return Tile(
                id: "editor-preview:smart-stack",
                content: .smartStack(
                    SmartStackTile(
                        identifier: "editor-preview:smart-stack",
                        title: "Smart Stack",
                        widgets:
                            WidgetCatalog
                            .smartStackRegistrations
                            .map { $0.makeTile() },
                        span: .three
                    )
                )
            )
        }
    }

    private static func resolvedPaletteWidgetSpan(
        ownerBundleIdentifier: String,
        kind: WidgetKind,
        requestedSpan: TileSpan?
    ) -> TileSpan {
        let supportedSpans = kind.supportedSpans
        if let requestedSpan,
           supportedSpans.contains(requestedSpan) {
            return requestedSpan
        }
        if let catalogSpan =
            WidgetCatalog.staticRegistrations.first(where: {
                $0.ownerBundleIdentifier
                    == ownerBundleIdentifier
                    && $0.kind == kind
            })?.defaultSpan,
           supportedSpans.contains(catalogSpan) {
            return catalogSpan
        }
        return supportedSpans.last ?? .one
    }
}
