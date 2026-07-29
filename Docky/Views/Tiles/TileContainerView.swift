//
//  TileContainerView.swift
//  Docky
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct DockTileSurfaceContentLayout: Equatable {
    let primarySize: CGSize
    let handoffSize: CGSize
    let interDockGap: CGFloat
    let combinedSize: CGSize
}

struct TileContainerView: View {
    static let edgePadding: CGFloat = 8
    static let handoffDockEdgePadding: CGFloat = 4
    static let handoffDockGap: CGFloat = 10
    private let tileMutationAnimation: Animation = .easeInOut(duration: 0.18)
    private static let logger = Logger(subsystem: "gt.quintero.Docky", category: "TileDrag")

    @ObservedObject private var store = TileStore.shared
    private let dockSettings = DockSettingsService.shared
    @ObservedObject private var layout = DockLayoutService.shared
    @Bindable private var preferences = DockyPreferences.shared
    @Bindable private var profileService = ProfileService.shared
    @ObservedObject private var editMode = DockEditModeService.shared
    @ObservedObject private var dockDrag = DockDragService.shared
    @ObservedObject private var presentation =
        DockPresentationService.shared
    @ObservedObject private var spaceInteractionEpoch =
        DockSpaceInteractionEpoch.shared
    private let magnification = DockMagnificationService.shared

    @State private var draggedProfileID: String?
    @State private var draggedProfileRevision: UInt64?
    @State private var draggedSpaceGeneration: UInt64?
    @State private var draggedTileOffset: CGFloat = 0
    @State private var draggedTileInitialFrame: CGRect?
    @State private var draggedAppFolderTargetTileID: String?
    @State private var draggedTrashTargetTileID: String?
    @State private var draggedPickupCandidateTileID: String?
    @State private var tileFrames: [String: CGRect] = [:]

    /// Structural drag state lives beside the canonical presentation
    /// snapshot. These accessors keep gesture code concise without letting
    /// the renderer own a second, private tile-composition state machine.
    private var draggedTileID: String? {
        get { presentation.draggedTileID }
        nonmutating set {
            presentation.draggedTileID = newValue
        }
    }

    private var draggedPinnedTileDestinationIndex: Int? {
        get {
            presentation.draggedPinnedTileDestinationIndex
        }
        nonmutating set {
            presentation.draggedPinnedTileDestinationIndex =
                newValue
        }
    }

    private var draggedTrailingTileDestinationIndex: Int? {
        get {
            presentation.draggedTrailingTileDestinationIndex
        }
        nonmutating set {
            presentation.draggedTrailingTileDestinationIndex =
                newValue
        }
    }

    private var draggedAdditionalTileIDs: [String] {
        get { presentation.draggedAdditionalTileIDs }
        nonmutating set {
            presentation.draggedAdditionalTileIDs = newValue
        }
    }

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif

