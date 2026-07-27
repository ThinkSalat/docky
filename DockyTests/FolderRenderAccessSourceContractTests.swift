import Foundation
import XCTest

final class FolderRenderAccessSourceContractTests: XCTestCase {
    func testFolderTileRenderingUsesOnlyCachedProtectedFolderData() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderTileView.swift")

        XCTAssertTrue(source.contains("cachedRecentContents("))
        XCTAssertTrue(source.contains("cachedIcon(forFileURL:"))
        XCTAssertFalse(source.contains("loadSnapshot("))
        XCTAssertFalse(source.contains("beginWatching("))
        XCTAssertFalse(source.contains("previewIcon(forFileURL:"))
        XCTAssertFalse(source.contains("resourceValues(forKeys:"))
    }

    func testCachedFolderSortingCannotReinspectItemURLs() throws {
        let source = try sourceFile("Docky/Services/FolderAccessService.swift")
        let cachedSorting = try sourceSection(
            in: source,
            startingWith: "    func cachedContentsIfPresent(",
            endingWith: "    /// Starts observing a folder"
        )

        XCTAssertFalse(cachedSorting.contains("contentsOfDirectory("))
        XCTAssertFalse(cachedSorting.contains("resourceValues(forKeys:"))
        XCTAssertFalse(cachedSorting.contains("FolderSortEntry.init"))
        XCTAssertEqual(
            source.components(separatedBy: "FolderSortEntry.init").count - 1,
            1,
            "Sort metadata must be captured only by explicit loadSnapshot."
        )
    }

    func testExplicitFolderEnumerationRunsOffMainActor() throws {
        let source = try sourceFile(
            "Docky/Services/FolderAccessService.swift"
        )
        let publicLoad = try sourceSection(
            in: source,
            startingWith: "    func loadSnapshot(",
            endingWith: "    /// Returns only data"
        )
        XCTAssertTrue(publicLoad.contains("await request.task.value"))
        XCTAssertFalse(publicLoad.contains("contentsOfDirectory("))
        XCTAssertFalse(publicLoad.contains("resourceValues(forKeys:"))

        let worker = try sourceSection(
            in: source,
            startingWith:
                "private nonisolated final class FolderSnapshotLoadWorker:",
            endingWith: "\n}"
        )
        XCTAssertTrue(worker.contains("queue.async"))
        XCTAssertTrue(worker.contains("contentsOfDirectory("))
        XCTAssertTrue(
            worker.contains("discoveredItems.map(FolderSortEntry.init)")
        )

        let metadata = try sourceSection(
            in: source,
            startingWith:
                "private nonisolated struct FolderSortEntry:",
            endingWith:
                "private nonisolated struct LoadedFolderContents:"
        )
        XCTAssertTrue(metadata.contains("resourceValues(forKeys:"))
        XCTAssertTrue(metadata.contains(".isPackageKey"))
    }

    func testFolderLoadGenerationRejectsWatcherStaleResults() throws {
        let source = try sourceFile(
            "Docky/Services/FolderAccessService.swift"
        )
        let publicLoad = try sourceSection(
            in: source,
            startingWith: "    func loadSnapshot(",
            endingWith: "    /// Returns only data"
        )
        XCTAssertTrue(
            publicLoad.contains(
                "loadGenerationByURL[normalizedFolderURL, default: 0]"
            )
        )
        XCTAssertTrue(
            publicLoad.contains("== request.generation else")
        )

        let invalidation = try sourceSection(
            in: source,
            startingWith: "    func invalidateCache(of folderURL:",
            endingWith: "    private func handleWatcherEvent("
        )
        XCTAssertTrue(
            invalidation.contains(
                "advanceLoadGeneration(for: normalizedFolderURL)"
            )
        )
        XCTAssertTrue(
            invalidation.contains(
                "inFlightLoads.removeValue(forKey: normalizedFolderURL)"
            )
        )

        let worker = try sourceSection(
            in: source,
            startingWith:
                "private nonisolated final class FolderSnapshotLoadWorker:",
            endingWith: "\n}"
        )
        XCTAssertTrue(worker.contains("attributes: .concurrent"))
    }

    func testFolderWatcherRetiresTerminalSourceBeforePublishingChange() throws {
        let source = try sourceFile("Docky/Services/FolderAccessService.swift")
        let beginWatching = try sourceSection(
            in: source,
            startingWith: "    func beginWatching(",
            endingWith: "    func endWatching("
        )
        XCTAssertTrue(
            beginWatching.contains(
                "watcherOwnerIDsByURL[normalizedFolderURL, default: []]"
            )
        )
        XCTAssertTrue(
            beginWatching.contains(
                "startOpeningWatcherIfNeeded(for: normalizedFolderURL)"
            )
        )
        XCTAssertFalse(beginWatching.contains("O_EVTONLY"))
        XCTAssertFalse(beginWatching.contains("open("))

        let handler = try sourceSection(
            in: source,
            startingWith: "    private func handleWatcherEvent(",
            endingWith: "\n\n}"
        )
        XCTAssertTrue(handler.contains(".rename"))
        XCTAssertTrue(handler.contains(".delete"))
        XCTAssertTrue(handler.contains(".revoke"))

        let removal = try XCTUnwrap(
            handler.range(of: "watchersByURL.removeValue")
        )
        let cancellation = try XCTUnwrap(
            handler.range(of: "watcher.source.cancel()")
        )
        let publication = try XCTUnwrap(
            handler.range(of: "changeToken &+= 1")
        )
        XCTAssertLessThan(removal.lowerBound, cancellation.lowerBound)
        XCTAssertLessThan(cancellation.lowerBound, publication.lowerBound)
    }

    func testFolderWatcherDescriptorOpenIsOffMainAndLifecycleValidated() throws {
        let source = try sourceFile("Docky/Services/FolderAccessService.swift")
        let descriptorWorker = try sourceSection(
            in: source,
            startingWith:
                "private nonisolated final class FolderWatcherDescriptorWorker:",
            endingWith: "/// Filesystem worker."
        )
        XCTAssertTrue(descriptorWorker.contains("queue.async"))
        XCTAssertTrue(
            descriptorWorker.contains("O_EVTONLY | O_CLOEXEC")
        )

        let watcherOpen = try sourceSection(
            in: source,
            startingWith:
                "    private func startOpeningWatcherIfNeeded(",
            endingWith: "    private func handleWatcherEvent("
        )
        XCTAssertTrue(
            watcherOpen.contains(
                "await descriptorWorker.openDescriptor("
            )
        )
        XCTAssertTrue(
            watcherOpen.contains(
                "watcherGenerationByURL[folderURL, default: 0] == generation"
            )
        )
        XCTAssertTrue(
            watcherOpen.contains(
                "!requestOwnerIDs.isDisjoint(with: currentOwnerIDs)"
            )
        )
        XCTAssertTrue(watcherOpen.contains("close(descriptor)"))

        let endWatching = try sourceSection(
            in: source,
            startingWith: "    func endWatching(",
            endingWith: "    func invalidateCache()"
        )
        XCTAssertTrue(
            endWatching.contains(
                "watcherGenerationByURL[normalizedFolderURL, default: 0] &+= 1"
            )
        )
        XCTAssertTrue(
            endWatching.contains(
                "inFlightWatcherOpens.removeValue"
            )
        )
        XCTAssertTrue(endWatching.contains(".task.cancel()"))
    }

    func testFolderWatcherRejectsEventsFromRetiredSources() throws {
        let source = try sourceFile("Docky/Services/FolderAccessService.swift")
        let handler = try sourceSection(
            in: source,
            startingWith: "    private func handleWatcherEvent(",
            endingWith: "\n\n}"
        )
        XCTAssertTrue(handler.contains("watcherID: UUID"))
        XCTAssertTrue(handler.contains("watcher.id == watcherID"))

        let installation = try sourceSection(
            in: source,
            startingWith: "    private func finishOpeningWatcher(",
            endingWith: "    private func handleWatcherEvent("
        )
        XCTAssertTrue(installation.contains("let watcherID = UUID()"))
        XCTAssertTrue(
            installation.contains(
                "handleWatcherEvent(\n" +
                "                for: folderURL,\n" +
                "                watcherID: watcherID"
            )
        )
    }

    func testFolderPopoverAdoptsExplicitInitialSnapshotBeforeRefreshing() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderPopoverView.swift")
        let reloadTask = try sourceSection(
            in: source,
            startingWith: "            .task(id: reloadKey)",
            endingWith: "            .onDisappear"
        )
        XCTAssertTrue(reloadTask.contains("if hasAdoptedInitialSnapshot"))
        XCTAssertTrue(reloadTask.contains("adoptInitialSnapshot()"))
        let adoptionCall = try XCTUnwrap(
            reloadTask.range(of: "adoptInitialSnapshot()")
        )
        let watcherSync = try XCTUnwrap(
            reloadTask.range(of: "syncWatchedFolder()")
        )
        XCTAssertLessThan(adoptionCall.lowerBound, watcherSync.lowerBound)

        let adoption = try sourceSection(
            in: source,
            startingWith: "    private func adoptInitialSnapshot()",
            endingWith: "    private func refreshEntriesIfNeeded() async"
        )
        XCTAssertTrue(adoption.contains("snapshot: initialSnapshot"))
        XCTAssertFalse(adoption.contains("loadSnapshot("))

        let disappearance = try sourceSection(
            in: source,
            startingWith: "            .onDisappear {",
            endingWith: "    @ViewBuilder"
        )
        XCTAssertTrue(
            disappearance.contains("hasAdoptedInitialSnapshot = false")
        )
    }

    func testLoadedPopoverSnapshotSurvivesCacheInvalidation() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderPopoverView.swift")
        let items = try sourceSection(
            in: source,
            startingWith: "    private var items:",
            endingWith: "    private var popoverItems:"
        )

        XCTAssertTrue(
            items.contains(
                "guard case .loaded(let snapshotItems) = currentEntry.snapshot"
            )
        )
        XCTAssertTrue(
            items.contains(
                "cachedContentsIfPresent(\n" +
                "            of: currentEntry.url"
            )
        )
        XCTAssertTrue(items.contains(") ?? snapshotItems"))

        let navigateBack = try sourceSection(
            in: source,
            startingWith: "    private func navigateBack()",
            endingWith: "    private func open("
        )
        XCTAssertTrue(
            navigateBack.contains(
                "let refreshed = await refreshedEntry(for: previousEntry)"
            )
        )
        XCTAssertTrue(navigateBack.contains("guard !Task.isCancelled"))
        XCTAssertTrue(
            navigateBack.contains("currentEntry = refreshed")
        )
        XCTAssertTrue(
            navigateBack.contains(
                "lastHandledChangeToken = folderAccess.changeToken"
            )
        )
    }

    func testUnreadableFolderStateNeverLoadsAnIconFromItsURL() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderPopoverView.swift")
        let unreadableState = try sourceSection(
            in: source,
            startingWith: "    private var unreadableState:",
            endingWith: "    private var navigationHeader:"
        )

        XCTAssertTrue(unreadableState.contains("unreadableFolderIcon"))
        XCTAssertTrue(unreadableState.contains("cachedIcon(forFileURL:"))
        XCTAssertTrue(unreadableState.contains("systemSymbolName: \"folder.fill\""))
        XCTAssertFalse(
            unreadableState.contains(
                "IconCacheService.shared.icon(forFileURL:"
            )
        )
        XCTAssertFalse(unreadableState.contains("previewIcon(forFileURL:"))
    }

    func testFolderPopoverRenderingLoadsColdIconsAsynchronously() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderPopoverView.swift")
        let item = try sourceSection(
            in: source,
            startingWith: "private struct FolderPopoverItemView:",
            endingWith: "private struct FolderPopoverAsyncIcon:"
        )
        XCTAssertTrue(item.contains("FolderPopoverAsyncIcon("))
        XCTAssertFalse(item.contains("previewIcon(forFileURL:"))
        XCTAssertFalse(item.contains(".icon(forFileURL:"))
        XCTAssertFalse(item.contains("resourceValues(forKeys:"))

        let asyncIcon = try sourceSection(
            in: source,
            startingWith: "private struct FolderPopoverAsyncIcon:",
            endingWith: "private struct FolderPopoverActionItemView:"
        )
        XCTAssertTrue(asyncIcon.contains("cachedIcon(forFileURL:"))
        XCTAssertTrue(asyncIcon.contains("await IconCacheService.shared.loadPreviewIconAsync("))
        XCTAssertTrue(asyncIcon.contains("guard !Task.isCancelled"))

        let emptyState = try sourceSection(
            in: source,
            startingWith: "    private var emptyState:",
            endingWith: "    private var unreadableState:"
        )
        XCTAssertTrue(emptyState.contains("FolderPopoverAsyncIcon("))
        XCTAssertFalse(emptyState.contains(".icon(forFileURL:"))
    }

    func testFolderPopoverDismissalRetiresAllPendingLoads() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderPopoverView.swift")
        let reloadTask = try sourceSection(
            in: source,
            startingWith: "            .task(id: reloadKey)",
            endingWith: "            .onDisappear"
        )
        XCTAssertTrue(reloadTask.contains("guard isPresented else"))
        XCTAssertTrue(reloadTask.contains("cancelNavigationTask()"))
        XCTAssertTrue(reloadTask.contains("cancelSubfolderSpringLoad()"))
        XCTAssertTrue(reloadTask.contains("cancelDropTask()"))

        let refresh = try sourceSection(
            in: source,
            startingWith: "    private func refreshEntriesIfNeeded() async",
            endingWith: "    private func navigateIntoFolder("
        )
        XCTAssertTrue(refresh.contains("guard !Task.isCancelled, isPresented"))
        XCTAssertFalse(refresh.contains("for entry in backHistory"))
    }

    func testFolderDropFilesystemWorkRunsOffMainAndCannotDismissStaleUI() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderPopoverView.swift")
        let dropEntryPoint = try sourceSection(
            in: source,
            startingWith: "    private func moveDroppedFiles(",
            endingWith: "    private func collectDroppedFileURLs("
        )
        XCTAssertTrue(dropEntryPoint.contains("dropGeneration == generation"))
        XCTAssertTrue(dropEntryPoint.contains("isPresented"))
        XCTAssertTrue(
            dropEntryPoint.contains(
                "await FolderDropOperationWorker.shared.moveOrCopy("
            )
        )
        XCTAssertEqual(
            dropEntryPoint.components(
                separatedBy: "dropGeneration == generation"
            ).count - 1,
            2,
            "The drop must be lifecycle-checked before and after filesystem work."
        )
        XCTAssertFalse(dropEntryPoint.contains("FileManager.default"))

        let worker = try sourceSection(
            in: source,
            startingWith:
                "private nonisolated final class FolderDropOperationWorker:",
            endingWith: "private struct FolderPopoverEntry:"
        )
        XCTAssertTrue(worker.contains("queue.async"))
        XCTAssertTrue(worker.contains("FileManager.default.moveItem"))
        XCTAssertTrue(worker.contains("FileManager.default.copyItem"))

        let cancellation = try sourceSection(
            in: source,
            startingWith: "    private func cancelDropTask()",
            endingWith: "    /// Drives subfolder spring-loading:"
        )
        XCTAssertTrue(cancellation.contains("dropGeneration &+= 1"))
        XCTAssertTrue(cancellation.contains("dropTask?.cancel()"))
    }

    func testFolderFanNamesUseSnapshotMetadataWithoutFilesystemReads() throws {
        let source = try sourceFile("Docky/Views/Tiles/FolderFanView.swift")
        let displayName = try sourceSection(
            in: source,
            startingWith: "    private func displayName(for url:",
            endingWith: "    /// Y offset for the fan"
        )
        XCTAssertTrue(
            displayName.contains(
                "FolderAccessService.shared.cachedMetadata("
            )
        )
        XCTAssertTrue(displayName.contains("in: folderURL"))
        XCTAssertTrue(displayName.contains("url.lastPathComponent"))
        XCTAssertFalse(displayName.contains("resourceValues(forKeys:"))
    }

    func testSpringLoadedFolderUsesSameModeAwareExplicitOpenPathAsTap() throws {
        let source = try sourceFile("Docky/Views/Tiles/TileView.swift")
        let springLoad = try sourceSection(
            in: source,
            startingWith: "            .onChange(of: dockDrag.springLoadedTileID)",
            endingWith: "            .background {"
        )
        XCTAssertTrue(
            springLoad.contains(
                "handleExplicitFolderOpen(\n" +
                "                        folder,\n" +
                "                        behavior: .ensurePresented"
            )
        )

        XCTAssertEqual(
            source.components(
                separatedBy: "handleExplicitFolderOpen("
            ).count - 1,
            3,
            "The shared path must have one definition plus tap and spring-load callers."
        )

        let explicitOpen = try sourceSection(
            in: source,
            startingWith: "    private func handleExplicitFolderOpen(",
            endingWith: "    /// Children for the \"View Content as\" submenu"
        )
        XCTAssertTrue(explicitOpen.contains("case .finder:"))
        XCTAssertTrue(explicitOpen.contains("case .list:"))
        XCTAssertTrue(explicitOpen.contains("case .grid, .inline, .fan:"))

        let snapshotLoad = try XCTUnwrap(
            explicitOpen.range(
                of: "let snapshot = await FolderAccessService.shared.loadSnapshot("
            )
        )
        let cancellationGate = try XCTUnwrap(
            explicitOpen.range(
                of: "guard !Task.isCancelled",
                range: snapshotLoad.upperBound..<explicitOpen.endIndex
            )
        )
        let snapshotPublication = try XCTUnwrap(
            explicitOpen.range(
                of: "folderSnapshot = snapshot",
                range: cancellationGate.upperBound..<explicitOpen.endIndex
            )
        )
        let presentation = try XCTUnwrap(
            explicitOpen.range(
                of: "isFolderPopoverPresented = true",
                range: snapshotPublication.upperBound..<explicitOpen.endIndex
            )
        )
        XCTAssertLessThan(
            snapshotLoad.lowerBound,
            cancellationGate.lowerBound
        )
        XCTAssertLessThan(
            cancellationGate.lowerBound,
            snapshotPublication.lowerBound
        )
        XCTAssertLessThan(
            snapshotPublication.lowerBound,
            presentation.lowerBound
        )
    }

    func testFolderMenusUseAsyncLoadsAndCachedMetadata() throws {
        let source = try sourceFile("Docky/Views/Tiles/TileView.swift")
        let listPresenter = try sourceSection(
            in: source,
            startingWith: "private struct FolderListMenuPresenter:",
            endingWith: "private final class FolderListMenuAnchorView:"
        )
        XCTAssertTrue(
            listPresenter.contains(
                "await FolderAccessService.shared.loadSnapshot("
            )
        )
        XCTAssertTrue(
            listPresenter.contains(
                "FolderAccessService.shared.cachedMetadata("
            )
        )
        XCTAssertFalse(
            listPresenter.contains("resourceValues(forKeys:")
        )
        XCTAssertFalse(
            listPresenter.contains("previewIcon(forFileURL:")
        )
        XCTAssertTrue(
            listPresenter.contains("rootLoadTask == nil")
        )

        let navigation = try sourceSection(
            in: source,
            startingWith:
                "private func folderNavigationContextActions(",
            endingWith: "\nfunc fileContextActions("
        )
        XCTAssertTrue(
            navigation.contains(
                "await FolderAccessService.shared.loadSnapshot("
            )
        )
        XCTAssertTrue(
            navigation.contains(
                "FolderAccessService.shared.cachedMetadata("
            )
        )
        XCTAssertFalse(navigation.contains("resourceValues(forKeys:"))
        XCTAssertFalse(navigation.contains(".icon(forFileURL:"))
    }

    func testFolderSubmenuAsyncReplacementKeepsStableGeometry() throws {
        let source = try sourceFile("Docky/Views/Tiles/TileView.swift")
        let listPresenter = try sourceSection(
            in: source,
            startingWith: "private struct FolderListMenuPresenter:",
            endingWith: "private final class FolderListMenuAnchorView:"
        )
        XCTAssertTrue(
            listPresenter.contains("loadingPlaceholderRowCount = 4")
        )
        XCTAssertTrue(
            listPresenter.contains("installStableLoadingItems(in: menu)")
        )
        XCTAssertTrue(
            listPresenter.contains("self.activePresentation != nil")
        )
        XCTAssertTrue(listPresenter.contains("self.activeMenu != nil"))
        XCTAssertTrue(listPresenter.contains("menu.supermenu != nil"))
        XCTAssertTrue(listPresenter.contains("menu.update()"))
        XCTAssertTrue(listPresenter.contains("_ = menu.size"))

        let rootLoad = try sourceSection(
            in: String(listPresenter),
            startingWith: "            rootLoadTask = Task",
            endingWith: "        private func show("
        )
        let snapshotLoad = try XCTUnwrap(
            rootLoad.range(
                of: "await FolderAccessService.shared.loadSnapshot("
            )
        )
        let strongSelf = rootLoad.range(
            of: "guard let self",
            range: rootLoad.startIndex..<snapshotLoad.lowerBound
        )
        XCTAssertNil(
            strongSelf,
            "A hung folder load must not retain its menu coordinator."
        )

        let submenuLoad = try sourceSection(
            in: String(listPresenter),
            startingWith:
                "            submenuLoadTaskByMenuID[menuID] =",
            endingWith: "        func menuDidClose("
        )
        let nestedSnapshotLoad = try XCTUnwrap(
            submenuLoad.range(
                of: "await FolderAccessService.shared.loadSnapshot("
            )
        )
        let nestedStrongSelf = submenuLoad.range(
            of: "guard let self",
            range:
                submenuLoad.startIndex..<nestedSnapshotLoad.lowerBound
        )
        XCTAssertNil(
            nestedStrongSelf,
            "A hung submenu load must not retain its menu coordinator."
        )
    }

    func testContextActionProviderRunsOnlyAfterQualifiedClickHitTest() throws {
        let source = try sourceFile("Docky/Views/Tiles/ContextActionPopover.swift")
        let preClickLifecycle = try sourceSection(
            in: source,
            startingWith: "struct ContextActionMenuPresenter: NSViewRepresentable {",
            endingWith: "        private func handleContextClick("
        )
        XCTAssertFalse(
            preClickLifecycle.contains("actionProvider("),
            "Mounting or updating a presenter must never evaluate its action provider."
        )

        let clickHandler = try sourceSection(
            in: source,
            startingWith: "        private func handleContextClick(_ event: NSEvent) -> NSEvent? {",
            endingWith: "        private func popUpCartouche("
        )
        let qualification = try XCTUnwrap(
            clickHandler.range(of: "guard isRightClick || isControlClick else")
        )
        let hitTest = try XCTUnwrap(
            clickHandler.range(of: "guard view.bounds.contains(location) else")
        )
        let provider = try XCTUnwrap(
            clickHandler.range(of: "let actions = actionProvider(event.modifierFlags)")
        )
        XCTAssertLessThan(qualification.lowerBound, hitTest.lowerBound)
        XCTAssertLessThan(hitTest.lowerBound, provider.lowerBound)
    }

    func testStartMenuHostingRootIsCreatedOnlyDuringPresentation() throws {
        let source = try sourceFile(
            "Docky/Views/MainWindow/StartMenuOverlayWindowController.swift"
        )
        XCTAssertTrue(
            source.contains(
                "private var hostingController: NSHostingController<StartMenuView>?"
            )
        )

        let initializer = try sourceSection(
            in: source,
            startingWith: "    init(mainWindow: MainWindow) {",
            endingWith: "    @available(*, unavailable)"
        )
        XCTAssertFalse(initializer.contains("StartMenuView()"))
        XCTAssertFalse(initializer.contains("contentViewController"))
        XCTAssertEqual(
            source.components(separatedBy: "StartMenuView()").count - 1,
            1,
            "The SwiftUI root must have only one construction site."
        )

        let presentation = try sourceSection(
            in: source,
            startingWith: "    private func present() {",
            endingWith: "    private func dismiss() {"
        )
        let installationCall = try XCTUnwrap(
            presentation.range(of: "installHostingRootIfNeeded(on: panel)")
        )
        let ordering = try XCTUnwrap(
            presentation.range(of: "panel.makeKeyAndOrderFront(nil)")
        )
        XCTAssertLessThan(installationCall.lowerBound, ordering.lowerBound)
    }

    func testStartMenuHomeIconsCannotColdLoadProtectedFolderMetadata() throws {
        let source = try sourceFile(
            "Docky/Views/MainWindow/StartMenuOverlayWindowController.swift"
        )
        let homeSection = try sourceSection(
            in: source,
            startingWith: "    private var homeSection:",
            endingWith: "    @ViewBuilder\n    private var recentsSection:"
        )

        XCTAssertTrue(homeSection.contains("CachedAsyncFileImage("))
        XCTAssertTrue(homeSection.contains("Image(systemName: \"folder.fill\")"))
        XCTAssertFalse(homeSection.contains(".icon(forFileURL:"))
        XCTAssertFalse(homeSection.contains("NSWorkspace.shared.icon"))
        XCTAssertFalse(homeSection.contains("NSImage(contentsOf:"))
    }

    func testTrashFilesystemReadsAndWatcherOpenStayOffMainActor() throws {
        let source = try sourceFile("Docky/Services/TrashService.swift")
        let service = try sourceSection(
            in: source,
            startingWith: "final class TrashService:",
            endingWith: "private nonisolated final class TrashFilesystemWorker:"
        )
        XCTAssertTrue(service.contains("await worker.isEmpty(trashURL)"))
        XCTAssertTrue(service.contains("await worker.openWatcher(trashURL)"))
        XCTAssertFalse(service.contains("contentsOfDirectory("))
        XCTAssertFalse(service.contains("enumerator("))

        let worker = try sourceSection(
            in: source,
            startingWith:
                "private nonisolated final class TrashFilesystemWorker:",
            endingWith: "\n}"
        )
        XCTAssertTrue(worker.contains("queue.async"))
        XCTAssertTrue(worker.contains("FileManager.default.enumerator("))
        XCTAssertTrue(worker.contains("O_EVTONLY | O_CLOEXEC"))
    }

    func testFirstLaunchpadPresentationNeverScansApplicationsInline() throws {
        let source = try sourceFile(
            "Docky/Services/LaunchpadOverlayService.swift"
        )
        let presentation = try sourceSection(
            in: source,
            startingWith: "    func present() {",
            endingWith: "    func dismiss() {"
        )
        XCTAssertTrue(presentation.contains("scheduleRescan(delay: 0)"))
        XCTAssertFalse(presentation.contains("scanApplications()"))
        XCTAssertFalse(presentation.contains("applyScan("))
    }

    func testConfiguredChromeImagesNeverDecodeDuringSwiftUIRendering() throws {
        for path in [
            "Docky/Views/Tiles/TileView.swift",
            "Docky/Views/Tiles/DividerTileView.swift",
            "Docky/Views/MainWindow/MainWindowView.swift"
        ] {
            let source = try sourceFile(path)
            XCTAssertFalse(
                source.contains("NSImage(contentsOf:"),
                "\(path) must render cached images and schedule cold decoding."
            )
            XCTAssertTrue(source.contains("CachedAsyncImageFile("))
        }

        let asyncView = try sourceFile(
            "Docky/Views/Components/CachedAsyncImageFile.swift"
        )
        XCTAssertTrue(asyncView.contains(".task(id: requestKey)"))
        XCTAssertTrue(
            asyncView.contains(
                "await IconCacheService.shared.loadImageAsync("
            )
        )
        XCTAssertTrue(asyncView.contains("guard !Task.isCancelled"))
    }

    func testColdConfiguredImageDecodesAreOffMainAndCoalesced() throws {
        let source = try sourceFile("Docky/Services/IconCacheService.swift")
        let loader = try sourceSection(
            in: source,
            startingWith:
                "    func loadImageAsync(forImageFileURL url: URL)",
            endingWith:
                "    /// Cached-only counterpart"
        )
        XCTAssertTrue(loader.contains("pendingImageLoad("))
        XCTAssertFalse(loader.contains("NSImage(contentsOf:"))

        let worker = try sourceSection(
            in: source,
            startingWith: "    private func pendingImageLoad(",
            endingWith: "    private static func isImageFileURL"
        )
        XCTAssertTrue(worker.contains("Task.detached("))
        XCTAssertTrue(worker.contains("pendingImageLoads[path]"))
        XCTAssertTrue(worker.contains("LocalImageDecoder.decode(at: url)"))
    }

    func testCoreTileIconsNeverColdLoadDuringSwiftUIRendering() throws {
        for path in [
            "Docky/Views/Tiles/AppTileView.swift",
            "Docky/Views/Tiles/TrashTileView.swift",
            "Docky/Views/Tiles/FolderTileView.swift",
            "Docky/Views/Tiles/MinimizedWindowTileView.swift",
            "Docky/Views/Tiles/AppFolderTileView.swift",
            "Docky/Views/Tiles/FolderFanView.swift",
        ] {
            let source = try sourceFile(path)
            XCTAssertFalse(
                source.contains(".image(forImageFileURL:"),
                "\(path) must decode configured images asynchronously."
            )
            XCTAssertFalse(
                source.contains(".previewIcon(forFileURL:"),
                "\(path) must not inspect a cold file while rendering."
            )
        }
    }

    func testEffectiveManagedAssetURLsAreLexicalDuringRendering() throws {
        let preferences = try sourceFile(
            "Docky/Services/DockyPreferences.swift"
        )
        XCTAssertFalse(
            preferences.contains("ManagedUserAssetStore.managedURL(")
        )
        XCTAssertTrue(
            preferences.contains(
                "ManagedUserAssetStore.managedCandidateURL("
            )
        )

        let store = try sourceFile(
            "Docky/Models/ManagedUserAssetStore.swift"
        )
        let candidateResolver = try sourceSection(
            in: store,
            startingWith: "    static func managedCandidateURL(",
            endingWith: "    static func importAsset("
        )
        XCTAssertFalse(candidateResolver.contains("attributesOfItem("))
        XCTAssertFalse(candidateResolver.contains("fileExists("))
    }

    func testMenuCatalogLoadsBeforeTrackingAndReadsJSONOffMain() throws {
        let appDelegate = try sourceFile("Docky/AppDelegate.swift")
        XCTAssertTrue(appDelegate.contains("_ = MenuCatalogService.shared"))

        let catalog = try sourceFile(
            "Docky/Services/MenuCatalogService.swift"
        )
        let reload = try sourceSection(
            in: catalog,
            startingWith: "    func reload() {",
            endingWith: "    func contextActions("
        )
        XCTAssertTrue(reload.contains("Task.detached("))
        XCTAssertFalse(reload.contains("Data(contentsOf:"))

        let context = try sourceSection(
            in: catalog,
            startingWith: "    private func makeContext(",
            endingWith: "    private func tileType("
        )
        XCTAssertFalse(
            context.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
    }

    func testRecentFilesQueryAndIconsStayOffMainActor() throws {
        let source = try sourceFile(
            "Docky/Services/RecentFilesService.swift"
        )
        let service = try sourceSection(
            in: source,
            startingWith: "final class RecentFilesService:",
            endingWith:
                "private nonisolated final class RecentFilesWorker:"
        )
        XCTAssertTrue(service.contains("recentEntries"))
        XCTAssertTrue(service.contains("loadPreviewIconAsync("))
        XCTAssertFalse(service.contains("NSMetadataQuery()"))
        XCTAssertFalse(service.contains("resourceValues(forKeys:"))

        let worker = try sourceSection(
            in: source,
            startingWith:
                "private nonisolated final class RecentFilesWorker:",
            endingWith: "\n}"
        )
        XCTAssertTrue(worker.contains("queue.maxConcurrentOperationCount = 1"))
        XCTAssertTrue(worker.contains("query.operationQueue = queue"))
        XCTAssertTrue(worker.contains("NSMetadataItemDisplayNameKey"))
        XCTAssertFalse(worker.contains("operationQueue = .main"))
    }

    func testStartMenuBodyUsesPublishedAppAndRecentSnapshots() throws {
        let source = try sourceFile(
            "Docky/Views/MainWindow/StartMenuOverlayWindowController.swift"
        )
        let view = try sourceSection(
            in: source,
            startingWith: "private struct StartMenuView: View {",
            endingWith: "private struct HomeFolderShortcut:"
        )
        XCTAssertTrue(view.contains("recents.recentEntries"))
        XCTAssertTrue(view.contains("CachedAsyncFileImage("))
        XCTAssertTrue(view.contains("CachedAsyncAppImage("))
        XCTAssertFalse(
            view.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
        XCTAssertFalse(
            view.contains(
                "IconCacheService.shared.icon(forFileURL:"
            )
        )
        XCTAssertFalse(
            view.contains(
                "IconCacheService.shared.icon(forBundleIdentifier:"
            )
        )
        XCTAssertFalse(
            view.contains(
                "IconCacheService.shared.cachedIcon(forBundleIdentifier:"
            )
        )
    }

    func testApplicationURLResolutionCannotBlockTileClicks() throws {
        let workspace = try sourceFile(
            "Docky/Services/WorkspaceService.swift"
        )
        XCTAssertFalse(
            workspace.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
        XCTAssertTrue(
            workspace.contains(
                "await ApplicationURLResolver.shared"
            )
        )

        let resolver = try sourceFile(
            "Docky/Services/ApplicationURLResolver.swift"
        )
        XCTAssertTrue(resolver.contains("Task.detached("))
        XCTAssertTrue(resolver.contains("PendingResolution"))
        XCTAssertTrue(resolver.contains("generationByBundleIdentifier"))
        XCTAssertTrue(resolver.contains("missingRetryDelay"))
        XCTAssertTrue(resolver.contains("?.task.cancel()"))
        XCTAssertTrue(
            resolver.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
        XCTAssertTrue(
            resolver.contains("inFlightByBundleIdentifier")
        )
    }

    func testTileStoreRebuildsUsePublishedApplicationMetadata() throws {
        let source = try sourceFile("Docky/Services/TileStore.swift")
        let reload = try sourceSection(
            in: source,
            startingWith: "    private func reloadSystemDockState(",
            endingWith: "    private func applySystemDockSnapshot("
        )
        XCTAssertTrue(reload.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(reload.contains("systemDockReloadGeneration"))
        XCTAssertFalse(reload.contains("DockPlistReader.read()"))

        let appTile = try sourceSection(
            in: source,
            startingWith: "    private func makeAppTile(bundleIdentifier:",
            endingWith: "\n    private static func makeWidgetTile("
        )
        XCTAssertTrue(
            appTile.contains("applicationTilesByBundleIdentifier")
        )
        XCTAssertTrue(
            appTile.contains("scheduleApplicationMetadataResolution")
        )
        XCTAssertFalse(
            appTile.contains("NSWorkspace.shared.urlForApplication(")
        )
        XCTAssertFalse(
            appTile.contains("FileManager.default.displayName(")
        )
    }

    func testProfileTriggerPickersUseWorkspaceSnapshots() throws {
        let source = try sourceFile(
            "Docky/Views/SettingsWindow/ProfilesSettingsView.swift"
        )
        XCTAssertTrue(source.contains("workspace.runningApps"))
        XCTAssertTrue(
            source.contains(
                "await ApplicationURLResolver.shared.applicationURL("
            )
        )
        XCTAssertFalse(
            source.contains("NSWorkspace.shared.runningApplications")
        )
        XCTAssertFalse(
            source.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
    }

    func testMenuClickProcessLookupNeverBlocksMainActor() throws {
        let source = try sourceFile(
            "Docky/Services/MenuClickService.swift"
        )
        let lookup = try sourceSection(
            in: source,
            startingWith: "    private func runningApplicationName(",
            endingWith: "    private func presentUnavailableAlert("
        )
        XCTAssertTrue(lookup.contains("WorkspaceService.shared.runningApps"))
        XCTAssertTrue(lookup.contains("Task.detached("))
        XCTAssertTrue(
            lookup.contains(
                "await ApplicationURLResolver.shared.applicationURL("
            )
        )
        XCTAssertFalse(
            lookup.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
    }

    func testSystemDockEditsPerformFilesystemWorkOffMainActor() throws {
        let source = try sourceFile(
            "Docky/Services/DockEditorService.swift"
        )
        let pinning = try sourceSection(
            in: source,
            startingWith: "    func setPinnedApp(",
            endingWith: "    @discardableResult\n    func setPinnedItemOrder("
        )
        XCTAssertTrue(pinning.contains("await worker.perform"))
        XCTAssertFalse(pinning.contains("Data(contentsOf:"))
        XCTAssertFalse(
            pinning.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )

        let ordering = try sourceSection(
            in: source,
            startingWith: "    func setPinnedItemOrder(",
            endingWith: "    nonisolated private static func updateDockPlist("
        )
        XCTAssertTrue(ordering.contains("await worker.perform"))
        XCTAssertFalse(ordering.contains("Data(contentsOf:"))
        XCTAssertTrue(source.contains("private actor DockPlistEditingWorker"))
    }

    func testAppFolderDragUsesPreloadedOrDeferredApplicationURLs() throws {
        let source = try sourceFile(
            "Docky/Views/Tiles/AppFolderTileView.swift"
        )
        let drag = try sourceSection(
            in: source,
            startingWith: "    private func beginDragOutOfFolder(",
            endingWith: "    private func preloadApplicationURLs() async"
        )
        XCTAssertTrue(
            drag.contains("applicationURLsByBundleIdentifier")
        )
        XCTAssertTrue(
            drag.contains("deferredApplicationItemProvider(")
        )
        XCTAssertFalse(
            drag.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )

        let preload = try sourceSection(
            in: source,
            startingWith: "    private func preloadApplicationURLs() async",
            endingWith: "    private func deferredApplicationItemProvider("
        )
        XCTAssertTrue(preload.contains("withTaskGroup("))
        XCTAssertTrue(
            preload.contains(
                "ApplicationURLResolver.shared"
            )
        )
        XCTAssertTrue(preload.contains("guard !Task.isCancelled"))
    }

    func testEveryCoalescedConfiguredImageWaiterReceivesTheResult() throws {
        let source = try sourceFile("Docky/Services/IconCacheService.swift")
        let finish = try sourceSection(
            in: source,
            startingWith: "    private func finishPendingImageLoad(",
            endingWith: "    private static func isImageFileURL"
        )
        XCTAssertTrue(
            finish.contains(
                "if pendingImageLoads[path]?.id == pending.id"
            )
        )
        XCTAssertTrue(finish.contains("return decoded?.image"))
        XCTAssertFalse(finish.contains("return cache.object(forKey: key)"))
        XCTAssertFalse(
            finish.contains(
                "pendingImageLoads[path]?.id == pending.id,\n"
                    + "              imageLoadGeneration"
            )
        )
    }

    func testFolderListSecondTapCancelsAColdPresentation() throws {
        let source = try sourceFile("Docky/Views/Tiles/TileView.swift")
        let handler = try sourceSection(
            in: source,
            startingWith: "    private func handleExplicitFolderOpen(",
            endingWith: "\n    private func handleWidgetTap("
        )
        XCTAssertTrue(
            handler.contains("if isFolderListMenuPresented {")
        )
        XCTAssertTrue(
            handler.contains("if behavior == .togglePresentation")
        )
        XCTAssertTrue(
            handler.contains("isFolderListMenuPresented = false")
        )
        XCTAssertFalse(
            handler.contains(
                "guard !isFolderListMenuPresented else { return }"
            )
        )
    }

    func testUserAssetImportsAreLatestWinsAndReferenceAware() throws {
        let preferences = try sourceFile(
            "Docky/Services/DockyPreferences.swift"
        )
        let importSection = try sourceSection(
            in: preferences,
            startingWith: "    func importUserAssetPath(",
            endingWith: "    private func userAssetDiagnosticKind"
        )
        XCTAssertTrue(
            importSection.contains(
                "advanceUserAssetImportGeneration(for: slot)"
            )
        )
        XCTAssertTrue(
            importSection.contains(
                "userAssetImportGenerationBySlot[slot] == generation"
            )
        )
        XCTAssertTrue(
            importSection.contains("commitImportedUserAssetPath(")
        )
        XCTAssertTrue(
            importSection.contains("clearUserAsset(")
        )
        XCTAssertTrue(
            importSection.contains("managedUserAssetReferencedPaths")
        )

        let store = try sourceFile(
            "Docky/Models/ManagedUserAssetStore.swift"
        )
        XCTAssertTrue(
            store.contains("ManagedUserAssetOperationCoordinator")
        )
        XCTAssertTrue(
            store.contains("pruneUnreferencedAssets(")
        )
        XCTAssertTrue(
            store.contains("pendingPaths(forSlot: slot)")
        )
    }

    func testPhotoFrameStartupAndDecodingStayOffMain() throws {
        let source = try sourceFile(
            "Docky/Services/PhotoFrameService.swift"
        )
        let initializer = try sourceSection(
            in: source,
            startingWith: "    init() {",
            endingWith: "    // MARK: - Configuration"
        )
        XCTAssertEqual(
            initializer
                .components(separatedBy: "reload()")
                .count - 1,
            1
        )
        XCTAssertFalse(
            initializer.contains("resolvingBookmarkData:")
        )

        let reload = try sourceSection(
            in: source,
            startingWith: "    func reload() {",
            endingWith: "    private func applyResolvedSnapshot("
        )
        XCTAssertTrue(reload.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(
            reload.contains(
                "PhotoFrameWorker.resolveBookmarks(sourceBookmarks)"
            )
        )
        XCTAssertTrue(source.contains("LocalImageDecoder.decode(at: url)"))
        XCTAssertFalse(source.contains("Data(contentsOf:"))
        XCTAssertFalse(source.contains("NSImage(data:"))
    }

    func testPhotoFrameDecodesAreSerializedCoalescedAndBounded() throws {
        let source = try sourceFile(
            "Docky/Services/PhotoFrameService.swift"
        )
        let worker = try sourceSection(
            in: source,
            startingWith:
                "private actor PhotoFrameImageDecodeWorker {",
            endingWith: "\n}\n\n@MainActor"
        )
        XCTAssertTrue(worker.contains("jobByPath"))
        XCTAssertTrue(worker.contains("consumerIDs"))
        XCTAssertTrue(worker.contains("serialTail"))
        XCTAssertTrue(worker.contains("existing.task.isCancelled"))
        XCTAssertTrue(worker.contains("job.task.cancel()"))

        let loading = try sourceSection(
            in: source,
            startingWith:
                "    private func startImageLoadIfNeeded(at index: Int) {",
            endingWith: "    private func store("
        )
        XCTAssertTrue(
            loading.contains("imageLoadByIndex[index] == nil")
        )
        XCTAssertTrue(
            loading.contains(
                "await self.imageDecodeWorker.decode(at: url)"
            )
        )
        XCTAssertTrue(
            loading.contains("ownedLoad.id == loadID")
        )
        XCTAssertTrue(
            loading.contains("self.reloadGeneration == generation")
        )
        XCTAssertFalse(
            loading.contains("Task.detached(priority: .utility)")
        )

        XCTAssertTrue(
            source.contains("maximumImageCacheBytes")
        )
        XCTAssertTrue(
            source.contains("maximumImageCacheCount")
        )
        XCTAssertFalse(source.contains("currentImageLoadTask"))
        XCTAssertFalse(source.contains("preloadTaskByIndex"))
    }

    func testNowPlayingArtworkNeverDecodesDuringBodyEvaluation() throws {
        let source = try sourceFile(
            "Docky/Views/Tiles/NowPlayingWidgetTileView.swift"
        )
        XCTAssertTrue(source.contains(".task(id: artworkRequest)"))
        XCTAssertTrue(
            source.contains(
                "NowPlayingArtworkWorker.prepare("
            )
        )
        XCTAssertTrue(
            source.contains(
                "LocalImageDecoder.decode(data: data)"
            )
        )
        XCTAssertFalse(source.contains("NSImage(data:"))
        XCTAssertFalse(
            source.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
        XCTAssertFalse(
            source.contains("return effectiveBundleIdentifier")
        )
    }

    func testNowPlayingArtworkRevisionTracksContentNotByteCount()
        throws {
        let source = try sourceFile(
            "Docky/Services/MediaPlaybackService.swift"
        )
        let tracker = try sourceSection(
            in: source,
            startingWith:
                "private struct MediaArtworkRevisionTracker {",
            endingWith: "\n}\n\nprivate final class MediaRemoteBridge"
        )
        XCTAssertTrue(tracker.contains("previous.data == data"))
        XCTAssertTrue(tracker.contains("nextRevision &+= 1"))
        XCTAssertFalse(tracker.contains("data.count"))

        let handling = try sourceSection(
            in: source,
            startingWith:
                "    private func handle(_ snapshot: MediaRemoteSnapshot?) {",
            endingWith: "    func recordFavorite("
        )
        XCTAssertTrue(
            handling.contains("artworkRevisionTracker.revision(")
        )
        XCTAssertFalse(
            handling.contains("\\($0.count)")
        )
    }

    func testNowPlayingFavoriteOwnershipRejectsStaleResults()
        throws {
        let source = try sourceFile(
            "Docky/Services/MediaPlaybackService.swift"
        )
        let lookup = try sourceSection(
            in: source,
            startingWith:
                "    private func scheduleFavoriteLookup(",
            endingWith: "    private func favoriteTrackKey("
        )
        XCTAssertTrue(lookup.contains("let lookupID = UUID()"))
        XCTAssertTrue(
            lookup.contains("favoriteLookupID == lookupID")
        )
        XCTAssertTrue(
            lookup.contains("favoriteLookupID = nil")
        )
        XCTAssertTrue(lookup.contains("let favorite"))
        XCTAssertTrue(
            lookup.contains("favoriteByTrackKey[trackKey] == nil")
        )
        XCTAssertTrue(
            lookup.contains("favoriteTrackKey(for: latestState) == trackKey")
        )
        XCTAssertTrue(
            lookup.contains("favoriteLookupTask = nil")
        )
        XCTAssertTrue(
            lookup.contains("return try? await AppleScriptService")
        )
        XCTAssertFalse(
            lookup.contains("?? false")
        )
        XCTAssertFalse(
            lookup.contains("on error")
        )

        let mutation = try sourceSection(
            in: source,
            startingWith: "    func setFavorite(",
            endingWith: "    func resolvedBundleIdentifier("
        )
        XCTAssertTrue(
            mutation.contains("beginFavoriteMutation(")
        )
        XCTAssertTrue(
            mutation.contains("verifiedFavorite == favorite")
        )
        XCTAssertTrue(
            mutation.contains(
                "mutation: mutation"
            )
        )
        XCTAssertTrue(
            mutation.contains("abandonFavoriteMutation(mutation)")
        )
        XCTAssertFalse(
            mutation.contains("try? AppleScriptService")
        )
        XCTAssertFalse(mutation.contains("end try"))

        let beginMutation = try sourceSection(
            in: source,
            startingWith: "    func beginFavoriteMutation(",
            endingWith: "    func abandonFavoriteMutation("
        )
        XCTAssertTrue(
            beginMutation.contains(
                "favoriteByTrackKey.removeValue("
            )
        )
        XCTAssertTrue(
            beginMutation.contains("priorFavorite: priorFavorite")
        )
    }

    func testNowPlayingApplicationNameResolutionIsAsyncAndCached()
        throws {
        let service = try sourceFile(
            "Docky/Services/MediaPlaybackService.swift"
        )
        let resolution = try sourceSection(
            in: service,
            startingWith:
                "    private func resolveDisplayNameIfNeeded(",
            endingWith: "\n}\n\nprivate struct MediaRemoteSnapshot"
        )
        XCTAssertTrue(
            resolution.contains(
                "resolvedDisplayNameByBundleIdentifier"
            )
        )
        XCTAssertTrue(
            resolution.contains(
                "displayNameResolutionTaskByBundleIdentifier"
            )
        )
        XCTAssertTrue(
            resolution.contains(
                "await ApplicationURLResolver.shared.applicationURL("
            )
        )
        XCTAssertFalse(
            service.contains(
                "NSWorkspace.shared.urlForApplication("
            )
        )
    }

    func testDockPresentationHasOneCanonicalSnapshotForRenderingAndSizing()
        throws {
        let presentation = try sourceFile(
            "Docky/Services/DockPresentationService.swift"
        )
        XCTAssertTrue(
            presentation.contains(
                "@Published private(set) var snapshot"
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "let pinnedBaseTiles: [Tile]"
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "let trailingTiles: [Tile]"
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "var dockPartition:"
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "let separatesHandoffDock: Bool"
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "PresentedTileDockPartition.presenting("
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "separatesHandoff: separatesHandoffDock"
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "_ = preferences.separateHandoffDock"
            )
        )
        let snapshotRebuild = try sourceSection(
            in: presentation,
            startingWith:
                "    private func rebuildSnapshot()",
            endingWith:
                "\n}\n\n@MainActor\nprivate enum DockPresentationComposer"
        )
        XCTAssertTrue(
            snapshotRebuild.contains(
                "separatesHandoffDock:"
            )
        )
        XCTAssertTrue(
            snapshotRebuild.contains(
                "preferences.separateHandoffDock"
            )
        )
        XCTAssertFalse(
            presentation.contains(
                "private(set) var palettePreviewTile"
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "PresentedTileReducer.applyingTransient("
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "insertionBeforeID: \"divider:trailing\""
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "TileStore.applyingThemeLayoutInsertions("
            )
        )
        XCTAssertTrue(
            presentation.contains(
                "internalDrag = InternalDragState()"
            )
        )

        let container = try sourceFile(
            "Docky/Views/Tiles/TileContainerView.swift"
        )
        let displayTiles = try sourceSection(
            in: container,
            startingWith:
                "    private var displayTiles: [Tile] {",
            endingWith: "    private var dockPartition:"
        )
        XCTAssertEqual(
            displayTiles
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "private var displayTiles: [Tile] {\n" +
                "        presentation.snapshot.items\n" +
                "    }"
        )
        XCTAssertFalse(container.contains(
            "@State private var draggedTileID"
        ))
        XCTAssertFalse(container.contains(
            "applyingHandoffPresentation("
        ))
        XCTAssertFalse(container.contains(
            "static func previewedTiles("
        ))
        XCTAssertFalse(container.contains(
            "TileStore.applyingThemeLayoutInsertions("
        ))
        XCTAssertTrue(
            container.contains(
                "presentation.snapshot.pinnedBaseTiles"
            )
        )
        XCTAssertTrue(
            container.contains(
                "presentation.snapshot.trailingTiles"
            )
        )
        XCTAssertTrue(
            container.contains(
                "DockPresentationService.palettePreviewTile("
            )
        )
        XCTAssertTrue(
            container.contains(
                "presentation.snapshot.dockPartition"
            )
        )
        XCTAssertTrue(
            container.contains(
                "private var handoffDockSurface:"
            )
        )
        XCTAssertTrue(
            container.contains(
                "ForEach(handoffDisplayTiles)"
            )
        )
        XCTAssertTrue(
            container.contains(
                "for tile in mainDisplayTiles"
            )
        )

        let tileView = try sourceFile(
            "Docky/Views/Tiles/TileView.swift"
        )
        let content = try sourceSection(
            in: tileView,
            startingWith: "    private var content: some View",
            endingWith: "    private var tooltipTitle:"
        )
        XCTAssertTrue(
            content.contains("AppTileView(")
        )
        XCTAssertFalse(content.contains("DockHandoffBadgeView"))
        XCTAssertFalse(content.contains("handoffBadge"))

        let badgeSource = try sourceFile(
            "Docky/Views/Tiles/DockBadgeView.swift"
        )
        XCTAssertFalse(
            badgeSource.contains("DockHandoffBadgeView")
        )

        let iconCache = try sourceFile(
            "Docky/Services/IconCacheService.swift"
        )
        XCTAssertFalse(iconCache.contains("visibleContentRectCache"))
        XCTAssertFalse(
            iconCache.contains("loadVisibleContentRectAsync")
        )

        let mainWindow = try sourceFile(
            "Docky/Views/MainWindow/MainWindow.swift"
        )
        let frameObservation = try sourceSection(
            in: mainWindow,
            startingWith: "    private func observeFrameInputs()",
            endingWith:
                "    private func observeScreenAndSpaceInputs()"
        )
        XCTAssertTrue(
            frameObservation.contains(
                "presentation.$snapshot"
            )
        )
        XCTAssertFalse(
            frameObservation.contains(
                ".map(\\.items)"
            )
        )
        XCTAssertFalse(frameObservation.contains("tileStore.$tiles"))
        XCTAssertFalse(
            frameObservation.contains(
                "dockBadges.$handoffSuggestion"
            )
        )
        XCTAssertFalse(
            frameObservation.contains(
                "editMode.$paletteDropDestination"
            )
        )
        XCTAssertFalse(
            frameObservation.contains(
                "DockDragService.shared.$destinationIndex"
            )
        )

        let frameCalculation = try sourceSection(
            in: mainWindow,
            startingWith:
                "    private func applyCurrentFrame(animated: Bool, duration:",
            endingWith: "    private func applyFrame("
        )
        XCTAssertTrue(
            frameCalculation.contains(
                "let sizingTiles = presentation.snapshot.items"
            )
        )
        XCTAssertTrue(
            frameCalculation.contains(
                "presentation.snapshot.dockPartition"
            )
        )
        XCTAssertTrue(
            frameCalculation.contains(
                "TileContainerView.dockContentLayout("
            )
        )
        XCTAssertTrue(
            frameCalculation.contains(
                "layout.setChromeSurfaces("
            )
        )
        XCTAssertFalse(
            frameCalculation.contains("tileStore.tiles")
        )
        XCTAssertFalse(
            frameCalculation.contains("previewedTiles(")
        )
        XCTAssertFalse(
            frameCalculation.contains(
                "applyingHandoffPresentation("
            )
        )

        let mainWindowView = try sourceFile(
            "Docky/Views/MainWindow/MainWindowView.swift"
        )
        XCTAssertTrue(
            mainWindowView.contains(
                "chromeSurfaceBackgrounds(chromeSurfaces)"
            )
        )
        XCTAssertTrue(
            mainWindowView.contains(
                "surfaces.interDockGap"
            )
        )
        XCTAssertTrue(
            mainWindowView.contains(
                "surfaces.handoffSize"
            )
        )

        let layoutService = try sourceFile(
            "Docky/Services/DockLayoutService.swift"
        )
        XCTAssertTrue(
            layoutService.contains(
                "@Published private(set) var chromeSurfaces"
            )
        )
        XCTAssertFalse(
            layoutService.contains(
                "@Published private(set) var chromeSize"
            )
        )

        let chromeMetrics = try sourceFile(
            "Docky/Services/DockChromeMetricsService.swift"
        )
        XCTAssertTrue(
            chromeMetrics.contains(
                "var primary: CGFloat"
            )
        )
        XCTAssertTrue(
            chromeMetrics.contains(
                "var handoff: CGFloat"
            )
        )

        let startMenu = try sourceFile(
            "Docky/Views/MainWindow/StartMenuOverlayWindowController.swift"
        )
        XCTAssertTrue(
            startMenu.contains(
                "DockLayoutService.shared.$chromeSurfaces"
            )
        )
        XCTAssertFalse(
            startMenu.contains(
                ".map(\\.primarySize)"
            )
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSection(
        in source: String,
        startingWith startMarker: String,
        endingWith endMarker: String
    ) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
            )
        )
        return source[start.lowerBound..<end.lowerBound]
    }
}