        GeometryReader { proxy in
            overflowWrappedContent(in: proxy)
            .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
            .onAppear { layout.setTileCanvasFrame(proxy.frame(in: .global)) }
            .onChange(of: proxy.frame(in: .global)) { frame in
                layout.setTileCanvasFrame(frame)
            }
            .onChange(of: dockDrag.cursorLocation) { location in
                updateExternalDragDestinationIndex(at: location)
                updatePaletteDropDestinationFromCursor(at: location)
            }
            .onChange(of: dockDrag.kind) { kind in
                if kind == nil {
                    dockDrag.destinationIndex = nil
                } else {
                    updateExternalDragDestinationIndex(at: dockDrag.cursorLocation)
                }
            }
            .onChange(of: editMode.paletteDrag) { paletteDrag in
                if paletteDrag == nil {
                    editMode.paletteDropDestination = nil
                } else {
                    updatePaletteDropDestinationFromCursor(at: dockDrag.cursorLocation)
                }
            }
            .onChange(of: profileService.activeProfileID) { _ in
                invalidateDragForProfileChange()
            }
            .onChange(of: profileService.stateRevision) { _ in
                invalidateDragForProfileChange()
            }
            .onChange(of: spaceInteractionEpoch.generation) { _ in
                invalidateDragForSpaceChange()
            }
            .onChange(of: preferences.tileHoverEffectsEnabled) { isEnabled in
                if !isEnabled {
                    magnification.clearPointer()
                }
            }
            .animation(tileMutationAnimation, value: displayTiles)
        }
    }

    @ViewBuilder
    private func overflowWrappedContent(in proxy: GeometryProxy) -> some View {
        tileCanvas(in: proxy)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tileCanvas(in proxy: GeometryProxy) -> some View {
        let scrollableSectionLayout = scrollableSectionLayout(in: proxy)

        let axisOffset = contentAxisOffset
        return ZStack(alignment: .topLeading) {
            contentStack(scrollableSectionLayout: scrollableSectionLayout)
                .offset(
                    x: position.isVertical ? 0 : axisOffset,
                    y: position.isVertical ? axisOffset : 0
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: contentAlignment(in: proxy, scrollableSectionLayout: scrollableSectionLayout)
                )

            draggedTileOverlay
        }
        .background(TileDragKeyMonitor(keyDownHandler: handleDragKeyDown))
    }

    @ViewBuilder
    private func contentStack(scrollableSectionLayout: ScrollableSectionLayout?) -> some View {
        if position.isVertical {
            VStack(
                alignment: stackHorizontalAlignment,
                spacing: effectiveHandoffDockGap
            ) {
                primaryDockSurface(
                    scrollableSectionLayout:
                        scrollableSectionLayout
                )
                handoffDockSurface
            }
        } else {
            HStack(
                alignment: stackVerticalAlignment,
                spacing: effectiveHandoffDockGap
            ) {
                primaryDockSurface(
                    scrollableSectionLayout:
                        scrollableSectionLayout
                )
                handoffDockSurface
            }
        }
    }

    @ViewBuilder
    private func primaryDockSurface(
        scrollableSectionLayout:
            ScrollableSectionLayout?
    ) -> some View {
        if position.isVertical {
            VStack(
                alignment: stackHorizontalAlignment,
                spacing: effectiveTileSpacing
            ) {
                contentComponents(
                    scrollableSectionLayout:
                        scrollableSectionLayout
                )
            }
            .padding(.vertical, effectiveEdgePadding)
            .frame(
                height:
                    layout.chromeSurfaces
                        .constrainsPrimaryAxis
                    ? layout.chromeSurfaces.primarySize.height
                    : nil
            )
        } else {
            HStack(
                alignment: stackVerticalAlignment,
                spacing: effectiveTileSpacing
            ) {
                contentComponents(
                    scrollableSectionLayout:
                        scrollableSectionLayout
                )
            }
            .padding(.horizontal, effectiveEdgePadding)
            .frame(
                width:
                    layout.chromeSurfaces
                        .constrainsPrimaryAxis
                    ? layout.chromeSurfaces.primarySize.width
                    : nil
            )
        }
    }

    @ViewBuilder
    private var handoffDockSurface: some View {
        if !handoffDisplayTiles.isEmpty {
            if position.isVertical {
                VStack(
                    alignment: stackHorizontalAlignment,
                    spacing: effectiveTileSpacing
                ) {
                    ForEach(handoffDisplayTiles) { tile in
                        tileView(for: tile)
                    }
                }
                .padding(
                    .vertical,
                    effectiveHandoffDockEdgePadding
                )
            } else {
                HStack(
                    alignment: stackVerticalAlignment,
                    spacing: effectiveTileSpacing
                ) {
                    ForEach(handoffDisplayTiles) { tile in
                        tileView(for: tile)
                    }
                }
                .padding(
                    .horizontal,
                    effectiveHandoffDockEdgePadding
                )
            }
        }
    }

    private func contentAlignment(in proxy: GeometryProxy, scrollableSectionLayout: ScrollableSectionLayout?) -> Alignment {
        switch position {
        case .bottom:
            return .bottom
        case .top:
            return .top
        case .left:
            return .leading
        case .right:
            return .trailing
        }
    }

    @ViewBuilder
    private func contentComponents(scrollableSectionLayout: ScrollableSectionLayout?) -> some View {
        let count = Double(layoutComponents.count)
        ForEach(layoutComponents) { component in
            componentView(component, scrollableSectionLayout: scrollableSectionLayout)
                .zIndex(count - Double(component.index ?? 0))
        }
    }

    @ViewBuilder
    private func componentView(_ component: TileLayoutComponent, scrollableSectionLayout: ScrollableSectionLayout?) -> some View {
        switch component {
        case .divider(let tile):
            tileView(for: tile)
                .zIndex(-1)
        case .section(let section):
            if let scrollableSectionLayout, scrollableSectionLayout.id == section.id {
                scrollableSectionView(section, axisLength: scrollableSectionLayout.axisLength)
            } else {
                sectionTilesView(section.tiles)
            }
        }
    }

    @ViewBuilder
    private func scrollableSectionView(_ section: TileLayoutSection, axisLength: CGFloat) -> some View {
        let leadingScrollInset = scrollContentLeadingInset(for: section)
        let trailingScrollInset = scrollContentTrailingInset(for: section)

        ScrollViewReader { scrollProxy in
            ScrollView(scrollAxes, showsIndicators: false) {
                if position.isVertical {
                    sectionTilesView(section.tiles)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, leadingScrollInset)
                        .padding(.bottom, trailingScrollInset)
                } else {
                    sectionTilesView(section.tiles)
                        .padding(.leading, leadingScrollInset)
                        .padding(.trailing, trailingScrollInset)
                }
            }
            .padding(position.isVertical ? .bottom : .trailing, -trailingScrollInset)
            .padding(position.isVertical ? .top : .leading, -leadingScrollInset)
            .frame(
                width: position.isVertical ? nil : axisLength,
                height: position.isVertical ? axisLength : nil
            )
            .onAppear {
                scrollSectionToEnd(section, using: scrollProxy)
            }
            .onChange(of: section.tiles.map(\.id)) { _ in
                scrollSectionToEnd(section, using: scrollProxy)
            }
        }
    }

    @ViewBuilder
    private func sectionTilesView(_ tiles: [Tile]) -> some View {
        if position.isVertical {
            VStack(alignment: stackHorizontalAlignment, spacing: effectiveTileSpacing) {
                ForEach(tiles) { tile in
                    tileView(for: tile)
                }
            }
        } else {
            HStack(alignment: stackVerticalAlignment, spacing: effectiveTileSpacing) {
                ForEach(tiles) { tile in
                    tileView(for: tile)
                }
            }
        }
    }

    @ViewBuilder
    private func tileView(for tile: Tile) -> some View {
        let iconSize = magnifiedIconSize(for: tile)
        let size = magnifiedTileFrame(for: tile, iconSize: iconSize)
        // A flexible spacer's main-axis size is unbounded so the surrounding
        // HStack/VStack distributes leftover chrome space to it. Its natural
        // (`size`) extent acts as the minimum so the spacer is still visible
        // when the dock is content-sized.
        let isFlexible = tile.content == .flexibleSpacer
        let isHorizontal = !position.isVertical
        TileView(
            tile: tile,
            isDocumentDropTarget: dockDrag.documentTargetTileID == tile.id,
            isAppFolderDropTarget: draggedAppFolderTargetTileID == tile.id,
            isTrashDropTarget: draggedTrashTargetTileID == tile.id,
            renderedTileSize: iconSize
        )
            .frame(
                minWidth: isFlexible && isHorizontal ? size.width : nil,
                maxWidth: isFlexible && isHorizontal ? .infinity : nil,
                minHeight: isFlexible && !isHorizontal ? size.height : nil,
                maxHeight: isFlexible && !isHorizontal ? .infinity : nil
            )
            .frame(
                width: isFlexible && isHorizontal ? nil : size.width,
                height: isFlexible && !isHorizontal ? nil : size.height
            )
            .opacity(isHiddenForActiveDrag(tileID: tile.id) ? 0 : 1)
            .background(alignment: .topLeading) {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TileFramePreferenceKey.self,
                        value: [tile.id: proxy.frame(in: .global)]
                    )
                }
            }
            // simultaneousGesture (not gesture) so the parent reorder drag
            // shares events with TileView's inner onTapGesture instead of
            // competing for them. With `.gesture()`, the parent claims
            // mouse-down and starves the inner tap even when the drag
            // never recognizes. For non-draggable tiles we mask the
            // gesture off so only subview gestures run.
            .simultaneousGesture(reorderGesture(for: tile), including: isTileDraggable(tile) ? .all : .subviews)
            .transition(tileTransition)
    }

    @ViewBuilder
    private var draggedTileOverlay: some View {
        if let draggedTile {
            let size = Self.size(
                for: draggedTile,
                tileSize: effectiveTileSize,
                tileHeight: tileHeight,
                tileSpacing: effectiveTileSpacing,
                position: position,
                compactWidgets: layout.compactsWidgetsForOverflow
            )
            ZStack {
                draggedSelectionStackPreview(size: size)

                TileView(tile: draggedTile, isDragging: true)
                    .frame(width: size.width, height: size.height)
            }
                .position(draggedTilePosition)
                .offset(axisSize(value: draggedTileOffset))
                .zIndex(10)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func draggedSelectionStackPreview(size: CGSize) -> some View {
        let additionalBundleIdentifiers = draggedPreviewAdditionalBundleIdentifiers
        if !additionalBundleIdentifiers.isEmpty {
            ForEach(Array(additionalBundleIdentifiers.enumerated()), id: \.element) { index, bundleIdentifier in
                let depth = additionalBundleIdentifiers.count - index
                AppTileView(
                    tile: AppTile(bundleIdentifier: bundleIdentifier, displayName: ""),
                    clipShape: preferences.effectiveTileClipShape,
                    transparencyCompensationInset: dragPreviewStackTileChromeInset
                )
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(dragPreviewStackRotationDegrees(for: depth)))
                .offset(
                    x: dragPreviewStackOffset(for: depth),
                    y: dragPreviewStackOffset(for: depth + 1)
                )
            }
        }
    }

    private var displayTiles: [Tile] {
        presentation.snapshot.items
    }

    private var dockPartition:
        PresentedTileDockPartition<Tile> {
        presentation.snapshot.dockPartition
    }

    private var mainDisplayTiles: [Tile] {
        dockPartition.mainItems
    }

    private var handoffDisplayTiles: [Tile] {
        dockPartition.handoffItems
    }

    private var surfaceOrderedDisplayTiles: [Tile] {
        mainDisplayTiles + handoffDisplayTiles
    }

    private var pinnedTiles: [Tile] {
        store.tiles.filter { isPinnedReorderable(tileID: $0.id) }
    }

    private var pinnedTileIDs: [String] {
        pinnedTiles.map(\.id)
    }

    private var trailingTiles: [Tile] {
        store.tiles.filter { isTrailingReorderable(tileID: $0.id) }
    }

    private var trailingTileIDs: [String] {
        trailingTiles.map(\.id)
    }

    private var previewPinnedBaseTiles: [Tile] {
        presentation.snapshot.pinnedBaseTiles
    }

    private var previewTrailingTiles: [Tile] {
        presentation.snapshot.trailingTiles
    }

    private var draggedTile: Tile? {
        guard let draggedTileID else {
            return nil
        }

        return store.tiles.first { $0.id == draggedTileID }
    }

    private var orderedDraggedSelectionTileIDs: [String] {
        var result: [String] = []
        if let draggedTileID {
            result.append(draggedTileID)
        }

        for tileID in draggedAdditionalTileIDs where !result.contains(tileID) {
            result.append(tileID)
        }

        return result
    }

    private var draggedSelectionTileIDs: Set<String> {
        Set(orderedDraggedSelectionTileIDs)
    }

    private var draggedSelectionBundleIdentifiers: [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for tileID in orderedDraggedSelectionTileIDs {
            guard let bundleIdentifier = bundleIdentifier(forTileID: tileID),
                  seen.insert(bundleIdentifier).inserted else {
                continue
            }
            result.append(bundleIdentifier)
        }

        return result
    }

    private var draggedPreviewAdditionalBundleIdentifiers: [String] {
        Array(draggedSelectionBundleIdentifiers.dropFirst().suffix(3))
    }

    private var isCollectingAdditionalAppsDuringDrag: Bool {
        draggedBundleIdentifier != nil
    }

    private var hasCollectedAdditionalAppsDuringDrag: Bool {
        !draggedAdditionalTileIDs.isEmpty
    }

    private var draggedTilePosition: CGPoint {
        guard let frame = draggedTileInitialFrame else {
            return .zero
        }

        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private var tileTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.9, anchor: tileScaleAnchor).combined(with: .opacity),
            removal: .scale(scale: 0.9, anchor: tileScaleAnchor).combined(with: .opacity)
        )
    }

    private var tileScaleAnchor: UnitPoint {
        switch position {
        case .top:
            .top
        case .left:
            .leading
        case .right:
            .trailing
        case .bottom:
            .bottom
        }
    }

    private var scrollAxes: Axis.Set {
        position.isVertical ? .vertical : .horizontal
    }

    private var layoutComponents: [TileLayoutComponent] {
        var components: [TileLayoutComponent] = []
        var currentSectionID = "primary"
        var currentTiles: [Tile] = []

        func appendCurrentSection() {
            guard !currentTiles.isEmpty else { return }
            let idx = components.count
            components.append(.section(TileLayoutSection(index: idx, id: currentSectionID, tiles: currentTiles)))
            currentTiles = []
        }

        for tile in mainDisplayTiles {
            if tile.id == "divider:running" || tile.id == "divider:trailing" {
                appendCurrentSection()
                components.append(.divider(tile))
                currentSectionID = tile.id == "divider:running" ? "running" : "trailing"
                continue
            }

            currentTiles.append(tile)
        }

        appendCurrentSection()
        return components
    }

    private var layoutSections: [TileLayoutSection] {
        layoutComponents.compactMap { component in
            if case .section(let section) = component {
                return section
            }
            return nil
        }
    }

    private func scrollableSectionLayout(in proxy: GeometryProxy) -> ScrollableSectionLayout? {
        guard preferences.overflowBehavior == .scroll else {
            return nil
        }

        let components = layoutComponents
        let resolvedPrimaryAxisLength = projected(
            size: layout.chromeSurfaces.primarySize
        )
        let availableAxisLength =
            resolvedPrimaryAxisLength > 0
            ? resolvedPrimaryAxisLength
            : projected(size: proxy.size)
        guard totalAxisLength(for: components) > availableAxisLength else {
            return nil
        }

        let sections = components.compactMap { component -> TileLayoutSection? in
            if case .section(let section) = component {
                return section
            }
            return nil
        }
        guard let largestSection = sections.max(by: { axisLength(of: $0.tiles) < axisLength(of: $1.tiles) }) else {
            return nil
        }

        let viewportAxisLength = scrollableSectionAxisLength(
            for: largestSection.id,
            in: components,
            availableAxisLength: availableAxisLength
        )
        guard viewportAxisLength > 0 else {
            return nil
        }

        return ScrollableSectionLayout(index: largestSection.index, id: largestSection.id, axisLength: viewportAxisLength)
    }

    private func totalAxisLength(for components: [TileLayoutComponent]) -> CGFloat {
        let componentLengths = components.reduce(CGFloat(0)) { partialResult, component in
            partialResult + axisLength(of: component)
        }
        let spacings = CGFloat(max(0, components.count - 1)) * effectiveTileSpacing
        return componentLengths + spacings + effectiveEdgePadding * 2
    }

    private var presentedRestAxisLayout:
        PresentedTileDockAxisLayout {
        PresentedTileDockAxisMetrics.measure(
            mainItemExtents: mainDisplayTiles.map {
                projected(
                    size: Self.size(
                        for: $0,
                        tileSize: effectiveTileSize,
                        tileHeight: tileHeight,
                        tileSpacing: effectiveTileSpacing,
                        position: position,
                        compactWidgets:
                            layout.compactsWidgetsForOverflow
                    )
                )
            },
            handoffItemExtents: handoffDisplayTiles.map {
                projected(
                    size: Self.size(
                        for: $0,
                        tileSize: effectiveTileSize,
                        tileHeight: tileHeight,
                        tileSpacing: effectiveTileSpacing,
                        position: position,
                        compactWidgets:
                            layout.compactsWidgetsForOverflow
                    )
                )
            },
            itemSpacing: effectiveTileSpacing,
            mainEdgePadding: effectiveEdgePadding,
            handoffEdgePadding:
                effectiveHandoffDockEdgePadding,
            interDockGap: effectiveHandoffDockGap
        )
    }

    private func scrollableSectionAxisLength(
        for sectionID: String,
        in components: [TileLayoutComponent],
        availableAxisLength: CGFloat
    ) -> CGFloat {
        let innerAvailableAxisLength = max(0, availableAxisLength - effectiveEdgePadding * 2)
        let spacings = CGFloat(max(0, components.count - 1)) * effectiveTileSpacing
        let fixedAxisLength = components.reduce(CGFloat(0)) { partialResult, component in
            switch component {
            case .section(let section) where section.id == sectionID:
                partialResult
            default:
                partialResult + axisLength(of: component)
            }
        }
        return max(0, innerAvailableAxisLength - fixedAxisLength - spacings)
    }

    private func axisLength(of component: TileLayoutComponent) -> CGFloat {
        switch component {
        case .divider(let tile):
            let size = Self.size(
                for: tile,
                tileSize: effectiveTileSize,
                tileHeight: tileHeight,
                tileSpacing: effectiveTileSpacing,
                position: position,
                compactWidgets: layout.compactsWidgetsForOverflow
            )
            return projected(size: size)
        case .section(let section):
            return axisLength(of: section.tiles)
        }
    }

    private func axisLength(of tiles: [Tile]) -> CGFloat {
        let size = Self.contentSize(
            tiles: tiles,
            tileSize: effectiveTileSize,
            tileHeight: tileHeight,
            tileSpacing: effectiveTileSpacing,
            position: position,
            compactWidgets: layout.compactsWidgetsForOverflow,
            edgePadding: 0
        )
        return projected(size: size)
    }

    private func scrollSectionToEnd(_ section: TileLayoutSection, using scrollProxy: ScrollViewProxy) {
        guard draggedTileID == nil,
              editMode.paletteDrag == nil,
              let lastTileID = section.tiles.last?.id else {
            return
        }

        DispatchQueue.main.async {
            scrollProxy.scrollTo(lastTileID, anchor: sectionScrollAnchor)
        }
    }

    private var sectionScrollAnchor: UnitPoint {
        position.isVertical ? .bottom : .trailing
    }

    private func scrollContentLeadingInset(for section: TileLayoutSection) -> CGFloat {
        guard layoutSections.first?.id == section.id else {
            return 0
        }

        return effectiveEdgePadding
    }

    private func scrollContentTrailingInset(for section: TileLayoutSection) -> CGFloat {
        if layoutSections.last?.id == section.id {
            return effectiveEdgePadding
        }

        if preferences.effectiveShowsActivePinnedSeparator, section.id == "primary" {
            return effectiveTileSize * 0.25
        }

        return 0
    }

    private var effectiveEdgePadding: CGFloat {
        layout.scaled(Self.edgePadding)
    }

    private var effectiveHandoffDockEdgePadding: CGFloat {
        layout.scaled(Self.handoffDockEdgePadding)
    }

    private var effectiveHandoffDockGap: CGFloat {
        handoffDisplayTiles.isEmpty
            ? 0
            : layout.scaled(Self.handoffDockGap)
    }

    private var effectiveTileSize: CGFloat {
        layout.scaled(baseTileSize)
    }

    private var effectiveTileSpacing: CGFloat {
        layout.scaled(preferences.effectiveTileSpacing)
    }

    private var dragPreviewStackTileChromeInset: CGFloat {
        floor(effectiveTileSize * 3 / 32)
    }

    private func dragPreviewStackRotationDegrees(for depth: Int) -> Double {
        let magnitude = Double(depth) * (Double(depth) + 0.5)
        return depth.isMultiple(of: 2) ? magnitude : -magnitude
    }
    
    private func dragPreviewStackOffset(for depth: Int) -> Double {
        let magnitude = Double(depth) * 2.5
        return depth.isMultiple(of: 2) ? magnitude : -magnitude
    }

    private var tileHeight: CGFloat {
        effectiveTileSize + layout.scaled(preferences.effectiveTileVerticalPadding) * 2
    }

    private var baseTileSize: CGFloat {
        dockSettings.effectiveTileSize
    }

    private var position: ResolvedDockWindowPosition {
        preferences.windowPosition.resolved(systemOrientation: dockSettings.orientation)
    }

    /// Cross-axis alignment that pushes tiles toward the screen edge the
    /// dock is anchored to, so magnified icons grow inward (away from the
    /// edge) instead of bleeding off-screen.
    private var stackVerticalAlignment: VerticalAlignment {
        switch position {
        case .top: return .top
        case .bottom: return .bottom
        case .left, .right: return .center
        }
    }

    private var stackHorizontalAlignment: HorizontalAlignment {
        switch position {
        case .left: return .leading
        case .right: return .trailing
        case .top, .bottom: return .center
        }
    }

    /// Magnification is suppressed in conditions where it would conflict
    /// with another interaction (edit mode, active drag) or when there's
    /// no headroom to grow into. Overflow rescaling does NOT disable it —
    /// when the dock is squished, magnification still pops icons up to
    /// the full `largeSize`, which is how Apple's Dock behaves. Scroll
    /// overflow IS disabled though: the section's scroll offset and
    /// clipped viewport make cursor-to-tile mapping unreliable.
    private var magnificationActive: Bool {
        guard TileHoverEffectsRuntimePolicy.allowsMagnification(
            isEnabled: preferences.tileHoverEffectsEnabled,
            configuredEnabled: dockSettings.effectiveMagnification
        ) else {
            return false
        }
        guard !editMode.isActive else { return false }
        guard draggedTileID == nil else { return false }
        guard dockSettings.effectiveLargeSize
            > dockSettings.effectiveTileSize else {
            return false
        }
        // Full-axis primary content has a fixed viewport. When a detached
        // Handoff capsule occupies the trailing edge, along-axis overflow
        // from magnification could otherwise draw through the transparent
        // gap and over the accessory surface.
        if preferences.effectiveWindowAxisSizing == .fullAxis,
           !handoffDisplayTiles.isEmpty {
            return false
        }
        if preferences.overflowBehavior == .scroll {
            let canvasAxisLength = projected(size: layout.tileCanvasFrame.size)
            if canvasAxisLength > 0,
               presentedRestAxisLayout.totalExtent
                    > canvasAxisLength {
                return false
            }
        }
        return true
    }

    /// Pointer position projected onto the dock's primary axis, expressed
    /// in *HStack-leading-relative* coords so it can be compared directly
    /// against the rest centers from `restAxisCenter(forTileID:)`. The
    /// HStack/VStack centers itself within the canvas when content fits,
    /// so we subtract that same leading gap from the cursor before doing
    /// any distance math. Without this, hovering over the first icon
    /// magnifies icons further inward by the centering offset.
    private var cursorAxisLocation: CGFloat? {
        guard magnificationActive,
              let pointer = magnification.pointerLocation else {
            return nil
        }
        let canvasOrigin = layout.tileCanvasFrame.origin
        let local = CGPoint(x: pointer.x - canvasOrigin.x, y: pointer.y - canvasOrigin.y)
        let cursorInCanvas = position.isVertical ? local.y : local.x

        let canvasAxisLength = projected(size: layout.tileCanvasFrame.size)
        let contentAxisLength =
            presentedRestAxisLayout.totalExtent
        guard contentAxisLength <= canvasAxisLength + 0.5 else {
            return cursorInCanvas
        }
        let leadingOffset =
            max(0, (canvasAxisLength - contentAxisLength) / 2)
            + surfaceGroupCenterOffset(handoffGrowth: 0)
        return cursorInCanvas - leadingOffset
    }

    private var magnificationModel: DockMagnificationModel {
        // baseSize is the scaled (possibly shrunken) resting extent so the
        // falloff lands cleanly at the rest size at the edge of the
        // influence radius. maxSize is the UNscaled `largeSize` so a
        // crowded, shrunken dock still pops icons up to their full
        // magnified size on hover — matching Apple's behavior.
        DockMagnificationModel(
            baseSize: effectiveTileSize,
            maxSize: dockSettings.effectiveLargeSize,
            influenceRadius: effectiveTileSize * 2.5,
            strength: magnification.strength,
            cursorAxisLocation: cursorAxisLocation
        )
    }

    /// Tiles that participate in magnification. Dividers keep their
    /// natural extent. Widgets/smart stacks (and apps showing a widget)
    /// only magnify when they're 1×1 — wider spans would have to scale
    /// non-uniformly to grow, which warps their content.
    private func shouldMagnify(_ tile: Tile) -> Bool {
        if tile.id == DockBadgeService.handoffTileID,
           preferences.effectiveWindowAxisSizing
                == .fullAxis {
            return false
        }
        switch tile.content {
        case .app(let app):
            if let widget = app.displayedWidget {
                return effectiveWidgetSpan(widget.span) == .one
            }
            return true
        case .folder, .trash, .appFolder, .minimizedWindow, .launchpad, .startMenu, .spacer, .flexibleSpacer:
            return true
        case .widget(let widget):
            return effectiveWidgetSpan(widget.span) == .one
        case .smartStack(let stack):
            return effectiveWidgetSpan(stack.span) == .one
        case .divider:
            return false
        }
    }

    private func effectiveWidgetSpan(_ span: TileSpan) -> TileSpan {
        Self.effectiveWidgetSpan(
            span,
            tileSize: effectiveTileSize,
            isVertical: position.isVertical,
            compactWidgets: layout.compactsWidgetsForOverflow
        )
    }

    /// Rest-axis center for a tile, computed by walking the flat display
    /// list with base sizes. Spacings are uniform across sections and
    /// dividers, so a single cumulative pass matches the rendered layout.
    private func restAxisCenter(forTileID id: String) -> CGFloat? {
        let tiles = surfaceOrderedDisplayTiles
        let spacing = effectiveTileSpacing
        var runningOffset: CGFloat =
            mainDisplayTiles.isEmpty
            ? effectiveHandoffDockEdgePadding
            : effectiveEdgePadding
        for (index, tile) in tiles.enumerated() {
            if index > 0 {
                runningOffset += interItemAxisGap(
                    before: index
                )
            }
            let restSize = Self.size(
                for: tile,
                tileSize: effectiveTileSize,
                tileHeight: tileHeight,
                tileSpacing: spacing,
                position: position,
                compactWidgets: layout.compactsWidgetsForOverflow
            )
            let extent = projected(size: restSize)
            if tile.id == id {
                return runningOffset + extent / 2
            }
            runningOffset += extent
        }
        return nil
    }

    private func interItemAxisGap(
        before index: Int
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        if !mainDisplayTiles.isEmpty,
           !handoffDisplayTiles.isEmpty,
           index == mainDisplayTiles.count {
            return effectiveEdgePadding
                + effectiveHandoffDockGap
                + effectiveHandoffDockEdgePadding
        }
        return effectiveTileSpacing
    }

    /// Icon-side extent for a tile after applying the magnification
    /// falloff. Returns the rest size when magnification is suppressed or
    /// the tile doesn't participate.
    private func magnifiedIconSize(for tile: Tile) -> CGFloat {
        guard magnificationActive,
              shouldMagnify(tile),
              let center = restAxisCenter(forTileID: tile.id) else {
            return effectiveTileSize
        }
        return magnificationModel.magnifiedExtent(
            restSize: effectiveTileSize,
            restAxisCenter: center
        )
    }

    private struct MagnificationWalk {
        /// Sum of (magnified − rest) extent over every tile along the
        /// dock axis. Strength is already baked in via the per-tile sizes.
        let totalGrowth: CGFloat
        let primaryGrowth: CGFloat
        let handoffGrowth: CGFloat
        /// Magnified axis position corresponding to the cursor's resting
        /// position, used by the anchor offset to keep the under-cursor
        /// icon pinned to the cursor.
        let anchoredMag: CGFloat
    }

    /// Walks every tile once. Produces both the per-frame
    /// `totalGrowth` (needed for chrome sizing) and the magnified cursor
    /// position (needed for the anchor offset).
    private func computeMagnificationWalk(cursor: CGFloat) -> MagnificationWalk {
        let tiles = surfaceOrderedDisplayTiles
        let spacing = effectiveTileSpacing
        let leadingPadding =
            mainDisplayTiles.isEmpty
            ? effectiveHandoffDockEdgePadding
            : effectiveEdgePadding
        var restCursor: CGFloat = leadingPadding
        var magCursor: CGFloat = leadingPadding
        var totalGrowth: CGFloat = 0
        var primaryGrowth: CGFloat = 0
        var handoffGrowth: CGFloat = 0
        var anchoredMag: CGFloat? = nil

        if cursor < leadingPadding {
            anchoredMag = cursor
        }

        for (index, tile) in tiles.enumerated() {
            if index > 0 {
                let gap = interItemAxisGap(before: index)
                let restGapStart = restCursor
                restCursor += gap
                magCursor += gap
                if anchoredMag == nil, cursor < restCursor {
                    let denom = gap > 0 ? gap : 1
                    let fraction = (cursor - restGapStart) / denom
                    anchoredMag =
                        magCursor - gap + fraction * gap
                }
            }

            let restFrame = Self.size(
                for: tile,
                tileSize: effectiveTileSize,
                tileHeight: tileHeight,
                tileSpacing: spacing,
                position: position,
                compactWidgets: layout.compactsWidgetsForOverflow
            )
            let restSize = projected(size: restFrame)
            let iconSize = magnifiedIconSize(for: tile)
            let magSize: CGFloat
            if iconSize > effectiveTileSize {
                let magHeight = iconSize + (tileHeight - effectiveTileSize)
                magSize = projected(size: Self.size(
                    for: tile,
                    tileSize: iconSize,
                    tileHeight: magHeight,
                    tileSpacing: spacing,
                    position: position,
                    compactWidgets: layout.compactsWidgetsForOverflow
                ))
            } else {
                magSize = restSize
            }

            let restTileStart = restCursor
            let magTileStart = magCursor
            restCursor += restSize
            magCursor += magSize

            if anchoredMag == nil, cursor < restCursor {
                let denom = restSize > 0 ? restSize : 1
                let fraction = (cursor - restTileStart) / denom
                anchoredMag = magTileStart + fraction * magSize
            }

            let growth = magSize - restSize
            totalGrowth += growth
            if tile.id == DockBadgeService.handoffTileID {
                handoffGrowth += growth
            } else {
                primaryGrowth += growth
            }
        }

        return MagnificationWalk(
            totalGrowth: totalGrowth,
            primaryGrowth: primaryGrowth,
            handoffGrowth: handoffGrowth,
            anchoredMag: anchoredMag ?? (cursor + totalGrowth)
        )
    }

    /// Shift to apply to the entire tile stack so the icon under the
    /// cursor stays put as neighbors magnify. Also publishes the
    /// per-frame total along-axis growth to `DockChromeMetricsService`
    /// so the chrome can wrap tightly around whatever actually grew
    /// (handling edges and non-1×1 widgets precisely, not via the 5-icon
    /// constant approximation).
    ///
    /// Centered (small-layout) mode skips the anchor shift: SwiftUI's
    /// own centering already splits growth across both sides, so adding
    /// our own offset would double-correct. Total growth is still
    /// published either way.
    private var contentAxisOffset: CGFloat {
        guard magnificationActive,
              let cursor = cursorAxisLocation else {
            publishChromeGrowth(
                primary: 0,
                handoff: 0
            )
            return surfaceGroupCenterOffset(
                handoffGrowth: 0
            )
        }

        let walk = computeMagnificationWalk(cursor: cursor)
        publishChromeGrowth(
            primary: walk.primaryGrowth,
            handoff: walk.handoffGrowth
        )
        let placementOffset = surfaceGroupCenterOffset(
            handoffGrowth: walk.handoffGrowth
        )

        let canvasAxisLength = projected(size: layout.tileCanvasFrame.size)
        let contentAxisLength =
            presentedRestAxisLayout.totalExtent
        if contentAxisLength <= canvasAxisLength + 0.5 {
            return placementOffset
        }
        return placementOffset
            + cursor
            - walk.anchoredMag
    }

    private func surfaceGroupCenterOffset(
        handoffGrowth: CGFloat
    ) -> CGFloat {
        let primaryCenterOffset =
            layout.chromeSurfaces.primaryCenterOffset
        guard !mainDisplayTiles.isEmpty else {
            return 0
        }
        guard !handoffDisplayTiles.isEmpty else {
            return primaryCenterOffset
        }
        return primaryCenterOffset
            + (
                presentedRestAxisLayout.interDockGap
                + presentedRestAxisLayout.handoffDockExtent
                + handoffGrowth
            ) / 2
    }

    /// Defers the publish to the next runloop tick so we don't mutate
    /// shared state mid-render. The service isn't observed by this view,
    /// so this never re-triggers `TileContainerView`.
    private func publishChromeGrowth(
        primary: CGFloat,
        handoff: CGFloat
    ) {
        DispatchQueue.main.async {
            DockChromeMetricsService.shared.setAxisGrowth(
                primary: primary,
                handoff: handoff
            )
        }
    }

    /// Frame to assign to the tile, computed from its magnified icon side.
    /// Padding stays constant, matching Apple Dock's behavior where the
    /// icon scales but the tile chrome around it remains thin.
    private func magnifiedTileFrame(for tile: Tile, iconSize: CGFloat) -> CGSize {
        guard iconSize > effectiveTileSize else {
            return Self.size(
                for: tile,
                tileSize: effectiveTileSize,
                tileHeight: tileHeight,
                tileSpacing: effectiveTileSpacing,
                position: position,
                compactWidgets: layout.compactsWidgetsForOverflow
            )
        }
        let magnifiedHeight = iconSize + (tileHeight - effectiveTileSize)
        return Self.size(
            for: tile,
            tileSize: iconSize,
            tileHeight: magnifiedHeight,
            tileSpacing: effectiveTileSpacing,
            position: position,
            compactWidgets: layout.compactsWidgetsForOverflow
        )
    }

    private func isPinnedReorderable(tileID: String) -> Bool {
        store.isPinnedReorderable(tileID: tileID)
    }

    private func isTrailingReorderable(tileID: String) -> Bool {
        store.isTrailingReorderable(tileID: tileID)
    }

    private func isTileDraggable(_ tile: Tile) -> Bool {
        if tile.id == DockBadgeService.handoffTileID {
            return false
        }
        // Inline children of an app folder (rendered next to the folder
        // tile in inline / grouped-opened modes) are derived from the
        // folder's contents — reordering them as standalone tiles would
        // detach the relationship. Force users through the explicit
        // "Remove from Folder" action instead.
        if tile.id.hasPrefix("folder-running:") {
            return false
        }
        switch tile.content {
        case .app(let app):
            return !app.bundleIdentifier.isEmpty && app.bundleIdentifier != "com.apple.finder"
        case .minimizedWindow:
            return false
        case .appFolder:
            return isPinnedReorderable(tileID: tile.id)
        case .widget, .smartStack:
            return isPinnedReorderable(tileID: tile.id) || isTrailingReorderable(tileID: tile.id)
        case .launchpad, .startMenu, .spacer, .flexibleSpacer, .divider:
            return editMode.isActive && (isPinnedReorderable(tileID: tile.id) || isTrailingReorderable(tileID: tile.id))
        case .folder, .trash:
            return editMode.isActive && isTrailingReorderable(tileID: tile.id)
        }
    }

    private func makePinnedItem(from paletteDrag: DockEditPaletteDrag) -> PinnedTileItem? {
        Self.makePinnedItem(from: paletteDrag)
    }

    private func makePinnedItem(from paletteDrag: DockEditPaletteDrag?) -> PinnedTileItem? {
        guard let paletteDrag else { return nil }
        return Self.makePinnedItem(from: paletteDrag)
    }

    static func makePinnedItem(from paletteDrag: DockEditPaletteDrag) -> PinnedTileItem? {
        makePinnedItem(from: paletteDrag.item, widgetSpan: paletteDrag.widgetSpan)
    }

    static func makePinnedItem(from paletteItem: DockEditPaletteItem, widgetSpan: TileSpan?) -> PinnedTileItem? {
        return switch paletteItem {
        case .launchpad:
            PinnedTileItem.launchpad()
        case .startMenu:
            PinnedTileItem.startMenu()
        case .spacer:
            PinnedTileItem.spacer()
        case .flexibleSpacer:
            PinnedTileItem.flexibleSpacer()
        case .divider:
            PinnedTileItem.divider()
        case .widget(let ownerBundleIdentifier, let kind):
            PinnedTileItem.widget(
                kind: kind,
                ownerBundleIdentifier: ownerBundleIdentifier,
                span: resolvedPaletteWidgetSpan(
                    ownerBundleIdentifier: ownerBundleIdentifier,
                    kind: kind,
                    requestedSpan: widgetSpan
                )
            )
        case .smartStack:
            PinnedTileItem.smartStack()
        }
    }

    private func makeTrailingItem(from paletteDrag: DockEditPaletteDrag?) -> TrailingTileItem? {
        guard let paletteDrag else { return nil }
        return Self.makeTrailingItem(from: paletteDrag)
    }

    static func makeTrailingItem(from paletteDrag: DockEditPaletteDrag) -> TrailingTileItem? {
        return switch paletteDrag.item {
        case .launchpad:
            nil
        case .startMenu:
            nil
        case .spacer:
            TrailingTileItem.spacer()
        case .flexibleSpacer:
            TrailingTileItem.flexibleSpacer()
        case .divider:
            TrailingTileItem.divider()
        case .widget(let ownerBundleIdentifier, let kind):
            TrailingTileItem.widget(
                kind: kind,
                ownerBundleIdentifier: ownerBundleIdentifier,
                span: resolvedPaletteWidgetSpan(
                    ownerBundleIdentifier: ownerBundleIdentifier,
                    kind: kind,
                    requestedSpan: paletteDrag.widgetSpan
                )
            )
        case .smartStack:
            TrailingTileItem.smartStack()
        }
    }

    private func resolvedPaletteWidgetSpan(
        ownerBundleIdentifier: String,
        kind: WidgetKind,
        requestedSpan: TileSpan?
    ) -> TileSpan {
        let supportedSpans = kind.supportedSpans
        if let requestedSpan, supportedSpans.contains(requestedSpan) {
            return requestedSpan
        }

        if let catalogSpan = WidgetCatalog.staticRegistrations.first(where: {
            $0.ownerBundleIdentifier == ownerBundleIdentifier && $0.kind == kind
        })?.defaultSpan,
           supportedSpans.contains(catalogSpan) {
            return catalogSpan
        }

        return supportedSpans.last ?? .one
    }

    private func isHiddenForActiveDrag(tileID: String) -> Bool {
        tileID == draggedTileID
            || draggedAdditionalTileIDs.contains(tileID)
    }

    private func shouldHideDraggedOriginalTile(tileID: String) -> Bool {
        isHiddenForActiveDrag(tileID: tileID)
    }

    private func canDropInPinnedSection(_ tile: Tile) -> Bool {
        isPinnedReorderable(tileID: tile.id) || store.makePinnedItem(from: tile) != nil || bundleIdentifier(for: tile) != nil
    }

    private func canDropInTrailingSection(_ tile: Tile) -> Bool {
        isTrailingReorderable(tileID: tile.id) || store.makeTrailingItem(from: tile) != nil
    }

    private func reorderGesture(for tile: Tile) -> some Gesture {
        // Non-zero minimum so a pure click (no motion) never claims the
        // gesture. On Sequoia, minimumDistance: 0 caused mouse-down to
        // immediately start a drag, eating right-click and tap events.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                updateDrag(for: tile, value: value)
            }
            .onEnded { value in
                endDrag(for: tile, value: value)
            }
    }

    private func updateDrag(for tile: Tile, value: DragGesture.Value) {
        guard isTileDraggable(tile) else {
            return
        }

        if draggedTileID == nil {
            let pinnedDestinationIndex =
                isPinnedReorderable(tileID: tile.id)
                    ? pinnedTileIDs.firstIndex(of: tile.id)
                    : nil
            let trailingDestinationIndex =
                isTrailingReorderable(tileID: tile.id)
                    ? trailingTileIDs.firstIndex(of: tile.id)
                    : nil
            presentation.beginInternalDrag(
                tileID: tile.id,
                pinnedDestinationIndex: pinnedDestinationIndex,
                trailingDestinationIndex: trailingDestinationIndex
            )
            draggedProfileID = profileService.activeProfileID
            draggedProfileRevision =
                profileService.stateRevision
            draggedSpaceGeneration =
                spaceInteractionEpoch.generation
            draggedTileInitialFrame = tileFrames[tile.id]
            // Drag wins over hover/widget previews — they'd block the cursor
            // and confuse the reorder animation otherwise.
            WindowPreviewWindowController.shared.dismissCurrent()
            WidgetExpansionWindowController.shared.dismiss(sourceTileID: tile.id)
            Self.logger.info(
                "Drag started tile=\(tileLogDescription(tile), privacy: .public) pinnedSource=\(isPinnedReorderable(tileID: tile.id), privacy: .public) trailingSource=\(isTrailingReorderable(tileID: tile.id), privacy: .public) startPinnedIndex=\(optionalIndexDescription(draggedPinnedTileDestinationIndex), privacy: .public) startTrailingIndex=\(optionalIndexDescription(draggedTrailingTileDestinationIndex), privacy: .public)"
            )
            let diagnostics = DiagnosticsTrace.shared
            diagnostics.record(.input, "tileReorderDragStarted", fields: [
                "tileToken": diagnostics.token(tile.id),
                "sourceProfileToken": diagnostics.token(draggedProfileID),
                "pinnedSource": isPinnedReorderable(tileID: tile.id),
                "trailingSource": isTrailingReorderable(tileID: tile.id),
                "startPinnedIndex": draggedPinnedTileDestinationIndex ?? -1,
                "startTrailingIndex": draggedTrailingTileDestinationIndex ?? -1,
            ])
        }

        guard draggedTileID == tile.id else {
            return
        }
        guard draggedProfileID
                == profileService.activeProfileID,
              draggedProfileRevision
                == profileService.stateRevision,
              draggedSpaceGeneration
                == spaceInteractionEpoch.generation
        else {
            return
        }

        draggedTileOffset = projected(size: value.translation)
        draggedPickupCandidateTileID = dragPickupCandidateTileID(at: value.location)

        if draggedBundleIdentifier != nil,
           let groupTargetTileID = appFolderDropTargetTileID(
                at: value.location,
                selectedTileIDs: draggedSelectionTileIDs,
                selectedBundleIdentifiers: draggedSelectionBundleIdentifiers
             ) {
            if draggedAppFolderTargetTileID != groupTargetTileID {
                Self.logger.debug(
                    "Drag folder target tile=\(tileLogDescription(tile), privacy: .public) targetTileID=\(groupTargetTileID, privacy: .public) selectionCount=\(draggedSelectionBundleIdentifiers.count, privacy: .public)"
                )
            }
            draggedAppFolderTargetTileID = groupTargetTileID
            draggedTrashTargetTileID = nil
            presentation.setInternalDragDestinations(
                pinned: nil,
                trailing: nil
            )
            editMode.paletteDropDestination = nil
            return
        }

        if let trashTargetTileID = trashDropTargetTileID(at: value.location, sourceTileID: tile.id) {
            if draggedTrashTargetTileID != trashTargetTileID {
                Self.logger.debug(
                    "Drag trash target tile=\(tileLogDescription(tile), privacy: .public) targetTileID=\(trashTargetTileID, privacy: .public)"
                )
            }
            draggedTrashTargetTileID = trashTargetTileID
            draggedAppFolderTargetTileID = nil
            presentation.setInternalDragDestinations(
                pinned: nil,
                trailing: nil
            )
            editMode.paletteDropDestination = nil
            return
        }

        if hasCollectedAdditionalAppsDuringDrag {
            clearDragPreviewDestinations()
            return
        }

        draggedAppFolderTargetTileID = nil
        draggedTrashTargetTileID = nil
        let projectedLocation =
            projected(point: value.location)
        if !isPinnedReorderable(tileID: tile.id),
           draggedBundleIdentifier != nil,
           isPointInRunningAppDropRegion(
               projectedLocation
           ) {
            if let sourceFrame = tileFrames[tile.id],
               sourceFrame.contains(value.location) {
                presentation.setInternalDragDestinations(
                    pinned: nil,
                    trailing: nil
                )
                return
            }

            // Running order is owned by WorkspaceService and is transient.
            // Dragging within that strip means "keep this app": preview and
            // commit it at the final persistent slot, matching the native
            // Dock's favorite/recent separator semantics.
            guard case .pinned(let destinationIndex) =
                    DockDropAxisRegionPolicy
                    .destination(
                        for: .unpinnedApp,
                        over: .running,
                        canDropIntoPinned: true,
                        canDropIntoTrailing: false,
                        authoritativePinnedCount:
                            pinnedTiles.count,
                        authoritativeTrailingCount:
                            trailingTiles.count
                    )
            else {
                return
            }
            presentation.setInternalDragDestinations(
                pinned: destinationIndex,
                trailing: nil
            )
            return
        }
        updatePreviewDestination(
            at: projectedLocation,
            sourceTileID: tile.id,
            isTileDrag: true,
            isPinnedSource: isPinnedReorderable(tileID: tile.id),
            isTrailingSource: isTrailingReorderable(tileID: tile.id),
            canDropIntoPinned: canDropInPinnedSection(tile),
            canDropIntoTrailing: canDropInTrailingSection(tile)
        )
    }

    private func endDrag(for tile: Tile, value: DragGesture.Value) {
        let translationMagnitude = sqrt(value.translation.width * value.translation.width + value.translation.height * value.translation.height)
        Self.logger.info(
            "endDrag tile=\(tileLogDescription(tile), privacy: .public) translation=(\(value.translation.width, privacy: .public),\(value.translation.height, privacy: .public)) magnitude=\(translationMagnitude, privacy: .public) draggedTileID=\(self.draggedTileID ?? "nil", privacy: .public)"
        )
        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(.input, "tileReorderDragEnded", fields: [
            "tileToken": diagnostics.token(tile.id),
            "draggedTileToken": diagnostics.token(draggedTileID),
            "sourceProfileToken": diagnostics.token(draggedProfileID),
            "activeProfileToken": diagnostics.token(profileService.activeProfileID),
            "translationX": value.translation.width,
            "translationY": value.translation.height,
            "translationMagnitude": translationMagnitude,
        ])

        guard let sourceProfileID = draggedProfileID,
              let sourceProfileRevision =
                draggedProfileRevision,
              let sourceSpaceGeneration =
                draggedSpaceGeneration,
              sourceProfileID
                == profileService.activeProfileID,
              sourceProfileRevision
                == profileService.stateRevision,
              sourceSpaceGeneration
                == spaceInteractionEpoch.generation
        else {
            let cancellationReason =
                draggedProfileID
                    != profileService.activeProfileID
                ? "profileChanged"
                : draggedSpaceGeneration
                    != spaceInteractionEpoch.generation
                ? "spaceChanged"
                : "profileRevisionChanged"
            Self.logger.info(
                "Drag cancelled after profile/layout change tile=\(tileLogDescription(tile), privacy: .public) reason=\(cancellationReason, privacy: .public) sourceProfile=\(self.draggedProfileID ?? "nil", privacy: .public) activeProfile=\(self.profileService.activeProfileID, privacy: .public)"
            )
            diagnostics.record(.profiles, "tileReorderDragCancelled", fields: [
                "reason": cancellationReason,
                "tileToken": diagnostics.token(tile.id),
                "sourceProfileToken": diagnostics.token(draggedProfileID),
                "activeProfileToken": diagnostics.token(profileService.activeProfileID),
                "sourceRevision": draggedProfileRevision ?? 0,
                "activeRevision": profileService.stateRevision,
                "sourceSpaceGeneration":
                    draggedSpaceGeneration ?? 0,
                "activeSpaceGeneration":
                    spaceInteractionEpoch.generation,
            ])
            diagnostics.record(.input, "tileReorderDragResolved", fields: [
                "result": "cancelled",
                "reason": cancellationReason,
                "tileToken": diagnostics.token(tile.id),
            ])
            clearDragState()
            return
        }

        updateDrag(for: tile, value: value)

        guard draggedTileID == tile.id else {
            Self.logger.info(
                "Drag ended without active source tile=\(tileLogDescription(tile), privacy: .public)"
            )
            diagnostics.record(.input, "tileReorderDragResolved", fields: [
                "result": "rejected",
                "reason": "sourceUnavailable",
                "tileToken": diagnostics.token(tile.id),
            ])
            clearDragState()
            return
        }

        var resolutionResult = "noIntent"
        var resolutionReason = "noMutation"
        if draggedTrashTargetTileID != nil {
            Self.logger.info(
                "Drag dropping on trash tile=\(tileLogDescription(tile), privacy: .public) pinnedSource=\(isPinnedReorderable(tileID: tile.id), privacy: .public) trailingSource=\(isTrailingReorderable(tileID: tile.id), privacy: .public)"
            )
            if isPinnedReorderable(tileID: tile.id) {
                let applied = store.removePinnedItem(
                    tileID: tile.id,
                    expectedProfileID:
                        sourceProfileID,
                    expectedRevision:
                        sourceProfileRevision
                )
                resolutionResult =
                    applied ? "committed" : "rejected"
                resolutionReason =
                    applied
                    ? "removedPinnedItem"
                    : "removeTransactionRejected"
            } else if isTrailingReorderable(tileID: tile.id) {
                let applied = store.removeTrailingItem(
                    tileID: tile.id,
                    expectedProfileID:
                        sourceProfileID,
                    expectedRevision:
                        sourceProfileRevision
                )
                resolutionResult =
                    applied ? "committed" : "rejected"
                resolutionReason =
                    applied
                    ? "removedTrailingItem"
                    : "removeTransactionRejected"
            }
        } else if let groupTargetTileID = draggedAppFolderTargetTileID,
           draggedBundleIdentifier != nil {
            Self.logger.info(
                "Drag committing group tile=\(tileLogDescription(tile), privacy: .public) targetTileID=\(groupTargetTileID, privacy: .public) selectionCount=\(draggedSelectionBundleIdentifiers.count, privacy: .public)"
            )
            let applied = store.groupApps(
                bundleIdentifiers:
                    draggedSelectionBundleIdentifiers,
                intoTileID: groupTargetTileID,
                expectedProfileID: sourceProfileID,
                expectedRevision:
                    sourceProfileRevision
            )
            resolutionResult =
                applied ? "committed" : "rejected"
            resolutionReason =
                applied
                ? "groupedApps"
                : "groupTransactionRejected"
        } else if hasCollectedAdditionalAppsDuringDrag {
            // Multi-app pickup is only used for grouping into an app or folder target.
            Self.logger.info(
                "Drag ended with collected apps tile=\(tileLogDescription(tile), privacy: .public) additionalTileIDs=\(self.draggedAdditionalTileIDs.joined(separator: ","), privacy: .public)"
            )
            resolutionReason = "collectedAppsWithoutTarget"
        } else if isPinnedReorderable(tileID: tile.id) {
            if let destinationIndex = draggedTrailingTileDestinationIndex,
               let trailingItem = draggedTile.flatMap(store.makeTrailingItem(from:)) {
                Self.logger.info(
                    "Drag moving pinned->trailing tile=\(tileLogDescription(tile), privacy: .public) destinationIndex=\(destinationIndex, privacy: .public)"
                )
                let applied =
                    store.movePinnedItemToTrailing(
                        tileID: tile.id,
                        convertedItem: trailingItem,
                        at: destinationIndex,
                        expectedProfileID:
                            sourceProfileID,
                        expectedRevision:
                            sourceProfileRevision
                    )
                resolutionResult =
                    applied ? "committed" : "rejected"
                resolutionReason =
                    applied
                    ? "movedPinnedToTrailing"
                    : "crossSectionTransactionRejected"
            } else {
                let finalPinnedTileIDs = previewPinnedBaseTiles.map(\.id)
                Self.logger.info(
                    "Drag reordering pinned tile=\(tileLogDescription(tile), privacy: .public) finalPinnedIDs=\(finalPinnedTileIDs.joined(separator: ","), privacy: .public)"
                )
                if finalPinnedTileIDs != pinnedTileIDs {
                    let applied =
                        store.setPinnedTileOrder(
                            ids: finalPinnedTileIDs,
                            expectedProfileID:
                                sourceProfileID,
                            expectedRevision:
                                sourceProfileRevision
                        )
                    resolutionResult =
                        applied
                        ? "committed"
                        : "rejected"
                    resolutionReason =
                        applied
                        ? "reorderedPinnedItems"
                        : "reorderTransactionRejected"
                } else {
                    resolutionReason =
                        "unchangedPinnedOrder"
                }
            }
        } else if isTrailingReorderable(tileID: tile.id) {
            if let destinationIndex = draggedPinnedTileDestinationIndex,
               let pinnedItem = draggedTile.flatMap(store.makePinnedItem(from:)) {
                Self.logger.info(
                    "Drag moving trailing->pinned tile=\(tileLogDescription(tile), privacy: .public) destinationIndex=\(destinationIndex, privacy: .public)"
                )
                let applied =
                    store.moveTrailingItemToPinned(
                        tileID: tile.id,
                        convertedItem: pinnedItem,
                        at: destinationIndex,
                        expectedProfileID:
                            sourceProfileID,
                        expectedRevision:
                            sourceProfileRevision
                    )
                resolutionResult =
                    applied ? "committed" : "rejected"
                resolutionReason =
                    applied
                    ? "movedTrailingToPinned"
                    : "crossSectionTransactionRejected"
            } else {
                let finalTrailingTileIDs = previewTrailingTiles.map(\.id)
                Self.logger.info(
                    "Drag reordering trailing tile=\(tileLogDescription(tile), privacy: .public) finalTrailingIDs=\(finalTrailingTileIDs.joined(separator: ","), privacy: .public)"
                )
                if finalTrailingTileIDs != trailingTileIDs {
                    let applied =
                        store.setTrailingTileOrder(
                            ids: finalTrailingTileIDs,
                            expectedProfileID:
                                sourceProfileID,
                            expectedRevision:
                                sourceProfileRevision
                        )
                    resolutionResult =
                        applied
                        ? "committed"
                        : "rejected"
                    resolutionReason =
                        applied
                        ? "reorderedTrailingItems"
                        : "reorderTransactionRejected"
                } else {
                    resolutionReason =
                        "unchangedTrailingOrder"
                }
            }
        } else if let destinationIndex = draggedPinnedTileDestinationIndex,
                  let bundleIdentifier = draggedBundleIdentifier {
            Self.logger.info(
                "Drag pinning app tile=\(tileLogDescription(tile), privacy: .public) bundleIdentifier=\(bundleIdentifier, privacy: .public) destinationIndex=\(destinationIndex, privacy: .public)"
            )
            let applied = store.pinApp(
                bundleIdentifier: bundleIdentifier,
                at: destinationIndex,
                expectedProfileID: sourceProfileID,
                expectedRevision:
                    sourceProfileRevision
            )
            resolutionResult =
                applied ? "committed" : "rejected"
            resolutionReason =
                applied
                ? "pinnedRunningApp"
                : "pinTransactionRejected"
        } else {
            Self.logger.info(
                "Drag ended with no mutation tile=\(tileLogDescription(tile), privacy: .public) pinnedDestination=\(optionalIndexDescription(draggedPinnedTileDestinationIndex), privacy: .public) trailingDestination=\(optionalIndexDescription(draggedTrailingTileDestinationIndex), privacy: .public) folderTarget=\(draggedAppFolderTargetTileID ?? "nil", privacy: .public)"
            )
        }

        diagnostics.record(.input, "tileReorderDragResolved", fields: [
            "result": resolutionResult,
            "reason": resolutionReason,
            "tileToken": diagnostics.token(tile.id),
            "profileToken": diagnostics.token(sourceProfileID),
            "sourceRevision": sourceProfileRevision,
            "activeRevision": profileService.stateRevision,
        ])
        withAnimation(tileMutationAnimation) {
            clearDragState()
        }
    }

    private var draggedBundleIdentifier: String? {
        guard let draggedTile, case .app(let app) = draggedTile.content else {
            return nil
        }
        return app.bundleIdentifier
    }

    private func handleDragKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              event.charactersIgnoringModifiers == " " else {
            return false
        }

        return grabPickupCandidateDuringActiveDrag()
    }

    private func grabPickupCandidateDuringActiveDrag() -> Bool {
        guard isCollectingAdditionalAppsDuringDrag,
              let pickupCandidateTileID = draggedPickupCandidateTileID,
              let bundleIdentifier = bundleIdentifier(forTileID: pickupCandidateTileID),
              !draggedSelectionTileIDs.contains(pickupCandidateTileID),
              !draggedSelectionBundleIdentifiers.contains(bundleIdentifier) else {
            return false
        }

        withAnimation(tileMutationAnimation) {
            draggedAdditionalTileIDs.append(pickupCandidateTileID)
            draggedPickupCandidateTileID = nil
            clearDragPreviewDestinations()
        }
        return true
    }

    private func clearDragPreviewDestinations() {
        draggedAppFolderTargetTileID = nil
        draggedTrashTargetTileID = nil
        presentation.setInternalDragDestinations(
            pinned: nil,
            trailing: nil
        )
        editMode.paletteDropDestination = nil
    }

    private func invalidateDragForProfileChange() {
        // External and palette interactions are session-scoped too. Clearing
        // them here prevents a profile excursion from becoming valid again if
        // automation returns to the original profile before mouse-up.
        dockDrag.invalidateCurrentInteraction()
        editMode.endPaletteDrag()

        guard draggedTileID != nil,
              draggedProfileID
                != profileService.activeProfileID
                || draggedProfileRevision
                    != profileService.stateRevision
        else {
            return
        }
        Self.logger.info(
            "Invalidating drag after profile change tileID=\(self.draggedTileID ?? "nil", privacy: .public) sourceProfile=\(self.draggedProfileID ?? "nil", privacy: .public) activeProfile=\(self.profileService.activeProfileID, privacy: .public)"
        )
        // Keep the source tile latched until the gesture ends so a stale
        // DragGesture callback cannot start a second drag in the new profile.
        // Clearing the revision makes every remaining update/end fail closed.
        draggedProfileRevision = nil
        draggedTileOffset = 0
        draggedPickupCandidateTileID = nil
        clearDragPreviewDestinations()
    }

    private func invalidateDragForSpaceChange() {
        // Keep the internal source latched until DragGesture.onEnded so a
        // stale callback cannot start a new drag in the destination Space.
        // Every commit path also compares the captured generation directly.
        dockDrag.invalidateCurrentInteraction()
        editMode.endPaletteDrag()

        guard draggedTileID != nil else {
            return
        }
        Self.logger.info(
            "Invalidating drag after Space change tileID=\(self.draggedTileID ?? "nil", privacy: .public) sourceGeneration=\(self.draggedSpaceGeneration ?? 0, privacy: .public) activeGeneration=\(self.spaceInteractionEpoch.generation, privacy: .public)"
        )
        draggedProfileRevision = nil
        draggedTileOffset = 0
        draggedPickupCandidateTileID = nil
        clearDragPreviewDestinations()
    }

    private func updatePreviewDestination(
        at positionValue: CGFloat,
        sourceTileID: String,
        isTileDrag: Bool,
        isPinnedSource: Bool,
        isTrailingSource: Bool,
        canDropIntoPinned: Bool,
        canDropIntoTrailing: Bool
    ) {
        if canDropIntoPinned && isPointInPinnedDropRegion(positionValue) {
            if draggedPinnedTileDestinationIndex == nil || draggedTrailingTileDestinationIndex != nil {
                Self.logger.debug(
                    "Drag entered pinned region sourceTileID=\(sourceTileID, privacy: .public) position=\(positionValue, privacy: .public) pinnedSource=\(isPinnedSource, privacy: .public) trailingSource=\(isTrailingSource, privacy: .public) canDropPinned=\(canDropIntoPinned, privacy: .public) canDropTrailing=\(canDropIntoTrailing, privacy: .public)"
                )
            }
            updateDropDestination(for: .pinned, at: positionValue, sourceTileID: sourceTileID, isTileDrag: isTileDrag)
            return
        }

        if canDropIntoTrailing && isPointInTrailingDropRegion(positionValue) {
            if draggedTrailingTileDestinationIndex == nil || draggedPinnedTileDestinationIndex != nil {
                Self.logger.debug(
                    "Drag entered trailing region sourceTileID=\(sourceTileID, privacy: .public) position=\(positionValue, privacy: .public) pinnedSource=\(isPinnedSource, privacy: .public) trailingSource=\(isTrailingSource, privacy: .public) canDropPinned=\(canDropIntoPinned, privacy: .public) canDropTrailing=\(canDropIntoTrailing, privacy: .public)"
                )
            }
            updateDropDestination(for: .trailing, at: positionValue, sourceTileID: sourceTileID, isTileDrag: isTileDrag)
            return
        }

        if draggedPinnedTileDestinationIndex != nil || draggedTrailingTileDestinationIndex != nil {
            Self.logger.debug(
                "Drag left drop regions sourceTileID=\(sourceTileID, privacy: .public) position=\(positionValue, privacy: .public) pinnedSource=\(isPinnedSource, privacy: .public) trailingSource=\(isTrailingSource, privacy: .public)"
            )
        }
        if isTileDrag {
            presentation.setInternalDragDestinations(
                pinned: nil,
                trailing: nil
            )
        }
        if !isTileDrag {
            editMode.paletteDropDestination = nil
        }
    }

    private func updateDropDestination(
        for section: DockEditDropSection,
        at positionValue: CGFloat,
        sourceTileID: String,
        isTileDrag: Bool
    ) {
        let visibleTiles = previewTiles(for: section).filter { $0.id != sourceTileID }
        let destinationIndex = visibleTiles.enumerated().first { _, tile in
            guard let frame = tileFrames[tile.id] else {
                return false
            }
            let midpoint = projected(point: frame.origin) + projected(size: frame.size) / 2
            return positionValue < midpoint
        }?.offset ?? visibleTiles.count

        let currentDestinationIndex = currentDropDestinationIndex(for: section, isTileDrag: isTileDrag)
        guard currentDestinationIndex != destinationIndex else {
            return
        }

        Self.logger.debug(
            "Drag destination updated sourceTileID=\(sourceTileID, privacy: .public) section=\(dropSectionDescription(section), privacy: .public) index=\(destinationIndex, privacy: .public) previous=\(optionalIndexDescription(currentDestinationIndex), privacy: .public) visibleTileCount=\(visibleTiles.count, privacy: .public) position=\(positionValue, privacy: .public) tileDrag=\(isTileDrag, privacy: .public)"
        )

        withAnimation(tileMutationAnimation) {
            setDropDestination(section: section, index: destinationIndex, isTileDrag: isTileDrag)
        }
    }

    private func updateExternalDragDestinationIndex(at location: CGPoint?) {
        guard let location, let kind = dockDrag.kind else {
            dockDrag.destinationIndex = nil
            dockDrag.destinationSection = nil
            dockDrag.documentTargetTileID = nil
            return
        }
        let positionValue = projected(point: location)
        switch kind {
        case .document:
            let targetID = documentDropTargetTileID(at: location)
            if dockDrag.documentTargetTileID != targetID { dockDrag.documentTargetTileID = targetID }
            if dockDrag.destinationIndex != nil { dockDrag.destinationIndex = nil }
            if dockDrag.destinationSection != nil { dockDrag.destinationSection = nil }
            dockDrag.updateSpringLoadCandidate(springLoadCandidateTileID(at: location))
            return
        case .app:
            let isRunningStripDestination =
                isPointInRunningAppDropRegion(
                    positionValue
                )
            guard isPointInPinnedDropRegion(
                positionValue
            ) || isRunningStripDestination else {
                dockDrag.destinationIndex = nil
                dockDrag.destinationSection = nil
                return
            }
            let index =
                isRunningStripDestination
                ? pinnedTiles.count
                : pinnedTiles.enumerated()
                    .first { _, tile in
                        guard let frame =
                                tileFrames[tile.id]
                        else {
                            return false
                        }
                        let midpoint =
                            projected(
                                point: frame.origin
                            )
                            + projected(
                                size: frame.size
                            ) / 2
                        return positionValue
                            < midpoint
                    }?.offset
                    ?? pinnedTiles.count
            if dockDrag.destinationIndex != index { dockDrag.destinationIndex = index }
            if dockDrag.destinationSection != .pinned { dockDrag.destinationSection = .pinned }
        case .folder:
            // Hovering over an app tile → open-with target (any app, like document drops).
            if let targetID = documentDropTargetTileID(at: location) {
                if dockDrag.documentTargetTileID != targetID { dockDrag.documentTargetTileID = targetID }
                if dockDrag.destinationIndex != nil { dockDrag.destinationIndex = nil }
                if dockDrag.destinationSection != nil { dockDrag.destinationSection = nil }
                dockDrag.updateSpringLoadCandidate(springLoadCandidateTileID(at: location))
                return
            }
            if dockDrag.documentTargetTileID != nil { dockDrag.documentTargetTileID = nil }
            dockDrag.updateSpringLoadCandidate(springLoadCandidateTileID(at: location))
            guard isPointInTrailingDropRegion(positionValue) else {
                dockDrag.destinationIndex = nil
                dockDrag.destinationSection = nil
                return
            }
            let trashIndex = trailingTiles.firstIndex { tile in
                if case .trash = tile.content { return true }
                return false
            } ?? trailingTiles.count
            let rawIndex = trailingTiles.enumerated().first { _, tile in
                guard let frame = tileFrames[tile.id] else { return false }
                let midpoint = projected(point: frame.origin) + projected(size: frame.size) / 2
                return positionValue < midpoint
            }?.offset ?? trailingTiles.count
            let index = min(rawIndex, trashIndex)
            if dockDrag.destinationIndex != index { dockDrag.destinationIndex = index }
            if dockDrag.destinationSection != .trailing { dockDrag.destinationSection = .trailing }
        }
    }

    private func updatePaletteDropDestinationFromCursor(at location: CGPoint?) {
        guard let location, let paletteDrag = editMode.paletteDrag else {
            return
        }
        let palettePreviewTile =
            DockPresentationService.palettePreviewTile(
                for: paletteDrag
            )
        updatePreviewDestination(
            at: projected(point: location),
            sourceTileID: palettePreviewTile.id,
            isTileDrag: false,
            isPinnedSource: false,
            isTrailingSource: false,
            canDropIntoPinned: Self.makePinnedItem(from: paletteDrag) != nil,
            canDropIntoTrailing: Self.makeTrailingItem(from: paletteDrag) != nil
        )
    }

    private func documentDropTargetTileID(at location: CGPoint) -> String? {
        guard !editMode.isActive else { return nil }
        for tile in displayTiles.reversed() {
            guard let frame = tileFrames[tile.id], frame.contains(location) else { continue }
            guard tile.id != DockBadgeService.handoffTileID,
                  case .app(let app) = tile.content,
                  app.displayedWidget == nil,
                  !app.bundleIdentifier.isEmpty else {
                return nil
            }
            return tile.id
        }
        return nil
    }

    /// Tile id under the cursor that should spring-open during a drag.
    /// Grid-mode app folders and grid-mode regular folders qualify; list/
    /// inline presentations can't host drop targets per item.
    private func springLoadCandidateTileID(at location: CGPoint) -> String? {
        guard !editMode.isActive else { return nil }
        for tile in displayTiles.reversed() {
            guard let frame = tileFrames[tile.id], frame.contains(location) else { continue }
            switch tile.content {
            case .appFolder(let folder)
                where folder.contentViewMode == .grid && !folder.apps.isEmpty:
                return tile.id
            case .folder(let folder)
                where folder.displayMode == .folder && folder.contentViewMode == .grid:
                return tile.id
            default:
                return nil
            }
        }
        return nil
    }

    private func isPointInPinnedDropRegion(_ positionValue: CGFloat) -> Bool {
        guard let trailingBoundaryFrame = tileFrames[pinnedTrailingBoundaryTileID],
              let lowerBound = pinnedDropRegionLowerBound else {
            return false
        }

        let upperBound = projected(point: trailingBoundaryFrame.origin)
        if lowerBound < upperBound {
            return positionValue >= lowerBound
                && positionValue <= upperBound
        }

        // Finder can be shelved while both the saved and running app
        // sections are empty. In that state the leading fallback and divider
        // origin coincide, so the mathematical section has zero width. The
        // divider remains visible; accepting its own frame gives an external
        // app (or palette app) a concrete target for establishing the first
        // pinned item.
        let dividerUpperBound =
            upperBound
            + projected(size: trailingBoundaryFrame.size)
        return positionValue >= upperBound
            && positionValue <= dividerUpperBound
    }

    /// Leading edge of the pinned drop region. Normally this is the trailing
    /// edge of the fixed Finder fixture, so drops never land before it. Shelve
    /// mode can hide the Finder tile, in which case there's nothing to anchor
    /// against, so fall back to the dock's leading content edge. Without this
    /// fallback the whole pinned section becomes undroppable (issue #13).
    private var pinnedDropRegionLowerBound: CGFloat? {
        if let finderFrame = tileFrames["pinned:com.apple.finder"] {
            return projected(point: finderFrame.origin) + projected(size: finderFrame.size)
        }
        return tileFrames.values.map { projected(point: $0.origin) }.min()
    }

    private var pinnedTrailingBoundaryTileID: String {
        tileFrames.keys.contains("divider:running") ? "divider:running" : "divider:trailing"
    }

    private func isPointInRunningAppDropRegion(
        _ positionValue: CGFloat
    ) -> Bool {
        guard let runningDividerFrame =
                tileFrames["divider:running"],
              let trailingDividerFrame =
                tileFrames["divider:trailing"]
        else {
            return false
        }

        let lowerBound =
            projected(point: runningDividerFrame.origin)
            + projected(size: runningDividerFrame.size)
        let upperBound =
            projected(point: trailingDividerFrame.origin)
        return positionValue >= lowerBound
            && positionValue <= upperBound
    }

    private func isPointInTrailingDropRegion(_ positionValue: CGFloat) -> Bool {
        guard let dividerFrame = tileFrames["divider:trailing"] else {
            return false
        }

        // With trailing tiles present the region spans from the divider's
        // trailing edge to the last tile's trailing edge. Shelve mode can hide
        // Trash and leave the trailing section empty, so there's no tile past
        // the divider to anchor against, and the dock shrinks to content,
        // leaving no empty space either. Treat the divider tile itself as the
        // drop target so widgets can still be dropped there (issue #13).
        guard let lastTrailingTileID = previewTrailingTiles.last?.id,
              let trailingBoundaryFrame = tileFrames[lastTrailingTileID] else {
            let lowerBound = projected(point: dividerFrame.origin)
            let upperBound = projected(point: dividerFrame.origin) + projected(size: dividerFrame.size)
            return positionValue >= lowerBound && positionValue <= upperBound
        }

        let lowerBound = projected(point: dividerFrame.origin) + projected(size: dividerFrame.size)
        let upperBound = projected(point: trailingBoundaryFrame.origin) + projected(size: trailingBoundaryFrame.size)
        return positionValue >= lowerBound && positionValue <= upperBound
    }

    private func previewTiles(for section: DockEditDropSection) -> [Tile] {
        switch section {
        case .pinned:
            previewPinnedBaseTiles
        case .trailing:
            previewTrailingTiles
        }
    }

    private func currentDropDestinationIndex(for section: DockEditDropSection, isTileDrag: Bool) -> Int? {
        if isTileDrag {
            return switch section {
            case .pinned: draggedPinnedTileDestinationIndex
            case .trailing: draggedTrailingTileDestinationIndex
            }
        }

        guard editMode.paletteDropDestination?.section == section else {
            return nil
        }
        return editMode.paletteDropDestination?.index
    }

    private func setDropDestination(section: DockEditDropSection, index: Int?, isTileDrag: Bool) {
        if isTileDrag {
            switch section {
            case .pinned:
                presentation.setInternalDragDestinations(
                    pinned: index,
                    trailing: nil
                )
            case .trailing:
                presentation.setInternalDragDestinations(
                    pinned: nil,
                    trailing: index
                )
            }
            return
        }

        if let index {
            editMode.paletteDropDestination = DockEditDropDestination(section: section, index: index)
        } else {
            editMode.paletteDropDestination = nil
        }
    }

    private func clearDragState() {
        if draggedTileID != nil {
            Self.logger.debug(
                "Clearing drag state tileID=\(draggedTileID ?? "nil", privacy: .public) pinnedDestination=\(optionalIndexDescription(draggedPinnedTileDestinationIndex), privacy: .public) trailingDestination=\(optionalIndexDescription(draggedTrailingTileDestinationIndex), privacy: .public) folderTarget=\(draggedAppFolderTargetTileID ?? "nil", privacy: .public)"
            )
        }
        presentation.clearInternalDrag()
        draggedProfileID = nil
        draggedProfileRevision = nil
        draggedSpaceGeneration = nil
        draggedTileOffset = 0
        draggedTileInitialFrame = nil
        draggedAppFolderTargetTileID = nil
        draggedTrashTargetTileID = nil
        draggedPickupCandidateTileID = nil
    }

    private func bundleIdentifier(for tile: Tile) -> String? {
        guard tile.id != DockBadgeService.handoffTileID,
              case .app(let app) = tile.content else {
            return nil
        }
        return app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier
    }

    private func optionalIndexDescription(_ index: Int?) -> String {
        guard let index else {
            return "nil"
        }
        return String(index)
    }

    private func dropSectionDescription(_ section: DockEditDropSection) -> String {
        switch section {
        case .pinned:
            return "pinned"
        case .trailing:
            return "trailing"
        }
    }

    private func tileLogDescription(_ tile: Tile) -> String {
        "\(tile.id):\(tileKindDescription(tile))"
    }

    private func tileKindDescription(_ tile: Tile) -> String {
        switch tile.content {
        case .app(let app):
            return "app(\(app.bundleIdentifier))"
        case .appFolder(let folder):
            return "appFolder(\(folder.identifier))"
        case .folder(let folder):
            return "folder(\(folder.url.lastPathComponent))"
        case .widget(let widget):
            return "widget(\(widget.kind.rawValue))"
        case .smartStack:
            return "smartStack"
        case .spacer:
            return "spacer"
        case .flexibleSpacer:
            return "flexibleSpacer"
        case .divider:
            return "divider"
        case .launchpad:
            return "launchpad"
        case .startMenu:
            return "startMenu"
        case .trash:
            return "trash"
        case .minimizedWindow(let window):
            return "minimizedWindow(\(window.windowIdentifier))"
        }
    }

    private func bundleIdentifier(forTileID tileID: String) -> String? {
        guard let tile = store.tiles.first(where: { $0.id == tileID }) else {
            return nil
        }

        return bundleIdentifier(for: tile)
    }

    private func appFolderDropTargetTileID(
        at location: CGPoint,
        selectedTileIDs: Set<String>,
        selectedBundleIdentifiers: [String]
    ) -> String? {
        let selectedBundleIdentifierSet = Set(selectedBundleIdentifiers)

        // Folder intent is resolved from what the user can actually see, not
        // only from the persistent pinned preview. A new/empty profile often
        // contains exclusively `running:*` app tiles; those are valid targets
        // and the commit atomically promotes both apps into a pinned folder.
        for tile in surfaceOrderedDisplayTiles.reversed()
        where !selectedTileIDs.contains(tile.id) {
            switch tile.content {
            case .app(let app):
                guard tile.id
                        != DockBadgeService.handoffTileID,
                      !tile.id.hasPrefix(
                          "folder-running:"
                      ),
                      !app.bundleIdentifier.isEmpty,
                      app.bundleIdentifier
                        != "com.apple.finder",
                      !selectedBundleIdentifierSet
                        .contains(
                            app.bundleIdentifier
                        )
                else {
                    continue
                }
            case .minimizedWindow:
                continue
            case .appFolder(let folder):
                guard isPinnedReorderable(
                    tileID: tile.id
                ),
                folder.bundleIdentifiers.allSatisfy({
                    !selectedBundleIdentifierSet
                        .contains($0)
                }) else {
                    continue
                }
            case .launchpad, .startMenu, .widget, .smartStack, .folder, .spacer, .flexibleSpacer, .divider, .trash:
                continue
            }

            guard let frame = tileFrames[tile.id] else {
                continue
            }

            let targetFrame = frame.insetBy(dx: frame.width * 0.18, dy: frame.height * 0.18)
            if targetFrame.contains(location) {
                return tile.id
            }
        }

        return nil
    }

    private func trashDropTargetTileID(at location: CGPoint, sourceTileID: String) -> String? {
        for tile in trailingTiles where tile.id != sourceTileID {
            guard case .trash = tile.content,
                  let frame = tileFrames[tile.id],
                  frame.contains(location) else {
                continue
            }
            return tile.id
        }
        return nil
    }

    private func dragPickupCandidateTileID(at location: CGPoint) -> String? {
        guard isCollectingAdditionalAppsDuringDrag else {
            return nil
        }

        let selectedBundleIdentifiers = Set(draggedSelectionBundleIdentifiers)

        for tile in displayTiles.reversed() {
            guard !draggedSelectionTileIDs.contains(tile.id),
                  let bundleIdentifier = bundleIdentifier(for: tile),
                  !selectedBundleIdentifiers.contains(bundleIdentifier),
                  let frame = tileFrames[tile.id] else {
                continue
            }

            let targetFrame = frame.insetBy(dx: frame.width * 0.18, dy: frame.height * 0.18)
            if targetFrame.contains(location) {
                return tile.id
            }
        }

        return nil
    }

    private func projected(size: CGSize) -> CGFloat {
        position.isVertical ? size.height : size.width
    }

    private func projected(point: CGPoint) -> CGFloat {
        position.isVertical ? point.y : point.x
    }

    private func axisSize(value: CGFloat) -> CGSize {
        position.isVertical ? CGSize(width: 0, height: value) : CGSize(width: value, height: 0)
    }

    static func size(
        for tile: Tile,
        tileSize: CGFloat,
        tileHeight: CGFloat,
        tileSpacing: CGFloat = 0,
        position: ResolvedDockWindowPosition,
        compactWidgets: Bool = false
    ) -> CGSize {
        let dividerExtent = tileSize * 0.5

        return switch (position.isVertical, tile.content) {
        case (false, .divider):
            CGSize(width: dividerExtent, height: tileHeight)
        case (false, .app(let app)) where app.displayedWidget != nil:
            CGSize(
                width: spanExtent(
                    for: effectiveWidgetSpan(app.displayedWidget?.span ?? .one, tileSize: tileSize, isVertical: false, compactWidgets: compactWidgets),
                    baseTileSize: tileSize,
                    tileSpacing: tileSpacing
                ),
                height: tileHeight
            )
        case (false, .widget(let widget)):
            CGSize(width: spanExtent(for: effectiveWidgetSpan(widget.span, tileSize: tileSize, isVertical: false, compactWidgets: compactWidgets), baseTileSize: tileSize, tileSpacing: tileSpacing), height: tileHeight)
        case (false, .smartStack(let stack)):
            CGSize(width: spanExtent(for: effectiveWidgetSpan(stack.span, tileSize: tileSize, isVertical: false, compactWidgets: compactWidgets), baseTileSize: tileSize, tileSpacing: tileSpacing), height: tileHeight)
        case (false, _):
            CGSize(width: tileSize, height: tileHeight)
        case (true, .divider):
            CGSize(width: tileHeight, height: dividerExtent)
        case (true, .app(let app)) where app.displayedWidget != nil:
            CGSize(
                width: tileHeight,
                height: spanExtent(
                    for: effectiveWidgetSpan(app.displayedWidget?.span ?? .one, tileSize: tileSize, isVertical: true, compactWidgets: compactWidgets),
                    baseTileSize: tileSize,
                    tileSpacing: tileSpacing
                )
            )
        case (true, .widget(let widget)):
            CGSize(width: tileHeight, height: spanExtent(for: effectiveWidgetSpan(widget.span, tileSize: tileSize, isVertical: true, compactWidgets: compactWidgets), baseTileSize: tileSize, tileSpacing: tileSpacing))
        case (true, .smartStack(let stack)):
            CGSize(width: tileHeight, height: spanExtent(for: effectiveWidgetSpan(stack.span, tileSize: tileSize, isVertical: true, compactWidgets: compactWidgets), baseTileSize: tileSize, tileSpacing: tileSpacing))
        case (true, _):
            CGSize(width: tileHeight, height: tileSize)
        }
    }

    private static func effectiveWidgetSpan(_ span: TileSpan, tileSize: CGFloat, isVertical: Bool, compactWidgets: Bool) -> TileSpan {
        if compactWidgets || isVertical {
            return .one
        }

        return span
    }

    private static func spanExtent(for span: TileSpan, baseTileSize: CGFloat, tileSpacing: CGFloat) -> CGFloat {
        let spanCount = CGFloat(span.rawValue)
        return baseTileSize * spanCount + tileSpacing * max(0, spanCount - 1)
    }

    /// Total content size for the given tile list, including inter-tile spacing
    /// and outer stack padding. Used by MainWindow to size itself to fit.
    static func dockContentLayout(
        partition: PresentedTileDockPartition<Tile>,
        tileSize: CGFloat,
        tileHeight: CGFloat,
        tileSpacing: CGFloat,
        position: ResolvedDockWindowPosition,
        compactWidgets: Bool = false,
        mainEdgePadding: CGFloat = Self.edgePadding,
        handoffEdgePadding: CGFloat =
            Self.handoffDockEdgePadding,
        interDockGap: CGFloat = Self.handoffDockGap
    ) -> DockTileSurfaceContentLayout {
        let mainSizes = partition.mainItems.map {
            size(
                for: $0,
                tileSize: tileSize,
                tileHeight: tileHeight,
                tileSpacing: tileSpacing,
                position: position,
                compactWidgets: compactWidgets
            )
        }
        let handoffSizes = partition.handoffItems.map {
            size(
                for: $0,
                tileSize: tileSize,
                tileHeight: tileHeight,
                tileSpacing: tileSpacing,
                position: position,
                compactWidgets: compactWidgets
            )
        }
        let axisLayout =
            PresentedTileDockAxisMetrics.measure(
                mainItemExtents: mainSizes.map {
                    position.isVertical
                        ? $0.height
                        : $0.width
                },
                handoffItemExtents: handoffSizes.map {
                    position.isVertical
                        ? $0.height
                        : $0.width
                },
                itemSpacing: tileSpacing,
                mainEdgePadding: mainEdgePadding,
                handoffEdgePadding: handoffEdgePadding,
                interDockGap: interDockGap
            )

        let mainCrossExtent: CGFloat =
            position.isVertical
            ? (mainSizes.map(\.width).max() ?? 0)
            : (mainSizes.map(\.height).max() ?? 0)
        let handoffCrossExtent: CGFloat =
            position.isVertical
            ? (handoffSizes.map(\.width).max() ?? 0)
            : (handoffSizes.map(\.height).max() ?? 0)
        let combinedCrossExtent = max(
            mainCrossExtent,
            handoffCrossExtent
        )

        if position.isVertical {
            return DockTileSurfaceContentLayout(
                primarySize: CGSize(
                    width: mainCrossExtent,
                    height: axisLayout.mainDockExtent
                ),
                handoffSize: CGSize(
                    width: handoffCrossExtent,
                    height: axisLayout.handoffDockExtent
                ),
                interDockGap: axisLayout.interDockGap,
                combinedSize: CGSize(
                    width: combinedCrossExtent,
                    height: axisLayout.totalExtent
                )
            )
        }
        return DockTileSurfaceContentLayout(
            primarySize: CGSize(
                width: axisLayout.mainDockExtent,
                height: mainCrossExtent
            ),
            handoffSize: CGSize(
                width: axisLayout.handoffDockExtent,
                height: handoffCrossExtent
            ),
            interDockGap: axisLayout.interDockGap,
            combinedSize: CGSize(
                width: axisLayout.totalExtent,
                height: combinedCrossExtent
            )
        )
    }

    static func contentSize(
        tiles: [Tile],
        tileSize: CGFloat,
        tileHeight: CGFloat,
        tileSpacing: CGFloat,
        position: ResolvedDockWindowPosition,
        compactWidgets: Bool = false,
        edgePadding: CGFloat = Self.edgePadding
    ) -> CGSize {
        let sizes = tiles.map {
            size(for: $0, tileSize: tileSize, tileHeight: tileHeight, tileSpacing: tileSpacing, position: position, compactWidgets: compactWidgets)
        }
        if position.isVertical {
            let height = PresentedTileAxisMetrics.extent(
                itemExtents: sizes.map(\.height),
                spacing: tileSpacing,
                edgePadding: edgePadding
            )
            let width = sizes.map(\.width).max() ?? tileSize
            return CGSize(width: width, height: height)
        }

        let width = PresentedTileAxisMetrics.extent(
            itemExtents: sizes.map(\.width),
            spacing: tileSpacing,
            edgePadding: edgePadding
        )
        let height = sizes.map(\.height).max() ?? tileHeight
        return CGSize(width: width, height: height)
    }

    private static func resolvedPaletteWidgetSpan(
        ownerBundleIdentifier: String,
        kind: WidgetKind,
        requestedSpan: TileSpan?
    ) -> TileSpan {
        let supportedSpans = kind.supportedSpans
        if let requestedSpan, supportedSpans.contains(requestedSpan) {
            return requestedSpan
        }

        if let catalogSpan = WidgetCatalog.staticRegistrations.first(where: {
            $0.ownerBundleIdentifier == ownerBundleIdentifier && $0.kind == kind
        })?.defaultSpan,
           supportedSpans.contains(catalogSpan) {
            return catalogSpan
        }

        return supportedSpans.last ?? .one
    }
}

private struct TileLayoutSection: Identifiable {
    let index: Int
    let id: String
    let tiles: [Tile]
}

private enum TileLayoutComponent: Identifiable {
    case section(TileLayoutSection)
    case divider(Tile)

    var id: String {
        switch self {
        case .section(let section):
            "section:\(section.id)"
        case .divider(let tile):
            tile.id
        }
    }

    var index: Int? {
        switch self {
        case .section(let section):
            return section.index
        default:
            return nil
        }
    }
}

private struct ScrollableSectionLayout {
    let index: Int
    let id: String
    let axisLength: CGFloat
}

private struct TileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TileDragKeyMonitor: NSViewRepresentable {
    let keyDownHandler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(keyDownHandler: keyDownHandler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.keyDownHandler = keyDownHandler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var keyDownHandler: (NSEvent) -> Bool
        private var eventMonitor: Any?

        init(keyDownHandler: @escaping (NSEvent) -> Bool) {
            self.keyDownHandler = keyDownHandler
        }

        func start() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.keyDownHandler(event) ? nil : event
            }
        }

        func stop() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        deinit {
            stop()
        }
    }
}
