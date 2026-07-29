//
//  TileStore.swift
//  Docky
//
//  Composes the visible dock tile row from three sources:
//    - `persistent-apps`   → pinned apps + spacers (left section)
//    - running apps that aren't pinned → injected between pinned and folders
//    - `persistent-others` → folders + spacers (right section)
//
//  Refresh signals: dock plist change and workspace running-apps changes.
//

import AppKit
import Combine
import os.log

final class TileStore: ObservableObject {
    static let shared = TileStore()

    private static let logger = Logger(subsystem: "gt.quintero.Docky", category: "TileStore")

    @Published private(set) var tiles: [Tile] = []

    private static let changeNotification = Notification.Name("com.apple.dock.prefchanged")
    private static let hasImportedSystemDockPreferencesKey = "docky.tileStore.hasImportedSystemDockPreferences"
    private static let expandedInlineAppFolderIDsKey = "docky.tileStore.expandedInlineAppFolderIDs"
    private static let demoDebugPinnedAppNames = [
        "Dia",
        "Notes",
        "Calendar",
        "Music",
        "Messages",
        "Slack",
        "Mail",
        "Xcode",
        "Figma",
        "Ghostty",
        "Linear"
    ]

    private var pinnedTiles: [Tile] = []
    private var systemPinnedTiles: [Tile] = []
    private var systemOtherTiles: [Tile] = []
    private var systemOtherTilesByID: [String: Tile] = [:]
    private var trailingTiles: [Tile] = []
    private var dockPinnedTilesByBundleIdentifier: [String: Tile] = [:]
    private var applicationTilesByBundleIdentifier: [String: AppTile] = [:]
    private var missingApplicationBundleIdentifiers: Set<String> = []
    private var applicationMetadataTasks:
        [String: Task<Void, Never>] = [:]
    private var systemDockReloadTask: Task<Void, Never>?
    private var systemDockReloadGeneration: UInt64 = 0
    private var pendingSystemDockPreferenceSync:
        SystemDockPreferenceSyncRequest?
    private var expandedInlineAppFolderIDs: Set<String> = [] {
        didSet {
            guard expandedInlineAppFolderIDs != oldValue else { return }
            defaults.set(Array(expandedInlineAppFolderIDs), forKey: Self.expandedInlineAppFolderIDsKey)
        }
    }
    /// Currently displayed unpinned running apps, in visual order. May contain
    /// one "ghost" entry at the end, an app that recently exited but sat at
    /// the rightmost position, preserved until something newer takes its slot.
    private var displayedRunning: [RunningApp] = []

    private var notificationObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    private let preferences = DockyPreferences.shared
    private let mediaPlayback = MediaPlaybackService.shared
    private let defaults = UserDefaults.standard

    private init() {
        if let storedExpandedIDs = defaults.stringArray(forKey: Self.expandedInlineAppFolderIDsKey) {
            expandedInlineAppFolderIDs = Set(storedExpandedIDs)
        }
        refreshPinnedTilesFromPreferences()
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
        reloadSystemDockState(syncPreferencesFromSystemDock: false)
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.changeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadSystemDockState(syncPreferencesFromSystemDock: false)
        }
        WorkspaceService.shared.$runningApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runningApps in
                self?.adoptRunningApplicationMetadata(runningApps)
                self?.refreshPinnedTilesFromPreferences()
                self?.rebuildTiles()
            }
            .store(in: &cancellables)
        WorkspaceService.shared.$minimizedWindows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildTiles() }
            .store(in: &cancellables)
        // `DockyPreferences` is `@Observable`. We observe each
        // property bundle through `observeChanges` so the same change
        // signal fires only when the relevant property mutates.
        // (`.dropFirst()` skipped the Combine initial emission; the
        // Observation closure runs once on install to register reads
        //, calling `rebuildTiles` etc. then is safe and idempotent.)
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.pinnedItems
            self?.refreshPinnedTilesFromPreferences()
            self?.rebuildTiles()
        }
        .store(in: &cancellables)
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.widgetPlacements
            self?.rebuildTiles()
        }
        .store(in: &cancellables)
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.appWidgetDisplays
            self?.rebuildTiles()
        }
        .store(in: &cancellables)
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.hiddenAppBundleIdentifiers
            self?.refreshPinnedTilesFromPreferences()
            self?.rebuildTiles()
        }
        .store(in: &cancellables)
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.trailingItems
            self?.refreshTrailingTilesFromPreferences()
            self?.rebuildTiles()
        }
        .store(in: &cancellables)
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.showsGroupedOpenedAppsInDock
            _ = DockyPreferences.shared.effectiveShowsActivePinnedSeparator
            _ = DockyPreferences.shared.showsRunningApps
            _ = DockyPreferences.shared.showsMinimizedWindows
            _ = DockyPreferences.shared.enablesShelveMode
            _ = DockyPreferences.shared.shelveHidesFinder
            _ = DockyPreferences.shared.shelveHidesTrash
            _ = DockyPreferences.shared.hidesRecentApps
            self?.rebuildTiles()
        }
        .store(in: &cancellables)
        mediaPlayback.$statesByBundleIdentifier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPinnedTilesFromPreferences()
                self?.refreshTrailingTilesFromPreferences()
                self?.rebuildTiles()
            }
            .store(in: &cancellables)
    }

    deinit {
        systemDockReloadTask?.cancel()
        applicationMetadataTasks.values.forEach { $0.cancel() }
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(notificationObserver)
        }
    }

    func refresh() {
        reloadSystemDockState(syncPreferencesFromSystemDock: false)
    }

    func refreshAfterDockyEditedSystemDock(
        credentials: ProfileMutationCredentials
    ) {
        reloadSystemDockState(
            syncPreferencesFromSystemDock: true,
            preferenceSyncCredentials: credentials
        )
    }

    func syncPreferencesFromSystemDockIfNeeded() {
        guard !hasImportedSystemDockPreferences else {
            return
        }

        let profileService = ProfileService.shared
        let credentials =
            profileService.captureMutationCredentials()
        guard let profile = profileService.activeProfile,
              profile.id == credentials.profileID else {
            return
        }
        guard profile.pinnedItems.isEmpty,
              profile.trailingItems.isEmpty else {
            hasImportedSystemDockPreferences = true
            return
        }

        reloadSystemDockState(
            syncPreferencesFromSystemDock: true,
            preferenceSyncCredentials: credentials,
            marksSystemImportComplete: true
        )
    }

    private func reloadSystemDockState(
        syncPreferencesFromSystemDock: Bool,
        preferenceSyncCredentials:
            ProfileMutationCredentials? = nil,
        marksSystemImportComplete: Bool = false
    ) {
        if syncPreferencesFromSystemDock {
            guard let preferenceSyncCredentials else {
                assertionFailure(
                    "A system-Dock preference sync requires "
                        + "pre-await profile credentials."
                )
                return
            }
            pendingSystemDockPreferenceSync =
                SystemDockPreferenceSyncRequest(
                    credentials:
                        preferenceSyncCredentials,
                    marksSystemImportComplete:
                        marksSystemImportComplete,
                    reason:
                        marksSystemImportComplete
                        ? "initialSystemDockImport"
                        : "systemDockEditorSync"
                )
        }

        systemDockReloadGeneration &+= 1
        let generation = systemDockReloadGeneration
        let preferenceSyncRequest =
            pendingSystemDockPreferenceSync

        systemDockReloadTask?.cancel()
        systemDockReloadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.loadSystemDockSnapshot()
            }.value

            guard !Task.isCancelled, let self,
                  self.systemDockReloadGeneration == generation else {
                return
            }

            self.systemDockReloadTask = nil
            self.pendingSystemDockPreferenceSync = nil
            let didApplyPreferenceSync =
                self.applySystemDockSnapshot(
                    snapshot,
                    preferenceSyncRequest:
                        preferenceSyncRequest
                )
            if preferenceSyncRequest?
                .marksSystemImportComplete == true,
               snapshot != nil,
               didApplyPreferenceSync {
                self.hasImportedSystemDockPreferences = true
            }
        }
    }

    private func applySystemDockSnapshot(
        _ snapshot: SystemDockSnapshot?,
        preferenceSyncRequest:
            SystemDockPreferenceSyncRequest?
    ) -> Bool {
        guard let snapshot else {
            dockPinnedTilesByBundleIdentifier = [:]
            systemPinnedTiles = []
            pinnedTiles = []
            systemOtherTiles = []
            systemOtherTilesByID = [:]
            refreshPinnedTilesFromPreferences()
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
            return preferenceSyncRequest == nil
        }

        let refreshedPinnedTiles = snapshot.pinnedTiles
        systemPinnedTiles = refreshedPinnedTiles
        adoptSystemDockApplicationMetadata(refreshedPinnedTiles)
        dockPinnedTilesByBundleIdentifier = Dictionary(
            refreshedPinnedTiles.compactMap { tile in
                bundleIdentifier(of: tile).map { ($0, tile) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        systemOtherTiles = snapshot.otherTiles
        systemOtherTilesByID = Dictionary(uniqueKeysWithValues: systemOtherTiles.map { ($0.id, $0) })
        let didApplyPreferenceSync =
            preferenceSyncRequest.map {
                applySystemDockPreferenceSync(
                    snapshot,
                    request: $0
                )
            } ?? true
        refreshPinnedTilesFromPreferences()
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
        return didApplyPreferenceSync
    }

    nonisolated private static func loadSystemDockSnapshot()
        -> SystemDockSnapshot? {
        guard let plist = DockPlistReader.read() else {
            return nil
        }

        let apps =
            (plist["persistent-apps"] as? [[String: Any]]) ?? []
        let others =
            (plist["persistent-others"] as? [[String: Any]]) ?? []
        return SystemDockSnapshot(
            pinnedTiles: apps.enumerated().compactMap { index, entry in
                parse(
                    entry: entry,
                    fallbackID: fallbackTileID(
                        for: entry,
                        at: index,
                        section: "persistent-apps"
                    )
                )
            },
            otherTiles: others.enumerated().compactMap { index, entry in
                parse(
                    entry: entry,
                    fallbackID: fallbackTileID(
                        for: entry,
                        at: index,
                        section: "persistent-others"
                    )
                )
            }
        )
    }

    private var hasImportedSystemDockPreferences: Bool {
        get { defaults.bool(forKey: Self.hasImportedSystemDockPreferencesKey) }
        set { defaults.set(newValue, forKey: Self.hasImportedSystemDockPreferencesKey) }
    }

    func isPinnedReorderable(tileID: String) -> Bool {
        pinnedTiles.contains { $0.id == tileID }
    }

    func isTrailingReorderable(tileID: String) -> Bool {
        trailingTiles.contains { $0.id == tileID }
    }

    func isPinned(bundleIdentifier: String) -> Bool {
        preferences.pinnedItems.contains {
            ($0.kind == .app && $0.bundleIdentifier == bundleIdentifier)
                || ($0.kind == .appFolder && $0.folderBundleIdentifiers.contains(bundleIdentifier))
        }
    }

    func isAppInFolder(bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty else {
            return false
        }

        return preferences.pinnedItems.contains {
            $0.kind == .appFolder && $0.folderBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    @discardableResult
    func setPinnedApp(bundleIdentifier: String, pinned: Bool) -> Bool {
        guard !bundleIdentifier.isEmpty, bundleIdentifier != Self.finderBundleID else {
            return false
        }

        var pinnedItems = preferences.pinnedItems

        if pinned {
            guard !pinnedItems.contains(where: { $0.kind == .app && $0.bundleIdentifier == bundleIdentifier }) else {
                return false
            }
            pinnedItems.append(.app(bundleIdentifier: bundleIdentifier))
        } else {
            guard pinnedItems.contains(where: { $0.kind == .app && $0.bundleIdentifier == bundleIdentifier }) else {
                return false
            }
            pinnedItems.removeAll { $0.kind == .app && $0.bundleIdentifier == bundleIdentifier }
        }

        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        return true
    }

    @discardableResult
    func setPinnedTileOrder(
        ids: [String],
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        TileStore.logger.info("setPinnedTileOrder called with ids.count=\(ids.count) pinnedTiles.count=\(self.pinnedTiles.count)")
        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(.profiles, "pinnedTileReorderRequested", fields: [
            "requestedCount": ids.count,
            "currentCount": pinnedTiles.count,
            "requestedOrderTokens": ids.map(diagnostics.token),
            "activeProfileToken": diagnostics.token(ProfileService.shared.activeProfileID),
        ])
        guard ids.count == pinnedTiles.count else {
            TileStore.logger.warning("setPinnedTileOrder early return: count mismatch ids=\(ids.count) pinnedTiles=\(self.pinnedTiles.count)")
            diagnostics.record(.profiles, "pinnedTileReorderRejected", fields: [
                "reason": "tileCountMismatch",
                "requestedCount": ids.count,
                "currentCount": pinnedTiles.count,
            ])
            return false
        }

        let visibleIDs = pinnedTiles.map(\.id)
        guard Set(ids).count == ids.count,
              Set(visibleIDs).count
                == visibleIDs.count,
              Set(ids) == Set(visibleIDs) else {
            TileStore.logger.warning("setPinnedTileOrder rejected unknown or duplicate visible IDs")
            diagnostics.record(.profiles, "pinnedTileReorderRejected", fields: [
                "reason": "unknownTileIDs",
                "resolvedCount": Set(ids).intersection(visibleIDs).count,
                "currentCount": pinnedTiles.count,
            ])
            return false
        }

        // `pinnedTiles` contains only materialized/visible preferences. Hidden
        // apps and temporarily unresolved applications are deliberately absent.
        // Reorder only those visible slots inside the authoritative array;
        // replacing the whole array with `ids` would silently delete every
        // non-materialized preference.
        guard let candidateItems =
                DockDropMutationPolicy
                .reorderingVisibleSubset(
                    authoritative:
                        preferences.pinnedItems,
                    requestedVisibleIDs: ids,
                    id: Self.pinnedTileID(for:)
                )
        else {
            diagnostics.record(.profiles, "pinnedTileReorderRejected", fields: [
                "reason": "authoritativeItemUnavailable",
                "requestedCount": ids.count,
            ])
            return false
        }

        let profileService = ProfileService.shared
        let profileID = expectedProfileID ?? profileService.activeProfileID
        let revision = expectedRevision ?? profileService.stateRevision
        let applied = profileService.applyActiveProfileTransaction(
            expectedProfileID: profileID,
            expectedRevision: revision,
            reason: "pinnedTileReorder"
        ) { profile in
            profile.pinnedItems = candidateItems
        }
        guard applied else {
            refreshPinnedTilesFromPreferences()
            rebuildTiles()
            diagnostics.record(.profiles, "pinnedTileReorderRejected", fields: [
                "reason": "profileTransactionRejected",
                "activeProfileToken": diagnostics.token(profileService.activeProfileID),
                "expectedProfileToken": diagnostics.token(profileID),
                "expectedRevision": revision,
                "revision": profileService.stateRevision,
            ])
            return false
        }

        TileStore.logger.info("setPinnedTileOrder: applying reorder, reorderedItems count=\(ids.count)")
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        diagnostics.record(.profiles, "pinnedTileReorderApplied", fields: [
            "itemCount": ids.count,
            "orderTokens": ids.map(diagnostics.token),
            "activeProfileToken": diagnostics.token(ProfileService.shared.activeProfileID),
        ])
        return true
    }

    @discardableResult
    func replacePinnedAppsWithDefaultDockAppsForLoadTest() -> Int {
        let installedBundleIdentifiers = Self.defaultDockLoadTestBundleIdentifiers.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }

        preferences.pinnedItems = installedBundleIdentifiers.map(PinnedTileItem.app(bundleIdentifier:))
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        return installedBundleIdentifiers.count
    }

    @discardableResult
    func replacePinnedAppsWithEveryInstalledAppForLoadTest() -> Int {
        let installedBundleIdentifiers = Self.installedApplicationBundleIdentifiers()
        preferences.pinnedItems = installedBundleIdentifiers.map(PinnedTileItem.app(bundleIdentifier:))
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        return installedBundleIdentifiers.count
    }

    @discardableResult
    func resetPinnedItemsToSystemDock() -> Int {
        let systemPinnedItems = systemPinnedTiles.compactMap(Self.pinnedItem(from:))
        guard !systemPinnedItems.isEmpty else {
            return 0
        }

        preferences.pinnedItems = systemPinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        return systemPinnedItems.count
    }

    func seedDummyDebugLayout() {
        let diaBundleIdentifier = Self.resolveInstalledAppBundleIdentifier(named: "Dia")
        let slackBundleIdentifier = Self.resolveInstalledAppBundleIdentifier(named: "Slack")
        let appFolderBundleIdentifiers = ["Xcode", "Ghostty", "Symbols"].compactMap {
            Self.resolveInstalledAppBundleIdentifier(named: $0)
        }

        var pinnedItems: [PinnedTileItem] = []
        if let diaBundleIdentifier {
            pinnedItems.append(.app(bundleIdentifier: diaBundleIdentifier))
        }
        if let slackBundleIdentifier {
            pinnedItems.append(.app(bundleIdentifier: slackBundleIdentifier))
        }
        if appFolderBundleIdentifiers.count >= 2 {
            pinnedItems.append(.appFolder(
                displayName: "Folder",
                bundleIdentifiers: appFolderBundleIdentifiers,
                displayMode: .grid,
                contentViewMode: .grid
            ))
        } else {
            pinnedItems.append(contentsOf: appFolderBundleIdentifiers.map(PinnedTileItem.app(bundleIdentifier:)))
        }

        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        preferences.pinnedItems = pinnedItems
        var trailingItems: [TrailingTileItem] = []
        trailingItems.append(.smartStack())
        trailingItems.append(.folder(
            url: downloadsURL,
            displayName: "Downloads",
            displayMode: .folder,
            contentViewMode: .grid
        ))
        preferences.trailingItems = trailingItems
        refreshPinnedTilesFromPreferences()
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
    }

    func loadDemoDebugLayout() {
        let pinnedAppBundleIdentifiers = Self.demoDebugPinnedAppNames.compactMap {
            Self.resolveInstalledAppBundleIdentifier(named: $0)
        }
        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)

        preferences.pinnedItems = pinnedAppBundleIdentifiers.map(PinnedTileItem.app(bundleIdentifier:))

        var trailingItems: [TrailingTileItem] = []
        trailingItems.append(.smartStack())
        trailingItems.append(.folder(
            url: downloadsURL,
            displayName: "Downloads",
            displayMode: .folder,
            contentViewMode: .grid
        ))
        trailingItems.append(.trash())
        preferences.trailingItems = trailingItems

        refreshPinnedTilesFromPreferences()
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
    }

    @discardableResult
    func pinApp(
        bundleIdentifier: String,
        at destinationIndex: Int,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != Self.finderBundleID else {
            return false
        }

        let sourceTileID = Self.pinnedTileID(
            for: .app(bundleIdentifier: bundleIdentifier)
        )
        let visibleIDs = pinnedTiles.map(\.id).filter {
            $0 != sourceTileID
        }
        let expandedFolderIDsContainingSource = preferences.pinnedItems.compactMap {
            item in
            item.kind == .appFolder
                && item.folderBundleIdentifiers.contains(
                    bundleIdentifier
                )
                ? item.id
                : nil
        }

        let originalItems = preferences.pinnedItems
        guard let insertionIndex =
                DockDropMutationPolicy
                .authoritativeInsertionIndexAfterTransformingPrefix(
                    authoritative: originalItems,
                    visibleIDs: visibleIDs,
                    visibleDestinationIndex:
                        destinationIndex,
                    id: Self.pinnedTileID(for:),
                    transformPrefix: {
                        Self.removingApps(
                            [bundleIdentifier],
                            from: $0
                        )
                    }
                )
        else {
            return false
        }
        var candidateItems = Self.removingApps(
            [bundleIdentifier],
            from: originalItems
        )
        candidateItems.insert(
            .app(bundleIdentifier: bundleIdentifier),
            at: min(insertionIndex, candidateItems.count)
        )

        let profileService = ProfileService.shared
        let profileID =
            expectedProfileID
            ?? profileService.activeProfileID
        let revision =
            expectedRevision
            ?? profileService.stateRevision
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: profileID,
                expectedRevision: revision,
                reason: "pinAppDrop"
            ) { profile in
                profile.pinnedItems = candidateItems
                profile.hiddenAppBundleIdentifiers.removeAll {
                    $0 == bundleIdentifier
                }
            }
        guard applied else {
            refreshPinnedTilesFromPreferences()
            rebuildTiles()
            return false
        }

        expandedInlineAppFolderIDs.subtract(
            expandedFolderIDsContainingSource
        )
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        return true
    }

    @discardableResult
    func groupApp(
        bundleIdentifier: String,
        intoTileID targetTileID: String,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        groupApps(
            bundleIdentifiers: [bundleIdentifier],
            intoTileID: targetTileID,
            expectedProfileID: expectedProfileID,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func groupApps(
        bundleIdentifiers: [String],
        intoTileID targetTileID: String,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        let diagnostics = DiagnosticsTrace.shared
        let normalizedBundleIdentifiers = normalizedGroupedAppBundleIdentifiers(bundleIdentifiers)
        guard !normalizedBundleIdentifiers.isEmpty else {
            diagnostics.record(.profiles, "appFolderDropRejected", fields: [
                "reason": "emptySource",
                "targetTileToken": diagnostics.token(targetTileID),
            ])
            return false
        }

        let originalItems = preferences.pinnedItems
        let pinnedTargetIndex = originalItems.firstIndex {
            Self.pinnedTileID(for: $0) == targetTileID
        }
        let pinnedTarget =
            pinnedTargetIndex.map { originalItems[$0] }
        let runningTargetBundleIdentifier: String? = {
            guard pinnedTarget == nil,
                  targetTileID != DockBadgeService.handoffTileID,
                  !targetTileID.hasPrefix("folder-running:"),
                  let targetTile = tiles.first(where: {
                      $0.id == targetTileID
                  }),
                  case .app(let app) = targetTile.content,
                  !app.bundleIdentifier.isEmpty,
                  app.bundleIdentifier != Self.finderBundleID,
                  !isPinned(
                      bundleIdentifier:
                          app.bundleIdentifier
                  ) else {
                return nil
            }
            return app.bundleIdentifier
        }()
        let groupTarget: DockAppGroupTarget? = {
            if let pinnedTarget {
                switch pinnedTarget.kind {
                case .app:
                    guard let bundleIdentifier =
                            pinnedTarget.bundleIdentifier
                    else {
                        return nil
                    }
                    return .pinnedApp(
                        itemID: pinnedTarget.id,
                        bundleIdentifier:
                            bundleIdentifier
                    )
                case .appFolder:
                    return .pinnedFolder(
                        itemID: pinnedTarget.id,
                        bundleIdentifiers:
                            pinnedTarget
                            .folderBundleIdentifiers
                    )
                case .launchpad, .startMenu, .widget,
                     .smartStack, .spacer,
                     .flexibleSpacer, .divider:
                    return nil
                }
            }
            return runningTargetBundleIdentifier.map {
                .runningApp(bundleIdentifier: $0)
            }
        }()
        guard let groupTarget,
              let groupingPlan =
                DockAppGroupLayoutPolicy.plan(
                    sourceBundleIdentifiers:
                        normalizedBundleIdentifiers,
                    target: groupTarget,
                    finderBundleIdentifier:
                        Self.finderBundleID
                )
        else {
            diagnostics.record(.profiles, "appFolderDropRejected", fields: [
                "reason": "targetUnavailableOrNoChange",
                "targetTileToken": diagnostics.token(targetTileID),
            ])
            return false
        }

        var candidateItems: [PinnedTileItem]
        var groupedBundleIdentifiers: [String]
        var createdFolder:
            (
                item: PinnedTileItem,
                name: String,
                apps: [AppTile]
            )?

        if let targetIndex = pinnedTargetIndex,
           let targetItem = pinnedTarget {
            switch targetItem.kind {
            case .app:
                guard targetItem.bundleIdentifier != nil else {
                    return false
                }
                let sourceBundleIdentifiers =
                    groupingPlan
                    .bundleIdentifiersToDetach
                guard !sourceBundleIdentifiers.isEmpty else {
                    return false
                }
                groupedBundleIdentifiers =
                    groupingPlan
                    .folderBundleIdentifiers
                let folderApps =
                    groupedBundleIdentifiers.compactMap {
                        makeAppTile(bundleIdentifier: $0)
                    }
                let seededFolderName =
                    appFolderSeedName(for: folderApps)
                let folder = PinnedTileItem.appFolder(
                    displayName: seededFolderName,
                    bundleIdentifiers:
                        groupedBundleIdentifiers,
                    displayMode: .grid,
                    contentViewMode: .grid
                )

                let prefix = Array(
                    originalItems.prefix(targetIndex)
                )
                let insertionIndex = Self.removingApps(
                    sourceBundleIdentifiers,
                    from: prefix
                ).count
                candidateItems = Self.removingApps(
                    sourceBundleIdentifiers,
                    from: originalItems
                )
                candidateItems.removeAll {
                    Self.pinnedTileID(for: $0)
                        == targetTileID
                }
                candidateItems.insert(
                    folder,
                    at: min(
                        insertionIndex,
                        candidateItems.count
                    )
                )
                createdFolder = (
                    folder,
                    seededFolderName,
                    folderApps
                )
            case .appFolder:
                let sourceBundleIdentifiers =
                    groupingPlan
                    .bundleIdentifiersToDetach
                guard !sourceBundleIdentifiers.isEmpty else {
                    return false
                }
                groupedBundleIdentifiers =
                    groupingPlan
                    .folderBundleIdentifiers
                candidateItems = Self.removingApps(
                    sourceBundleIdentifiers,
                    from: originalItems,
                    preservingItemID: targetItem.id
                )
                guard let folderIndex =
                        candidateItems.firstIndex(where: {
                            Self.pinnedTileID(for: $0)
                                == targetTileID
                        })
                else {
                    return false
                }
                candidateItems[folderIndex] = .appFolder(
                    id: targetItem.id,
                    displayName:
                        targetItem.folderDisplayName
                        ?? "Folder",
                    bundleIdentifiers:
                        groupedBundleIdentifiers,
                    displayMode:
                        targetItem.appFolderDisplayMode
                        ?? .grid,
                    contentViewMode:
                        targetItem.folderContentViewMode
                        ?? .grid
                )
            case .launchpad, .startMenu, .widget,
                 .smartStack, .spacer,
                 .flexibleSpacer, .divider:
                return false
            }
        } else if let targetBundleIdentifier =
                    runningTargetBundleIdentifier {
            let sourceBundleIdentifiers =
                normalizedBundleIdentifiers.filter {
                    $0 != targetBundleIdentifier
                }
            guard !sourceBundleIdentifiers.isEmpty else {
                return false
            }
            groupedBundleIdentifiers =
                groupingPlan
                .folderBundleIdentifiers

            // If at least one source is already pinned, the source's first
            // authoritative slot is the only persistent anchor. With two
            // running apps there is no such slot, so append the new folder to
            // the pinned section, immediately before the running divider.
            let sourceSet = Set(sourceBundleIdentifiers)
            let sourceAnchorIndex =
                originalItems.firstIndex {
                    Self.bundleIdentifiers(
                        in: $0
                    ).contains(where: sourceSet.contains)
                }
            let insertionIndex: Int
            if let sourceAnchorIndex {
                insertionIndex = Self.removingApps(
                    sourceBundleIdentifiers,
                    from: Array(
                        originalItems.prefix(
                            sourceAnchorIndex
                        )
                    )
                ).count
            } else {
                insertionIndex = Int.max
            }

            let folderApps =
                groupedBundleIdentifiers.compactMap {
                    makeAppTile(bundleIdentifier: $0)
                }
            let seededFolderName =
                appFolderSeedName(for: folderApps)
            let folder = PinnedTileItem.appFolder(
                displayName: seededFolderName,
                bundleIdentifiers:
                    groupedBundleIdentifiers,
                displayMode: .grid,
                contentViewMode: .grid
            )
            candidateItems = Self.removingApps(
                groupingPlan
                    .bundleIdentifiersToDetach,
                from: originalItems
            )
            candidateItems.insert(
                folder,
                at: min(
                    insertionIndex,
                    candidateItems.count
                )
            )
            createdFolder = (
                folder,
                seededFolderName,
                folderApps
            )
        } else {
            diagnostics.record(.profiles, "appFolderDropRejected", fields: [
                "reason": "targetUnavailable",
                "targetTileToken": diagnostics.token(targetTileID),
            ])
            return false
        }

        guard Self.hasValidAppMembership(
            candidateItems
        ) else {
            diagnostics.record(.profiles, "appFolderDropRejected", fields: [
                "reason": "invalidCandidate",
                "targetTileToken": diagnostics.token(targetTileID),
            ])
            return false
        }

        let selectedBundleIdentifierSet = Set(
            groupingPlan
                .bundleIdentifiersToDetach
        )
        let affectedFolderIDs: Set<String> = Set(
            originalItems.compactMap { item in
                guard item.kind == .appFolder,
                      item.folderBundleIdentifiers.contains(where: {
                          selectedBundleIdentifierSet.contains($0)
                      })
                else {
                    return nil
                }
                return item.id
            }
        )
        let profileService = ProfileService.shared
        let profileID =
            expectedProfileID
            ?? profileService.activeProfileID
        let revision =
            expectedRevision
            ?? profileService.stateRevision
        // Existing target-folder members retain their visibility state.
        // Only membership actively detached by this gesture is promoted back
        // to a visible pinned surface.
        let detachedSet = Set(
            groupingPlan.bundleIdentifiersToDetach
        )
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: profileID,
                expectedRevision: revision,
                reason: "appFolderDrop"
            ) { profile in
                profile.pinnedItems = candidateItems
                profile.hiddenAppBundleIdentifiers.removeAll {
                    detachedSet.contains($0)
                }
            }
        guard applied else {
            refreshPinnedTilesFromPreferences()
            rebuildTiles()
            diagnostics.record(.profiles, "appFolderDropRejected", fields: [
                "reason": "profileTransactionRejected",
                "targetTileToken": diagnostics.token(targetTileID),
                "expectedProfileToken": diagnostics.token(profileID),
                "expectedRevision": revision,
                "revision": profileService.stateRevision,
            ])
            return false
        }

        expandedInlineAppFolderIDs.subtract(
            affectedFolderIDs
        )
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        diagnostics.record(.profiles, "appFolderDropApplied", fields: [
            "targetTileToken": diagnostics.token(targetTileID),
            "bundleCount": groupedBundleIdentifiers.count,
            "profileToken": diagnostics.token(profileID),
            "revision": profileService.stateRevision,
        ])
        if let createdFolder {
            suggestAppFolderNameIfNeeded(
                folderID: createdFolder.item.id,
                expectedDisplayName: createdFolder.name,
                expectedBundleIdentifiers:
                    groupedBundleIdentifiers,
                expectedProfileID: profileID,
                expectedRevision:
                    profileService.stateRevision,
                apps: createdFolder.apps
            )
        }
        return true
    }

    func ungroupAppFolder(tileID: String) {
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .appFolder else {
            return
        }

        let folderItem = preferences.pinnedItems[itemIndex]
        expandedInlineAppFolderIDs.remove(folderItem.id)
        let replacementItems = folderItem.folderBundleIdentifiers.map(PinnedTileItem.app(bundleIdentifier:))
        var pinnedItems = preferences.pinnedItems
        pinnedItems.remove(at: itemIndex)
        pinnedItems.insert(contentsOf: replacementItems, at: itemIndex)
        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
    }

    func renameAppFolder(tileID: String, displayName: String) {
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .appFolder else {
            return
        }

        let normalizedDisplayName = normalizeAppFolderDisplayName(displayName)
        let existingItem = preferences.pinnedItems[itemIndex]
        guard existingItem.folderDisplayName != normalizedDisplayName else {
            return
        }

        var pinnedItems = preferences.pinnedItems
        pinnedItems[itemIndex] = .appFolder(
            id: existingItem.id,
            displayName: normalizedDisplayName,
            bundleIdentifiers: existingItem.folderBundleIdentifiers,
            displayMode: existingItem.appFolderDisplayMode ?? .grid,
            contentViewMode: existingItem.folderContentViewMode ?? .grid
        )
        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
    }

    func presentRenameAppFolderPrompt(tileID: String) {
        guard let item = pinnedItem(forTileID: tileID),
              item.kind == .appFolder else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        alert.informativeText = "Choose a name for this app folder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = item.folderDisplayName ?? "Folder"
        textField.placeholderString = "Folder"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        renameAppFolder(tileID: tileID, displayName: textField.stringValue)
    }

    func removeAppFromFolder(tileID: String, bundleIdentifier: String) {
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .appFolder else {
            return
        }

        let existingItem = preferences.pinnedItems[itemIndex]
        let remainingBundleIdentifiers = existingItem.folderBundleIdentifiers.filter { $0 != bundleIdentifier }
        guard remainingBundleIdentifiers.count != existingItem.folderBundleIdentifiers.count else {
            return
        }

        var pinnedItems = preferences.pinnedItems
        switch remainingBundleIdentifiers.count {
        case 0:
            expandedInlineAppFolderIDs.remove(existingItem.id)
            pinnedItems.remove(at: itemIndex)
        case 1:
            expandedInlineAppFolderIDs.remove(existingItem.id)
            pinnedItems[itemIndex] = .app(bundleIdentifier: remainingBundleIdentifiers[0])
        default:
            pinnedItems[itemIndex] = .appFolder(
                id: existingItem.id,
                displayName: existingItem.folderDisplayName ?? "Folder",
                bundleIdentifiers: remainingBundleIdentifiers,
                displayMode: existingItem.appFolderDisplayMode ?? .grid,
                contentViewMode: existingItem.folderContentViewMode ?? .grid
            )
        }

        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
    }

    /// Moves `movingBundleIdentifier` to the slot currently occupied by
    /// `targetBundleIdentifier` inside the app folder identified by
    /// `tileID`. No-op when either id isn't in the folder, when both ids
    /// are the same, or when the relative order is already correct.
    func reorderAppsInFolder(
        tileID: String,
        movingBundleIdentifier: String,
        toIndexOfTargetBundleIdentifier targetBundleIdentifier: String
    ) {
        guard movingBundleIdentifier != targetBundleIdentifier else { return }
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .appFolder else {
            return
        }

        let existingItem = preferences.pinnedItems[itemIndex]
        let ids = existingItem.folderBundleIdentifiers
        guard ids.contains(movingBundleIdentifier),
              let targetIndex = ids.firstIndex(of: targetBundleIdentifier) else {
            return
        }
        reorderAppsInFolder(
            tileID: tileID,
            movingBundleIdentifier: movingBundleIdentifier,
            toIndex: targetIndex
        )
    }

    /// Moves `movingBundleIdentifier` to absolute position `targetIndex`
    /// in the folder's current ordering. `targetIndex` is interpreted in
    /// the post-removal coordinate space, matching the convention used
    /// by the launchpad reorder gesture.
    func reorderAppsInFolder(
        tileID: String,
        movingBundleIdentifier: String,
        toIndex targetIndex: Int
    ) {
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .appFolder else {
            return
        }

        let existingItem = preferences.pinnedItems[itemIndex]
        var ids = existingItem.folderBundleIdentifiers
        guard let currentIndex = ids.firstIndex(of: movingBundleIdentifier) else { return }

        ids.remove(at: currentIndex)
        let clampedTarget = max(0, min(targetIndex, ids.count))
        ids.insert(movingBundleIdentifier, at: clampedTarget)
        guard ids != existingItem.folderBundleIdentifiers else { return }

        var pinnedItems = preferences.pinnedItems
        pinnedItems[itemIndex] = .appFolder(
            id: existingItem.id,
            displayName: existingItem.folderDisplayName ?? "Folder",
            bundleIdentifiers: ids,
            displayMode: existingItem.appFolderDisplayMode ?? .grid,
            contentViewMode: existingItem.folderContentViewMode ?? .grid
        )
        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
    }

    func setAppFolderContentViewMode(tileID: String, mode: FolderTileContentViewMode) {
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .appFolder else {
            return
        }

        let existingItem = preferences.pinnedItems[itemIndex]
        guard (existingItem.folderContentViewMode ?? .grid) != mode else {
            return
        }

        var pinnedItems = preferences.pinnedItems
        if mode != .inline {
            expandedInlineAppFolderIDs.remove(existingItem.id)
        }
        pinnedItems[itemIndex] = PinnedTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            bundleIdentifier: existingItem.bundleIdentifier,
            folderDisplayName: existingItem.folderDisplayName,
            folderBundleIdentifiers: existingItem.folderBundleIdentifiers,
            appFolderDisplayMode: existingItem.appFolderDisplayMode,
            folderContentViewMode: mode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: existingItem.widgetSpan,
            hiddenWidgetOwnerBundleIdentifiers: existingItem.hiddenWidgetOwnerBundleIdentifiers
        )
        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
    }

    func appFolderContentViewMode(tileID: String) -> FolderTileContentViewMode {
        guard let item = preferences.pinnedItems.first(where: { Self.pinnedTileID(for: $0) == tileID }),
              item.kind == .appFolder else {
            return .grid
        }

        return item.folderContentViewMode ?? .grid
    }

    func setAppFolderDisplayMode(tileID: String, mode: AppFolderTileDisplayMode) {
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .appFolder else {
            return
        }

        let existingItem = preferences.pinnedItems[itemIndex]
        guard (existingItem.appFolderDisplayMode ?? .grid) != mode else {
            return
        }

        var pinnedItems = preferences.pinnedItems
        pinnedItems[itemIndex] = PinnedTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            bundleIdentifier: existingItem.bundleIdentifier,
            folderDisplayName: existingItem.folderDisplayName,
            folderBundleIdentifiers: existingItem.folderBundleIdentifiers,
            appFolderDisplayMode: mode,
            folderContentViewMode: existingItem.folderContentViewMode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: existingItem.widgetSpan,
            hiddenWidgetOwnerBundleIdentifiers: existingItem.hiddenWidgetOwnerBundleIdentifiers
        )
        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
    }

    func appFolderDisplayMode(tileID: String) -> AppFolderTileDisplayMode {
        guard let item = preferences.pinnedItems.first(where: { Self.pinnedTileID(for: $0) == tileID }),
              item.kind == .appFolder else {
            return .grid
        }

        return item.appFolderDisplayMode ?? .grid
    }

    func toggleInlineAppFolderExpansion(folderID: String) {
        if expandedInlineAppFolderIDs.contains(folderID) {
            expandedInlineAppFolderIDs.remove(folderID)
        } else {
            expandedInlineAppFolderIDs.insert(folderID)
        }

        rebuildTiles()
    }

    func isInlineAppFolderExpanded(folderID: String) -> Bool {
        expandedInlineAppFolderIDs.contains(folderID)
    }

    func widgetPlacement(
        kind: WidgetKind,
        ownerBundleIdentifier: String
    ) -> WidgetPlacement? {
        preferences.widgetPlacements.first {
            $0.kind == kind && $0.ownerBundleIdentifier == ownerBundleIdentifier
        }
    }

    func hasWidget(kind: WidgetKind, ownerBundleIdentifier: String) -> Bool {
        widgetPlacement(kind: kind, ownerBundleIdentifier: ownerBundleIdentifier) != nil
    }

    func setWidget(
        kind: WidgetKind,
        ownerBundleIdentifier: String,
        span: TileSpan
    ) {
        var placements = preferences.widgetPlacements.filter {
            !($0.kind == kind && $0.ownerBundleIdentifier == ownerBundleIdentifier)
        }
        placements.append(WidgetPlacement(
            kind: kind,
            ownerBundleIdentifier: ownerBundleIdentifier,
            span: span
        ))
        preferences.widgetPlacements = placements
    }

    func removeWidget(kind: WidgetKind, ownerBundleIdentifier: String) {
        preferences.widgetPlacements.removeAll {
            $0.kind == kind && $0.ownerBundleIdentifier == ownerBundleIdentifier
        }
    }

    func appWidgetCandidates(bundleIdentifier: String) -> [WidgetTile] {
        guard !bundleIdentifier.isEmpty,
              !isAppInFolder(bundleIdentifier: bundleIdentifier) else {
            return []
        }

        var candidates = WidgetCatalog.staticRegistrations
            .filter { $0.ownerBundleIdentifier == bundleIdentifier }
            .map { $0.makeTile() }

        if mediaPlayback.state(for: bundleIdentifier) != nil || appWidgetDisplay(bundleIdentifier: bundleIdentifier)?.kind == .nowPlaying {
            candidates.append(Self.makeWidgetTile(
                kind: .nowPlaying,
                ownerBundleIdentifier: bundleIdentifier,
                span: defaultAppWidgetSpan(kind: .nowPlaying, ownerBundleIdentifier: bundleIdentifier)
            ))
        }

        return candidates
    }

    func appWidgetDisplay(bundleIdentifier: String) -> AppWidgetDisplay? {
        preferences.appWidgetDisplays.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func setAppWidgetDisplay(bundleIdentifier: String, kind: WidgetKind) {
        guard !bundleIdentifier.isEmpty,
              !isAppInFolder(bundleIdentifier: bundleIdentifier) else {
            return
        }

        let existingSpan = appWidgetDisplay(bundleIdentifier: bundleIdentifier)
            .flatMap { $0.kind == kind ? $0.span : nil }
        let span = existingSpan ?? defaultAppWidgetSpan(kind: kind, ownerBundleIdentifier: bundleIdentifier)

        var displays = preferences.appWidgetDisplays.filter { $0.bundleIdentifier != bundleIdentifier }
        displays.append(AppWidgetDisplay(
            bundleIdentifier: bundleIdentifier,
            kind: kind,
            span: span
        ))
        preferences.appWidgetDisplays = displays.sorted {
            $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending
        }
    }

    func removeAppWidgetDisplay(bundleIdentifier: String) {
        preferences.appWidgetDisplays.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    func setAppWidgetDisplaySpan(bundleIdentifier: String, span: TileSpan) {
        guard let existingDisplay = appWidgetDisplay(bundleIdentifier: bundleIdentifier),
              !isAppInFolder(bundleIdentifier: bundleIdentifier),
              existingDisplay.span != span else {
            return
        }

        let resolvedSpan = existingDisplay.kind.supportedSpans.contains(span)
            ? span
            : existingDisplay.kind.supportedSpans.last ?? .one
        guard existingDisplay.span != resolvedSpan else {
            return
        }

        var displays = preferences.appWidgetDisplays
        guard let displayIndex = displays.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }

        displays[displayIndex] = AppWidgetDisplay(
            bundleIdentifier: existingDisplay.bundleIdentifier,
            kind: existingDisplay.kind,
            span: resolvedSpan
        )
        preferences.appWidgetDisplays = displays
    }

    @discardableResult
    func insertPinnedItem(
        kind: PinnedTileItemKind,
        at destinationIndex: Int,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        let item: PinnedTileItem
        switch kind {
        case .app, .appFolder, .widget:
            return false
        case .launchpad:
            item = .launchpad()
        case .startMenu:
            item = .startMenu()
        case .smartStack:
            item = .smartStack()
        case .spacer:
            item = .spacer()
        case .flexibleSpacer:
            item = .flexibleSpacer()
        case .divider:
            item = .divider()
        }

        return insertPinnedItem(
            item,
            at: destinationIndex,
            expectedProfileID: expectedProfileID,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func insertPinnedItem(
        _ item: PinnedTileItem,
        at destinationIndex: Int,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        let visibleTargetIDs = pinnedTiles.map(\.id)
        let profileService = ProfileService.shared
        let profileID =
            expectedProfileID
            ?? profileService.activeProfileID
        let revision =
            expectedRevision
            ?? profileService.stateRevision
        var didPrepareMutation = false
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: profileID,
                expectedRevision: revision,
                reason: "insertPinnedItem"
            ) { profile in
                let destinationID =
                    Self.pinnedTileID(for: item)
                guard !profile.pinnedItems.contains(where: {
                    Self.pinnedTileID(for: $0)
                        == destinationID
                }),
                      let authoritativeIndex =
                        DockDropMutationPolicy
                        .authoritativeInsertionIndex(
                            authoritative:
                                profile.pinnedItems,
                            visibleIDs:
                                visibleTargetIDs,
                            visibleDestinationIndex:
                                destinationIndex,
                            id:
                                Self.pinnedTileID(for:)
                        )
                else {
                    return
                }
                profile.pinnedItems.insert(
                    item,
                    at: authoritativeIndex
                )
                didPrepareMutation = true
            }
        guard applied, didPrepareMutation else {
            refreshPinnedTilesFromPreferences()
            rebuildTiles()
            return false
        }

        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        return true
    }

    func smartOrganizePinnedItems() {
        // Smart-organize is FoundationModels-backed (macOS 26+). On
        // older systems, or when the feature is force-disabled via
        // `FeatureGate` for testing, the action is a no-op; callers
        // should hide or disable the entry point via the same gate.
        guard FeatureGate.shared.isAvailable(.foundationModelsSmartOrganize),
              #available(macOS 26.0, *) else { return }
        let profileService = ProfileService.shared
        let expectedProfileID =
            profileService.activeProfileID
        let expectedRevision =
            profileService.stateRevision
        let existingItems = preferences.pinnedItems
        Task { @MainActor [weak self] in
            guard let self else { return }
            let organizedItems = await PinnedDockSmartOrganizerService.shared.organize(items: existingItems)
            guard organizedItems != existingItems else {
                return
            }

            var didPrepareMutation = false
            let applied =
                profileService
                .applyActiveProfileTransaction(
                    expectedProfileID:
                        expectedProfileID,
                    expectedRevision:
                        expectedRevision,
                    reason:
                        "smartOrganizePinnedItems"
                ) { profile in
                    guard profile.pinnedItems
                            == existingItems else {
                        return
                    }
                    profile.pinnedItems =
                        organizedItems
                    didPrepareMutation = true
                }
            guard applied, didPrepareMutation else {
                self.refreshPinnedTilesFromPreferences()
                self.rebuildTiles()
                return
            }

            self.refreshPinnedTilesFromPreferences()
            self.rebuildTiles()
        }
    }

    @discardableResult
    func setTrailingTileOrder(
        ids: [String],
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        guard ids.count == trailingTiles.count else {
            return false
        }

        let visibleIDs = trailingTiles.map(\.id)
        guard Set(ids).count == ids.count,
              Set(visibleIDs).count == visibleIDs.count,
              Set(ids) == Set(visibleIDs) else {
            return false
        }

        var authoritativeItems = preferences.trailingItems
        if !authoritativeItems.contains(where: {
            $0.kind == .trash
        }) {
            authoritativeItems.append(.trash())
        }
        guard let reorderedItems =
                DockDropMutationPolicy
                .reorderingVisibleSubset(
                    authoritative:
                        authoritativeItems,
                    requestedVisibleIDs: ids,
                    id: Self.trailingTileID(for:)
                )
        else {
            return false
        }

        let profileService = ProfileService.shared
        let profileID =
            expectedProfileID
            ?? profileService.activeProfileID
        let revision =
            expectedRevision
            ?? profileService.stateRevision
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: profileID,
                expectedRevision: revision,
                reason: "trailingTileReorder"
            ) { profile in
                profile.trailingItems = reorderedItems
            }
        guard applied else {
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
            return false
        }

        refreshTrailingTilesFromPreferences()
        rebuildTiles()
        return true
    }

    /// Moves a persisted tile between sections as one compare-and-swap
    /// profile transaction. This prevents a rejected destination insert from
    /// leaving the source deleted.
    @discardableResult
    func movePinnedItemToTrailing(
        tileID: String,
        convertedItem: TrailingTileItem,
        at visibleDestinationIndex: Int,
        expectedProfileID: String,
        expectedRevision: UInt64
    ) -> Bool {
        let visibleTargetIDs = trailingTiles.map(\.id)
        let profileService = ProfileService.shared
        var didPrepareMutation = false
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: expectedProfileID,
                expectedRevision: expectedRevision,
                reason: "movePinnedItemToTrailing"
            ) { profile in
                guard let sourceIndex =
                        profile.pinnedItems.firstIndex(where: {
                            Self.pinnedTileID(for: $0)
                                == tileID
                        })
                else {
                    return
                }

                var trailingItems = profile.trailingItems
                if !trailingItems.contains(where: {
                    $0.kind == .trash
                }) {
                    trailingItems.append(.trash())
                }
                let destinationID =
                    Self.trailingTileID(
                        for: convertedItem
                    )
                guard !trailingItems.contains(where: {
                    Self.trailingTileID(for: $0)
                        == destinationID
                }),
                      let destinationIndex =
                        DockDropMutationPolicy
                        .authoritativeInsertionIndex(
                            authoritative:
                                trailingItems,
                            visibleIDs:
                                visibleTargetIDs,
                            visibleDestinationIndex:
                                visibleDestinationIndex,
                            id: {
                                Self.trailingTileID(
                                    for: $0
                                )
                            }
                        )
                else {
                    return
                }

                profile.pinnedItems.remove(
                    at: sourceIndex
                )
                trailingItems.insert(
                    convertedItem,
                    at: destinationIndex
                )
                profile.trailingItems = trailingItems
                didPrepareMutation = true
            }
        guard applied, didPrepareMutation else {
            refreshPinnedTilesFromPreferences()
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
            return false
        }

        refreshPinnedTilesFromPreferences()
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
        return true
    }

    /// Reverse of `movePinnedItemToTrailing`, with the same atomicity and
    /// stale-drag guard.
    @discardableResult
    func moveTrailingItemToPinned(
        tileID: String,
        convertedItem: PinnedTileItem,
        at visibleDestinationIndex: Int,
        expectedProfileID: String,
        expectedRevision: UInt64
    ) -> Bool {
        let visibleTargetIDs = pinnedTiles.map(\.id)
        let profileService = ProfileService.shared
        var didPrepareMutation = false
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: expectedProfileID,
                expectedRevision: expectedRevision,
                reason: "moveTrailingItemToPinned"
            ) { profile in
                guard let sourceIndex =
                        profile.trailingItems.firstIndex(where: {
                            Self.trailingTileID(for: $0)
                                == tileID
                        })
                else {
                    return
                }

                let destinationID =
                    Self.pinnedTileID(
                        for: convertedItem
                    )
                guard !profile.pinnedItems.contains(where: {
                    Self.pinnedTileID(for: $0)
                        == destinationID
                }),
                      let destinationIndex =
                        DockDropMutationPolicy
                        .authoritativeInsertionIndex(
                            authoritative:
                                profile.pinnedItems,
                            visibleIDs:
                                visibleTargetIDs,
                            visibleDestinationIndex:
                                visibleDestinationIndex,
                            id:
                                Self.pinnedTileID(for:)
                        )
                else {
                    return
                }

                profile.trailingItems.remove(
                    at: sourceIndex
                )
                profile.pinnedItems.insert(
                    convertedItem,
                    at: destinationIndex
                )
                didPrepareMutation = true
            }
        guard applied, didPrepareMutation else {
            refreshPinnedTilesFromPreferences()
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
            return false
        }

        refreshPinnedTilesFromPreferences()
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
        return true
    }

    @discardableResult
    func insertTrailingItem(
        _ item: TrailingTileItem,
        at destinationIndex: Int,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        let visibleTargetIDs = trailingTiles.map(\.id)
        let profileService = ProfileService.shared
        let profileID =
            expectedProfileID
            ?? profileService.activeProfileID
        let revision =
            expectedRevision
            ?? profileService.stateRevision
        var didPrepareMutation = false
        logTrailingItems("Before insertTrailingItem")
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: profileID,
                expectedRevision: revision,
                reason: "insertTrailingItem"
            ) { profile in
                var authoritativeItems =
                    profile.trailingItems
                if !authoritativeItems.contains(where: {
                    $0.kind == .trash
                }) {
                    authoritativeItems.append(.trash())
                }
                let destinationID =
                    Self.trailingTileID(for: item)
                guard !authoritativeItems.contains(where: {
                    Self.trailingTileID(for: $0)
                        == destinationID
                }),
                      let authoritativeIndex =
                        DockDropMutationPolicy
                        .authoritativeInsertionIndex(
                            authoritative:
                                authoritativeItems,
                            visibleIDs:
                                visibleTargetIDs,
                            visibleDestinationIndex:
                                destinationIndex,
                            id: {
                                Self.trailingTileID(
                                    for: $0
                                )
                            }
                        )
                else {
                    return
                }
                authoritativeItems.insert(
                    item,
                    at: authoritativeIndex
                )
                profile.trailingItems =
                    authoritativeItems
                didPrepareMutation = true
            }
        guard applied, didPrepareMutation else {
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
            return false
        }

        logTrailingItems("After insertTrailingItem")
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
        return true
    }

    func makePinnedItem(from tile: Tile) -> PinnedTileItem? {
        switch itemScope(forTileID: tile.id) {
        case .pinned(let item):
            return item
        case .trailing(let item):
            switch item.kind {
            case .widget:
                guard let widgetKind = item.widgetKind,
                      let ownerBundleIdentifier = item.widgetOwnerBundleIdentifier else {
                    return nil
                }
                return PinnedTileItem(
                    id: item.id,
                    kind: .widget,
                    bundleIdentifier: nil,
                    folderDisplayName: nil,
                    folderBundleIdentifiers: [],
                    appFolderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: widgetKind,
                    widgetOwnerBundleIdentifier: ownerBundleIdentifier,
                    widgetSpan: item.widgetSpan,
                    hiddenWidgetOwnerBundleIdentifiers:
                        item.hiddenWidgetOwnerBundleIdentifiers,
                    widgetSettings: item.widgetSettings
                )
            case .smartStack:
                return PinnedTileItem(
                    id: item.id,
                    kind: .smartStack,
                    bundleIdentifier: nil,
                    folderDisplayName: nil,
                    folderBundleIdentifiers: [],
                    appFolderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: item.hiddenWidgetOwnerBundleIdentifiers
                )
            case .spacer:
                return PinnedTileItem(
                    id: item.id,
                    kind: .spacer,
                    bundleIdentifier: nil,
                    folderDisplayName: nil,
                    folderBundleIdentifiers: [],
                    appFolderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: []
                )
            case .flexibleSpacer:
                return PinnedTileItem(
                    id: item.id,
                    kind: .flexibleSpacer,
                    bundleIdentifier: nil,
                    folderDisplayName: nil,
                    folderBundleIdentifiers: [],
                    appFolderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: []
                )
            case .divider:
                return PinnedTileItem(
                    id: item.id,
                    kind: .divider,
                    bundleIdentifier: nil,
                    folderDisplayName: nil,
                    folderBundleIdentifiers: [],
                    appFolderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: []
                )
            case .folder, .trash:
                return nil
            }
        case .none:
            return nil
        }
    }

    func makeTrailingItem(from tile: Tile) -> TrailingTileItem? {
        switch itemScope(forTileID: tile.id) {
        case .trailing(let item):
            return item
        case .pinned(let item):
            switch item.kind {
            case .launchpad, .startMenu:
                return nil
            case .widget:
                guard let widgetKind = item.widgetKind,
                      let ownerBundleIdentifier = item.widgetOwnerBundleIdentifier else {
                    return nil
                }
                return TrailingTileItem(
                    id: item.id,
                    kind: .widget,
                    sourceTileID: nil,
                    folderURL: nil,
                    folderDisplayName: nil,
                    folderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: widgetKind,
                    widgetOwnerBundleIdentifier: ownerBundleIdentifier,
                    widgetSpan: item.widgetSpan,
                    hiddenWidgetOwnerBundleIdentifiers:
                        item.hiddenWidgetOwnerBundleIdentifiers,
                    widgetSettings: item.widgetSettings
                )
            case .smartStack:
                return TrailingTileItem(
                    id: item.id,
                    kind: .smartStack,
                    sourceTileID: nil,
                    folderURL: nil,
                    folderDisplayName: nil,
                    folderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: item.hiddenWidgetOwnerBundleIdentifiers
                )
            case .spacer:
                return TrailingTileItem(
                    id: item.id,
                    kind: .spacer,
                    sourceTileID: nil,
                    folderURL: nil,
                    folderDisplayName: nil,
                    folderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: []
                )
            case .flexibleSpacer:
                return TrailingTileItem(
                    id: item.id,
                    kind: .flexibleSpacer,
                    sourceTileID: nil,
                    folderURL: nil,
                    folderDisplayName: nil,
                    folderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: []
                )
            case .divider:
                return TrailingTileItem(
                    id: item.id,
                    kind: .divider,
                    sourceTileID: nil,
                    folderURL: nil,
                    folderDisplayName: nil,
                    folderDisplayMode: nil,
                    folderContentViewMode: nil,
                    widgetKind: nil,
                    widgetOwnerBundleIdentifier: nil,
                    widgetSpan: nil,
                    hiddenWidgetOwnerBundleIdentifiers: []
                )
            case .app, .appFolder:
                return nil
            }
        case .none:
            return nil
        }
    }

    func smartStackWidgetCandidates(tileID: String) -> [WidgetTile] {
        switch itemScope(forTileID: tileID) {
        case .pinned(let item):
            guard item.kind == .smartStack else {
                return []
            }
            let hiddenOwnerBundleIdentifierSet = Set(item.hiddenWidgetOwnerBundleIdentifiers)
            let visibleWidgets = allSmartStackWidgets().filter {
                !hiddenOwnerBundleIdentifierSet.contains($0.ownerBundleIdentifier)
            }
            let hiddenWidgets = allSmartStackWidgets().filter {
                hiddenOwnerBundleIdentifierSet.contains($0.ownerBundleIdentifier)
            }
            return visibleWidgets + hiddenWidgets
        case .trailing(let item):
            guard item.kind == .smartStack else {
                return []
            }
            let hiddenOwnerBundleIdentifierSet = Set(item.hiddenWidgetOwnerBundleIdentifiers)
            let visibleWidgets = allSmartStackWidgets().filter {
                !hiddenOwnerBundleIdentifierSet.contains($0.ownerBundleIdentifier)
            }
            let hiddenWidgets = allSmartStackWidgets().filter {
                hiddenOwnerBundleIdentifierSet.contains($0.ownerBundleIdentifier)
            }
            return visibleWidgets + hiddenWidgets
        case .none:
            return []
        }
    }

    func isSmartStackWidgetVisible(tileID: String, ownerBundleIdentifier: String) -> Bool {
        switch itemScope(forTileID: tileID) {
        case .pinned(let item):
            guard item.kind == .smartStack else {
                return false
            }
            return !item.hiddenWidgetOwnerBundleIdentifiers.contains(ownerBundleIdentifier)
        case .trailing(let item):
            guard item.kind == .smartStack else {
                return false
            }
            return !item.hiddenWidgetOwnerBundleIdentifiers.contains(ownerBundleIdentifier)
        case .none:
            return false
        }
    }

    func setSmartStackWidgetVisibility(tileID: String, ownerBundleIdentifier: String, isVisible: Bool) {
        if let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
           preferences.pinnedItems[itemIndex].kind == .smartStack {
            var pinnedItems = preferences.pinnedItems
            let existingItem = pinnedItems[itemIndex]
            var hiddenOwnerBundleIdentifiers = Set(existingItem.hiddenWidgetOwnerBundleIdentifiers)
            if isVisible {
                hiddenOwnerBundleIdentifiers.remove(ownerBundleIdentifier)
            } else {
                hiddenOwnerBundleIdentifiers.insert(ownerBundleIdentifier)
            }

            pinnedItems[itemIndex] = PinnedTileItem(
                id: existingItem.id,
                kind: existingItem.kind,
                bundleIdentifier: existingItem.bundleIdentifier,
                folderDisplayName: existingItem.folderDisplayName,
                folderBundleIdentifiers: existingItem.folderBundleIdentifiers,
                appFolderDisplayMode: existingItem.appFolderDisplayMode,
                folderContentViewMode: existingItem.folderContentViewMode,
                widgetKind: existingItem.widgetKind,
                widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
                widgetSpan: existingItem.widgetSpan,
                hiddenWidgetOwnerBundleIdentifiers: hiddenOwnerBundleIdentifiers.sorted()
            )
            preferences.pinnedItems = pinnedItems
            refreshPinnedTilesFromPreferences()
            rebuildTiles()
            return
        }

        guard let itemIndex = preferences.trailingItems.firstIndex(where: { Self.trailingTileID(for: $0) == tileID }),
              preferences.trailingItems[itemIndex].kind == .smartStack else {
            return
        }

        var trailingItems = preferences.trailingItems
        let existingItem = trailingItems[itemIndex]
        var hiddenOwnerBundleIdentifiers = Set(existingItem.hiddenWidgetOwnerBundleIdentifiers)
        if isVisible {
            hiddenOwnerBundleIdentifiers.remove(ownerBundleIdentifier)
        } else {
            hiddenOwnerBundleIdentifiers.insert(ownerBundleIdentifier)
        }

        trailingItems[itemIndex] = TrailingTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            sourceTileID: existingItem.sourceTileID,
            folderURL: existingItem.folderURL,
            folderDisplayName: existingItem.folderDisplayName,
            folderDisplayMode: existingItem.folderDisplayMode,
            folderContentViewMode: existingItem.folderContentViewMode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: existingItem.widgetSpan,
            hiddenWidgetOwnerBundleIdentifiers: hiddenOwnerBundleIdentifiers.sorted()
        )
        preferences.trailingItems = trailingItems
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
    }

    func setPinnedWidgetSpan(tileID: String, span: TileSpan) {
        guard let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
              preferences.pinnedItems[itemIndex].kind == .widget else {
            return
        }

        let existingItem = preferences.pinnedItems[itemIndex]
        guard existingItem.widgetSpan != span else {
            return
        }

        var pinnedItems = preferences.pinnedItems
        pinnedItems[itemIndex] = PinnedTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            bundleIdentifier: existingItem.bundleIdentifier,
            folderDisplayName: existingItem.folderDisplayName,
            folderBundleIdentifiers: existingItem.folderBundleIdentifiers,
            appFolderDisplayMode: existingItem.appFolderDisplayMode,
            folderContentViewMode: existingItem.folderContentViewMode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: span,
            hiddenWidgetOwnerBundleIdentifiers: existingItem.hiddenWidgetOwnerBundleIdentifiers,
            widgetSettings: existingItem.widgetSettings
        )
        preferences.pinnedItems = pinnedItems
        refreshPinnedTilesFromPreferences()
        rebuildTiles()
    }

    func setTrailingWidgetSpan(tileID: String, span: TileSpan) {
        guard let itemIndex = preferences.trailingItems.firstIndex(where: { Self.trailingTileID(for: $0) == tileID }),
              preferences.trailingItems[itemIndex].kind == .widget else {
            return
        }

        let existingItem = preferences.trailingItems[itemIndex]
        guard existingItem.widgetSpan != span else {
            return
        }

        var trailingItems = preferences.trailingItems
        trailingItems[itemIndex] = TrailingTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            sourceTileID: existingItem.sourceTileID,
            folderURL: existingItem.folderURL,
            folderDisplayName: existingItem.folderDisplayName,
            folderDisplayMode: existingItem.folderDisplayMode,
            folderContentViewMode: existingItem.folderContentViewMode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: span,
            hiddenWidgetOwnerBundleIdentifiers: existingItem.hiddenWidgetOwnerBundleIdentifiers,
            widgetSettings: existingItem.widgetSettings
        )
        preferences.trailingItems = trailingItems
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
    }

    func widgetSettings(tileID: String) -> WidgetSettings? {
        if let item = preferences.pinnedItems.first(where: { Self.pinnedTileID(for: $0) == tileID }),
           item.kind == .widget {
            return item.widgetSettings
        }
        if let item = preferences.trailingItems.first(where: { Self.trailingTileID(for: $0) == tileID }),
           item.kind == .widget {
            return item.widgetSettings
        }
        return nil
    }

    /// Empty normalizes to nil; re-materializes tiles so edits apply live.
    func setWidgetSettings(tileID: String, settings: WidgetSettings) {
        let normalized: WidgetSettings? = settings.isEmpty ? nil : settings

        if let itemIndex = preferences.pinnedItems.firstIndex(where: { Self.pinnedTileID(for: $0) == tileID }),
           preferences.pinnedItems[itemIndex].kind == .widget {
            guard preferences.pinnedItems[itemIndex].widgetSettings != normalized else { return }
            var pinnedItems = preferences.pinnedItems
            pinnedItems[itemIndex].widgetSettings = normalized
            preferences.pinnedItems = pinnedItems
            refreshPinnedTilesFromPreferences()
            rebuildTiles()
            return
        }

        if let itemIndex = preferences.trailingItems.firstIndex(where: { Self.trailingTileID(for: $0) == tileID }),
           preferences.trailingItems[itemIndex].kind == .widget {
            guard preferences.trailingItems[itemIndex].widgetSettings != normalized else { return }
            var trailingItems = preferences.trailingItems
            trailingItems[itemIndex].widgetSettings = normalized
            preferences.trailingItems = trailingItems
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
            return
        }
    }

    func setWidgetSetting(tileID: String, key: String, value: WidgetSettingValue?) {
        var current = widgetSettings(tileID: tileID) ?? [:]
        if let value {
            current[key] = value
        } else {
            current.removeValue(forKey: key)
        }
        setWidgetSettings(tileID: tileID, settings: current)
    }

    func setFolderDisplayMode(tileID: String, folderURL: URL, mode: FolderTileDisplayMode) {
        let normalizedFolderURL = folderURL.standardizedFileURL

        if let itemIndex = preferences.trailingItems.firstIndex(where: {
            matchesFolderItem($0, tileID: tileID, normalizedFolderURL: normalizedFolderURL)
        }) {
            updateFolderDisplayMode(at: itemIndex, mode: mode)
            return
        }

        if let systemFolder = systemFolderEntry(normalizedFolderURL: normalizedFolderURL) {
            var trailingItems = preferences.trailingItems
            trailingItems.insert(
                .folder(
                    sourceTileID: systemFolder.tileID,
                    displayMode: mode,
                    contentViewMode: systemFolder.folder.contentViewMode
                ),
                at: trailingItems.firstIndex(where: { $0.kind == .trash }) ?? trailingItems.count
            )
            preferences.trailingItems = trailingItems
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
        }
    }

    func folderDisplayMode(tileID: String, folderURL: URL) -> FolderTileDisplayMode {
        let normalizedFolderURL = folderURL.standardizedFileURL
        if let item = preferences.trailingItems.first(where: {
            matchesFolderItem($0, tileID: tileID, normalizedFolderURL: normalizedFolderURL)
        }) {
            return resolvedFolderDisplayMode(for: item)
        }

        return systemFolderEntry(normalizedFolderURL: normalizedFolderURL)?.folder.displayMode ?? .contents
    }

    func setFolderContentViewMode(tileID: String, folderURL: URL, mode: FolderTileContentViewMode) {
        let normalizedFolderURL = folderURL.standardizedFileURL

        if let itemIndex = preferences.trailingItems.firstIndex(where: {
            matchesFolderItem($0, tileID: tileID, normalizedFolderURL: normalizedFolderURL)
        }) {
            updateFolderContentViewMode(at: itemIndex, mode: mode)
            return
        }

        if let systemFolder = systemFolderEntry(normalizedFolderURL: normalizedFolderURL) {
            var trailingItems = preferences.trailingItems
            trailingItems.insert(
                .folder(
                    sourceTileID: systemFolder.tileID,
                    displayMode: systemFolder.folder.displayMode,
                    contentViewMode: mode
                ),
                at: trailingItems.firstIndex(where: { $0.kind == .trash }) ?? trailingItems.count
            )
            preferences.trailingItems = trailingItems
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
        }
    }

    func folderContentViewMode(tileID: String, folderURL: URL) -> FolderTileContentViewMode {
        let normalizedFolderURL = folderURL.standardizedFileURL
        if let item = preferences.trailingItems.first(where: {
            matchesFolderItem($0, tileID: tileID, normalizedFolderURL: normalizedFolderURL)
        }) {
            return resolvedFolderContentViewMode(for: item)
        }

        return systemFolderEntry(normalizedFolderURL: normalizedFolderURL)?.folder.contentViewMode ?? .grid
    }

    func setFolderSortMode(tileID: String, folderURL: URL, mode: FolderTileSortMode) {
        let normalizedFolderURL = folderURL.standardizedFileURL

        if let itemIndex = preferences.trailingItems.firstIndex(where: {
            matchesFolderItem($0, tileID: tileID, normalizedFolderURL: normalizedFolderURL)
        }) {
            updateFolderSortMode(at: itemIndex, mode: mode)
            return
        }

        if let systemFolder = systemFolderEntry(normalizedFolderURL: normalizedFolderURL) {
            var trailingItems = preferences.trailingItems
            trailingItems.insert(
                .folder(
                    sourceTileID: systemFolder.tileID,
                    displayMode: systemFolder.folder.displayMode,
                    contentViewMode: systemFolder.folder.contentViewMode,
                    sortMode: mode
                ),
                at: trailingItems.firstIndex(where: { $0.kind == .trash }) ?? trailingItems.count
            )
            preferences.trailingItems = trailingItems
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
        }
    }

    func folderSortMode(tileID: String, folderURL: URL) -> FolderTileSortMode {
        let normalizedFolderURL = folderURL.standardizedFileURL
        if let item = preferences.trailingItems.first(where: {
            matchesFolderItem($0, tileID: tileID, normalizedFolderURL: normalizedFolderURL)
        }) {
            return resolvedFolderSortMode(for: item)
        }

        return systemFolderEntry(normalizedFolderURL: normalizedFolderURL)?.folder.sortMode ?? .dateAdded
    }

    private func updateFolderDisplayMode(at itemIndex: Int, mode: FolderTileDisplayMode) {
        let existingItem = preferences.trailingItems[itemIndex]
        guard resolvedFolderDisplayMode(for: existingItem) != mode else {
            return
        }

        var trailingItems = preferences.trailingItems
        trailingItems[itemIndex] = TrailingTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            sourceTileID: existingItem.sourceTileID,
            folderURL: existingItem.folderURL,
            folderDisplayName: existingItem.folderDisplayName,
            folderDisplayMode: mode,
            folderContentViewMode: existingItem.folderContentViewMode,
            folderSortMode: existingItem.folderSortMode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: existingItem.widgetSpan,
            hiddenWidgetOwnerBundleIdentifiers: existingItem.hiddenWidgetOwnerBundleIdentifiers
        )
        preferences.trailingItems = trailingItems
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
    }

    private func updateFolderContentViewMode(at itemIndex: Int, mode: FolderTileContentViewMode) {
        let existingItem = preferences.trailingItems[itemIndex]
        guard resolvedFolderContentViewMode(for: existingItem) != mode else {
            return
        }

        var trailingItems = preferences.trailingItems
        trailingItems[itemIndex] = TrailingTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            sourceTileID: existingItem.sourceTileID,
            folderURL: existingItem.folderURL,
            folderDisplayName: existingItem.folderDisplayName,
            folderDisplayMode: existingItem.folderDisplayMode,
            folderContentViewMode: mode,
            folderSortMode: existingItem.folderSortMode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: existingItem.widgetSpan,
            hiddenWidgetOwnerBundleIdentifiers: existingItem.hiddenWidgetOwnerBundleIdentifiers
        )
        preferences.trailingItems = trailingItems
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
    }

    private func updateFolderSortMode(at itemIndex: Int, mode: FolderTileSortMode) {
        let existingItem = preferences.trailingItems[itemIndex]
        guard resolvedFolderSortMode(for: existingItem) != mode else {
            return
        }

        var trailingItems = preferences.trailingItems
        trailingItems[itemIndex] = TrailingTileItem(
            id: existingItem.id,
            kind: existingItem.kind,
            sourceTileID: existingItem.sourceTileID,
            folderURL: existingItem.folderURL,
            folderDisplayName: existingItem.folderDisplayName,
            folderDisplayMode: existingItem.folderDisplayMode,
            folderContentViewMode: existingItem.folderContentViewMode,
            folderSortMode: mode,
            widgetKind: existingItem.widgetKind,
            widgetOwnerBundleIdentifier: existingItem.widgetOwnerBundleIdentifier,
            widgetSpan: existingItem.widgetSpan,
            hiddenWidgetOwnerBundleIdentifiers: existingItem.hiddenWidgetOwnerBundleIdentifiers
        )
        preferences.trailingItems = trailingItems
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
    }

    private func resolvedFolderDisplayMode(for item: TrailingTileItem) -> FolderTileDisplayMode {
        if let mode = item.folderDisplayMode {
            return mode
        }

        return systemFolder(for: item)?.displayMode ?? .contents
    }

    private func resolvedFolderContentViewMode(for item: TrailingTileItem) -> FolderTileContentViewMode {
        if let mode = item.folderContentViewMode {
            return mode
        }

        return systemFolder(for: item)?.contentViewMode ?? .grid
    }

    private func resolvedFolderSortMode(for item: TrailingTileItem) -> FolderTileSortMode {
        if let mode = item.folderSortMode {
            return mode
        }

        return systemFolder(for: item)?.sortMode ?? .dateAdded
    }

    private func systemFolder(for item: TrailingTileItem) -> FolderTile? {
        guard let sourceTileID = item.sourceTileID,
              let tile = systemOtherTilesByID[sourceTileID],
              case .folder(let folder) = tile.content else {
            return nil
        }

        return folder
    }

    private func systemFolderEntry(normalizedFolderURL: URL) -> (tileID: String, folder: FolderTile)? {
        for tile in systemOtherTiles {
            guard case .folder(let folder) = tile.content,
                  folder.url.standardizedFileURL == normalizedFolderURL else {
                continue
            }

            return (tile.id, folder)
        }

        return nil
    }

    private func matchesFolderItem(_ item: TrailingTileItem, tileID: String, normalizedFolderURL: URL) -> Bool {
        guard item.kind == .folder else {
            return false
        }
        if Self.trailingTileID(for: item) == tileID {
            return true
        }
        if let itemFolderURL = item.folderURL?.standardizedFileURL {
            return itemFolderURL == normalizedFolderURL
        }
        guard let sourceTileID = item.sourceTileID,
              let tile = systemOtherTilesByID[sourceTileID],
              case .folder(let folder) = tile.content else {
            return false
        }
        return folder.url.standardizedFileURL == normalizedFolderURL
    }

    @discardableResult
    func removePinnedItem(
        tileID: String,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        let profileService = ProfileService.shared
        let profileID =
            expectedProfileID
            ?? profileService.activeProfileID
        let revision =
            expectedRevision
            ?? profileService.stateRevision
        var didPrepareMutation = false
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: profileID,
                expectedRevision: revision,
                reason: "removePinnedItem"
            ) { profile in
                let originalCount =
                    profile.pinnedItems.count
                profile.pinnedItems.removeAll {
                    Self.pinnedTileID(for: $0)
                        == tileID
                }
                didPrepareMutation =
                    profile.pinnedItems.count
                    != originalCount
            }
        guard applied, didPrepareMutation else {
            refreshPinnedTilesFromPreferences()
            rebuildTiles()
            return false
        }

        refreshPinnedTilesFromPreferences()
        rebuildTiles()
        return true
    }

    @discardableResult
    func removeTrailingItem(
        tileID: String,
        expectedProfileID: String? = nil,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        let profileService = ProfileService.shared
        let profileID =
            expectedProfileID
            ?? profileService.activeProfileID
        let revision =
            expectedRevision
            ?? profileService.stateRevision
        var didPrepareMutation = false
        logTrailingItems("Before removeTrailingItem")
        let applied =
            profileService.applyActiveProfileTransaction(
                expectedProfileID: profileID,
                expectedRevision: revision,
                reason: "removeTrailingItem"
            ) { profile in
                let originalCount =
                    profile.trailingItems.count
                profile.trailingItems.removeAll {
                    Self.trailingTileID(for: $0)
                        == tileID
                }
                didPrepareMutation =
                    profile.trailingItems.count
                    != originalCount
            }
        guard applied, didPrepareMutation else {
            refreshTrailingTilesFromPreferences()
            rebuildTiles()
            return false
        }

        logTrailingItems("After removeTrailingItem")
        refreshTrailingTilesFromPreferences()
        rebuildTiles()
        return true
    }

    private static let finderBundleID = "com.apple.finder"
    private static let appSearchDirectories = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]
    private static let defaultDockLoadTestBundleIdentifiers = [
        "com.apple.launchpad.launcher",
        "com.apple.Safari",
        "com.apple.MobileSMS",
        "com.apple.mail",
        "com.apple.iCal",
        "com.apple.AddressBook",
        "com.apple.reminders",
        "com.apple.Notes",
        "com.apple.freeform",
        "com.apple.FaceTime",
        "com.apple.Photos",
        "com.apple.Maps",
        "com.apple.TV",
        "com.apple.Music",
        "com.apple.podcasts",
        "com.apple.AppStore",
        "com.apple.systempreferences"
    ]

    private static func installedApplications() -> [(bundleIdentifier: String, displayName: String)] {
        var bundleIdentifiersByURL: [URL: String] = [:]

        for directoryURL in appSearchDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let appURL as URL in enumerator {
                guard appURL.pathExtension == "app",
                      let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier,
                      !bundleIdentifier.isEmpty,
                      bundleIdentifier != finderBundleID,
                      bundleIdentifier != Bundle.main.bundleIdentifier else {
                    continue
                }

                bundleIdentifiersByURL[appURL] = bundleIdentifier
            }
        }

        return Array(Set(bundleIdentifiersByURL.values)).map { bundleIdentifier in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            let displayName = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleIdentifier
            return (bundleIdentifier: bundleIdentifier, displayName: displayName)
        }
        .sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if comparison == .orderedSame {
                return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(rhs.bundleIdentifier) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
    }

    private static func installedApplicationBundleIdentifiers() -> [String] {
        installedApplications().map(\.bundleIdentifier)
    }

    private static func resolveInstalledAppBundleIdentifier(named name: String) -> String? {
        let normalizedName = normalizedApplicationName(name)
        let applications = installedApplications()

        if let exactMatch = applications.first(where: {
            normalizedApplicationName($0.displayName) == normalizedName
        }) {
            return exactMatch.bundleIdentifier
        }

        let partialMatches = applications.filter {
            normalizedApplicationName($0.displayName).contains(normalizedName)
        }
        guard partialMatches.count == 1 else {
            return nil
        }
        return partialMatches[0].bundleIdentifier
    }

    private static func normalizedApplicationName(_ name: String) -> String {
        name
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func bundleIdentifier(of tile: Tile) -> String? {
        if case .app(let app) = tile.content {
            return app.bundleIdentifier
        }
        return nil
    }

    private func applySystemDockPreferenceSync(
        _ snapshot: SystemDockSnapshot,
        request: SystemDockPreferenceSyncRequest
    ) -> Bool {
        let importedPinnedItems =
            snapshot.pinnedTiles.compactMap(Self.pinnedItem(from:))
        let importedTrailingItems =
            snapshot.otherTiles.compactMap(Self.trailingItem(from:))
                + [.trash()]
        let availableFolderIDs =
            Set(snapshot.otherTiles.map(\.id))
        let profileService = ProfileService.shared
        let applied =
            profileService.applyActiveProfileTransaction(
                credentials:
                    request.credentials,
                reason:
                    request.reason
            ) { profile in
                Self.synchronizeSystemDockPreferences(
                    profile: &profile,
                    importedPinnedItems:
                        importedPinnedItems,
                    importedTrailingItems:
                        importedTrailingItems,
                    availableFolderIDs:
                        availableFolderIDs
                )
            }

        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(
            .profiles,
            applied
                ? "systemDockProfileSyncApplied"
                : "systemDockProfileSyncRejected",
            fields: [
                "reason": request.reason,
                "expectedProfileToken":
                    diagnostics.token(
                        request.credentials.profileID
                    ),
                "activeProfileToken":
                    diagnostics.token(
                        profileService.activeProfileID
                    ),
                "expectedRevision":
                    request.credentials.revision,
                "revision":
                    profileService.stateRevision,
                "marksSystemImportComplete":
                    request.marksSystemImportComplete,
            ]
        )
        return applied
    }

    private static func synchronizeSystemDockPreferences(
        profile: inout DockProfile,
        importedPinnedItems: [PinnedTileItem],
        importedTrailingItems: [TrailingTileItem],
        availableFolderIDs: Set<String>
    ) {
        if profile.pinnedItems.isEmpty,
           !importedPinnedItems.isEmpty {
            profile.pinnedItems = importedPinnedItems
        }

        if !profile.pinnedItems.isEmpty {
            let importedAdditions =
                importedPinnedItems
                .filter {
                    $0.kind != .app
                        || $0.bundleIdentifier
                            != Self.finderBundleID
                }
                .filter { importedItem in
                    !profile.pinnedItems.contains {
                        existingItem in
                        Self.matchesImportedPinnedItem(
                            existingItem,
                            importedItem
                        )
                    }
                }
            if !importedAdditions.isEmpty {
                profile.pinnedItems.append(
                    contentsOf: importedAdditions
                )
            }
        }

        guard !importedTrailingItems.isEmpty else {
            profile.trailingItems = []
            return
        }

        guard !profile.trailingItems.isEmpty else {
            profile.trailingItems = importedTrailingItems
            return
        }

        var mergedItems =
            profile.trailingItems.filter { item in
                switch item.kind {
                case .folder:
                    if let sourceTileID =
                        item.sourceTileID {
                        return availableFolderIDs.contains(
                            sourceTileID
                        )
                    }
                    return item.folderURL != nil
                case .trash, .widget, .smartStack,
                     .spacer, .flexibleSpacer,
                     .divider:
                    return true
                }
            }

        if !mergedItems.contains(where: {
            $0.kind == .trash
        }) {
            mergedItems.append(.trash())
        }

        let existingSystemSourceIDs =
            Set(mergedItems.compactMap(\.sourceTileID))
        let trailingAdditions =
            importedTrailingItems.filter { item in
                guard let sourceTileID =
                    item.sourceTileID else {
                    return item.kind == .trash
                        && !mergedItems.contains(
                            where: {
                                $0.kind == .trash
                            }
                        )
                }
                return !existingSystemSourceIDs.contains(
                    sourceTileID
                )
            }
        if !trailingAdditions.isEmpty {
            mergedItems.append(
                contentsOf: trailingAdditions
            )
        }

        if mergedItems != profile.trailingItems {
            profile.trailingItems = mergedItems
        }
    }

    private func adoptSystemDockApplicationMetadata(_ tiles: [Tile]) {
        for tile in tiles {
            guard case .app(let app) = tile.content,
                  !app.bundleIdentifier.isEmpty,
                  !app.displayName.isEmpty,
                  app.displayName != "Unknown" else {
                continue
            }
            applicationTilesByBundleIdentifier[app.bundleIdentifier] =
                AppTile(
                    bundleIdentifier: app.bundleIdentifier,
                    displayName: app.displayName
                )
            missingApplicationBundleIdentifiers.remove(
                app.bundleIdentifier
            )
        }
    }

    private func adoptRunningApplicationMetadata(_ apps: [RunningApp]) {
        for app in apps {
            guard !app.bundleIdentifier.isEmpty,
                  !app.localizedName.isEmpty else {
                continue
            }
            applicationTilesByBundleIdentifier[app.bundleIdentifier] =
                AppTile(
                    bundleIdentifier: app.bundleIdentifier,
                    displayName: app.localizedName
                )
            missingApplicationBundleIdentifiers.remove(
                app.bundleIdentifier
            )
        }
    }

    private func refreshPinnedTilesFromPreferences() {
        pinnedTiles = preferences.pinnedItems.compactMap(tile(for:))
    }

    private func scheduleApplicationMetadataResolution(
        for bundleIdentifier: String
    ) {
        guard !bundleIdentifier.isEmpty,
              applicationTilesByBundleIdentifier[bundleIdentifier] == nil,
              !missingApplicationBundleIdentifiers.contains(
                bundleIdentifier
              ),
              applicationMetadataTasks[bundleIdentifier] == nil else {
            return
        }

        let task = Task { [weak self] in
            let metadata = await Self.resolveApplicationMetadata(
                for: bundleIdentifier
            )
            guard !Task.isCancelled, let self else {
                return
            }

            self.applicationMetadataTasks.removeValue(
                forKey: bundleIdentifier
            )
            if let metadata {
                self.applicationTilesByBundleIdentifier[bundleIdentifier] =
                    AppTile(
                        bundleIdentifier: bundleIdentifier,
                        displayName: metadata.displayName
                    )
                self.missingApplicationBundleIdentifiers.remove(
                    bundleIdentifier
                )
            } else if self.applicationTilesByBundleIdentifier[
                bundleIdentifier
            ] == nil {
                self.missingApplicationBundleIdentifiers.insert(
                    bundleIdentifier
                )
            } else {
                return
            }

            self.refreshPinnedTilesFromPreferences()
            self.rebuildTiles()
        }
        applicationMetadataTasks[bundleIdentifier] = task
    }

    nonisolated private static func resolveApplicationMetadata(
        for bundleIdentifier: String
    ) async -> ResolvedApplicationMetadata? {
        guard let url =
                await ApplicationURLResolver.shared.applicationURL(
                    for: bundleIdentifier
                ),
              !Task.isCancelled else {
            return nil
        }

        let displayName = await Task.detached(priority: .utility) {
            FileManager.default.displayName(atPath: url.path)
        }.value
        guard !Task.isCancelled, !displayName.isEmpty else {
            return nil
        }
        return ResolvedApplicationMetadata(
            displayName: displayName
        )
    }

    private func logTrailingItems(_ message: String) {
        let summary =
            preferences.trailingItems.map(
                Self.trailingItemDebugDescription(_:)
            )
        NSLog("[Docky] \(message): \(summary)")
    }

    private nonisolated static func trailingItemDebugDescription(
        _ item: TrailingTileItem
    ) -> String {
        switch item.kind {
        case .folder:
            if let sourceTileID = item.sourceTileID {
                return "folder(system:\(sourceTileID))"
            }
            if let folderURL = item.folderURL {
                return "folder(custom:\(folderURL.path))"
            }
            return "folder(unknown)"
        case .trash:
            return "trash"
        case .widget:
            return "widget(\(item.widgetOwnerBundleIdentifier ?? "unknown"))"
        case .smartStack:
            return "smartStack"
        case .spacer:
            return "spacer"
        case .flexibleSpacer:
            return "flexibleSpacer"
        case .divider:
            return "divider"
        }
    }

    private func refreshTrailingTilesFromPreferences() {
        var visibleItems = preferences.trailingItems
        if !visibleItems.contains(where: { $0.kind == .trash }) {
            visibleItems.append(.trash())
        }

        trailingTiles = visibleItems.compactMap(trailingTile(for:))
    }

    private func suggestAppFolderNameIfNeeded(
        folderID: String,
        expectedDisplayName: String,
        expectedBundleIdentifiers: [String],
        expectedProfileID: String,
        expectedRevision: UInt64,
        apps: [AppTile]
    ) {
        guard apps.count >= 2 else {
            return
        }

        // The LLM-powered suggester is macOS 26+, or force-disabled
        // via `FeatureGate` for testing. On earlier systems the
        // deterministic seed name set at folder-creation time is what
        // the user keeps until they rename manually.
        guard FeatureGate.shared.isAvailable(.foundationModelsFolderNaming),
              #available(macOS 26.0, *) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let suggestedName = await AppFolderNamingService.shared.suggestInitialName(for: apps) else {
                return
            }

            let normalizedSuggestedName =
                self.normalizeAppFolderDisplayName(
                    suggestedName
                )
            var didPrepareRename = false
            let applied =
                ProfileService.shared
                .applyActiveProfileTransaction(
                    expectedProfileID:
                        expectedProfileID,
                    expectedRevision:
                        expectedRevision,
                    reason:
                        "suggestAppFolderName"
                ) { profile in
                    guard let itemIndex =
                            profile.pinnedItems
                            .firstIndex(where: {
                                $0.id == folderID
                            })
                    else {
                        return
                    }

                    let existingItem =
                        profile.pinnedItems[
                            itemIndex
                        ]
                    guard existingItem.kind
                            == .appFolder,
                          (
                            existingItem
                                .folderDisplayName
                                ?? "Folder"
                          )
                            == expectedDisplayName,
                          existingItem
                            .folderBundleIdentifiers
                            == expectedBundleIdentifiers,
                          existingItem
                            .folderDisplayName
                            != normalizedSuggestedName
                    else {
                        return
                    }

                    profile.pinnedItems[
                        itemIndex
                    ] = .appFolder(
                        id: existingItem.id,
                        displayName:
                            normalizedSuggestedName,
                        bundleIdentifiers:
                            existingItem
                            .folderBundleIdentifiers,
                        displayMode:
                            existingItem
                            .appFolderDisplayMode
                            ?? .grid,
                        contentViewMode:
                            existingItem
                            .folderContentViewMode
                            ?? .grid
                    )
                    didPrepareRename = true
                }
            guard applied, didPrepareRename else {
                return
            }

            self.refreshPinnedTilesFromPreferences()
            self.rebuildTiles()
        }
    }

    private func pinnedItem(forTileID tileID: String) -> PinnedTileItem? {
        preferences.pinnedItems.first { Self.pinnedTileID(for: $0) == tileID }
    }

    private func normalizedGroupedAppBundleIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []

        return bundleIdentifiers.filter { bundleIdentifier in
            guard !bundleIdentifier.isEmpty,
                  bundleIdentifier != Self.finderBundleID else {
                return false
            }

            return seen.insert(bundleIdentifier).inserted
        }
    }

    private static func bundleIdentifiers(
        in item: PinnedTileItem
    ) -> [String] {
        switch item.kind {
        case .app:
            return item.bundleIdentifier.map { [$0] } ?? []
        case .appFolder:
            return item.folderBundleIdentifiers
        case .launchpad, .startMenu, .widget, .smartStack,
             .spacer, .flexibleSpacer, .divider:
            return []
        }
    }

    /// Removes app membership from an authoritative pinned layout without
    /// publishing intermediate preference states. Folders are normalized in
    /// the candidate: empty folders disappear and one-member folders become
    /// a standalone app.
    private static func removingApps(
        _ bundleIdentifiers: [String],
        from items: [PinnedTileItem],
        preservingItemID: String? = nil
    ) -> [PinnedTileItem] {
        let removedBundleIdentifiers = Set(bundleIdentifiers)

        return items.compactMap { item in
            if item.id == preservingItemID {
                return item
            }

            switch item.kind {
            case .app:
                guard let bundleIdentifier = item.bundleIdentifier else {
                    return item
                }
                return removedBundleIdentifiers.contains(bundleIdentifier) ? nil : item
            case .appFolder:
                let remainingBundleIdentifiers = item.folderBundleIdentifiers.filter {
                    !removedBundleIdentifiers.contains($0)
                }
                guard remainingBundleIdentifiers.count != item.folderBundleIdentifiers.count else {
                    return item
                }

                switch remainingBundleIdentifiers.count {
                case 0:
                    return nil
                case 1:
                    return .app(bundleIdentifier: remainingBundleIdentifiers[0])
                default:
                    return .appFolder(
                        id: item.id,
                        displayName: item.folderDisplayName ?? "Folder",
                        bundleIdentifiers: remainingBundleIdentifiers,
                        displayMode: item.appFolderDisplayMode ?? .grid,
                        contentViewMode: item.folderContentViewMode ?? .grid
                    )
                }
            case .launchpad, .startMenu, .widget, .smartStack, .spacer, .flexibleSpacer, .divider:
                return item
            }
        }
    }

    private static func hasValidAppMembership(
        _ items: [PinnedTileItem]
    ) -> Bool {
        var itemIDs: Set<String> = []
        var bundleIdentifiers: Set<String> = []

        for item in items {
            guard itemIDs.insert(item.id).inserted else {
                return false
            }
            switch item.kind {
            case .app:
                guard let bundleIdentifier = item.bundleIdentifier,
                      !bundleIdentifier.isEmpty,
                      bundleIdentifier != finderBundleID,
                      bundleIdentifiers.insert(
                          bundleIdentifier
                      ).inserted else {
                    return false
                }
            case .appFolder:
                let members =
                    item.folderBundleIdentifiers.filter {
                        !$0.isEmpty && $0 != finderBundleID
                    }
                guard members.count >= 2,
                      Set(members).count == members.count else {
                    return false
                }
                for bundleIdentifier in members {
                    guard bundleIdentifiers.insert(
                        bundleIdentifier
                    ).inserted else {
                        return false
                    }
                }
            case .launchpad, .startMenu, .widget,
                 .smartStack, .spacer,
                 .flexibleSpacer, .divider:
                continue
            }
        }
        return true
    }

    private func trailingItem(forTileID tileID: String) -> TrailingTileItem? {
        preferences.trailingItems.first { Self.trailingTileID(for: $0) == tileID }
    }

    private enum ItemScope {
        case pinned(PinnedTileItem)
        case trailing(TrailingTileItem)
    }

    private func itemScope(forTileID tileID: String) -> ItemScope? {
        if let item = pinnedItem(forTileID: tileID) {
            return .pinned(item)
        }
        if let item = trailingItem(forTileID: tileID) {
            return .trailing(item)
        }
        return nil
    }

    private func tile(for item: PinnedTileItem) -> Tile? {
        switch item.kind {
        case .app:
            guard let bundleIdentifier = item.bundleIdentifier else {
                return nil
            }
            guard !preferences.isAppHiddenInDocky(bundleIdentifier: bundleIdentifier) else {
                return nil
            }
            if let tile = dockPinnedTilesByBundleIdentifier[bundleIdentifier] {
                return Self.makePinnedTile(from: tile, item: item)
            }
            return makePinnedTile(
                bundleIdentifier: bundleIdentifier,
                item: item
            )
        case .appFolder:
            let apps = item.folderBundleIdentifiers
                .filter { !preferences.isAppHiddenInDocky(bundleIdentifier: $0) }
                .compactMap { makeAppTile(bundleIdentifier: $0) }
            guard !apps.isEmpty else {
                return nil
            }
            if apps.count == 1, let app = apps.first {
                return Tile(id: Self.pinnedTileID(for: item), content: .app(app))
            }
            return Tile(
                id: Self.pinnedTileID(for: item),
                content: .appFolder(AppFolderTile(
                    identifier: item.id,
                    displayName: item.folderDisplayName ?? "Folder",
                    apps: apps,
                    displayMode: item.appFolderDisplayMode ?? .grid,
                    contentViewMode: item.folderContentViewMode ?? .grid
                ))
            )
        case .launchpad:
            return Tile(
                id: Self.pinnedTileID(for: item),
                content: .launchpad(LaunchpadTile(identifier: item.id))
            )
        case .startMenu:
            return Tile(
                id: Self.pinnedTileID(for: item),
                content: .startMenu(StartMenuTile(identifier: item.id))
            )
        case .widget:
            guard let widgetKind = item.widgetKind,
                  let ownerBundleIdentifier = item.widgetOwnerBundleIdentifier else {
                return nil
            }
            return Tile(
                id: Self.pinnedTileID(for: item),
                content: .widget(Self.makeWidgetTile(
                    kind: widgetKind,
                    ownerBundleIdentifier: ownerBundleIdentifier,
                    span: item.widgetSpan ?? .three,
                    settings: item.widgetSettings ?? [:]
                ))
            )
        case .smartStack:
            return Tile(
                id: Self.pinnedTileID(for: item),
                content: .smartStack(Self.makeSmartStackTile(
                    identifier: item.id,
                    widgets: visibleSmartStackWidgets(hiddenOwnerBundleIdentifiers: item.hiddenWidgetOwnerBundleIdentifiers)
                ))
            )
        case .spacer:
            return Tile(id: Self.pinnedTileID(for: item), content: .spacer)
        case .flexibleSpacer:
            return Tile(id: Self.pinnedTileID(for: item), content: .flexibleSpacer)
        case .divider:
            return Tile(id: Self.pinnedTileID(for: item), content: .divider)
        }
    }

    private func trailingTile(for item: TrailingTileItem) -> Tile? {
        switch item.kind {
        case .folder:
            if let sourceTileID = item.sourceTileID,
               let tile = systemOtherTilesByID[sourceTileID],
               case .folder(let folder) = tile.content {
                return Tile(
                    id: Self.trailingTileID(for: item),
                    content: .folder(FolderTile(
                        url: folder.url,
                        displayName: folder.displayName,
                        displayMode: resolvedFolderDisplayMode(for: item),
                        contentViewMode: resolvedFolderContentViewMode(for: item),
                        sortMode: resolvedFolderSortMode(for: item)
                    ))
                )
            }

            guard let folderURL = item.folderURL else {
                return nil
            }
            return Tile(
                id: Self.trailingTileID(for: item),
                content: .folder(FolderTile(
                    url: folderURL,
                    // Legacy payloads may not have captured a localized name.
                    // Reconstruct lexically so startup never probes a protected
                    // folder before the user explicitly opens it.
                    displayName: item.folderDisplayName
                        ?? (folderURL.lastPathComponent.isEmpty
                            ? "Folder"
                            : folderURL.lastPathComponent),
                    displayMode: resolvedFolderDisplayMode(for: item),
                    contentViewMode: resolvedFolderContentViewMode(for: item),
                    sortMode: resolvedFolderSortMode(for: item)
                ))
            )
        case .trash:
            return Tile(id: Self.trailingTileID(for: item), content: .trash)
        case .widget:
            guard let widgetKind = item.widgetKind,
                  let ownerBundleIdentifier = item.widgetOwnerBundleIdentifier else {
                return nil
            }
            return Tile(
                id: Self.trailingTileID(for: item),
                content: .widget(Self.makeWidgetTile(
                    kind: widgetKind,
                    ownerBundleIdentifier: ownerBundleIdentifier,
                    span: item.widgetSpan ?? .three,
                    settings: item.widgetSettings ?? [:]
                ))
            )
        case .smartStack:
            return Tile(
                id: Self.trailingTileID(for: item),
                content: .smartStack(Self.makeSmartStackTile(
                    identifier: item.id,
                    widgets: visibleSmartStackWidgets(hiddenOwnerBundleIdentifiers: item.hiddenWidgetOwnerBundleIdentifiers)
                ))
            )
        case .spacer:
            return Tile(id: Self.trailingTileID(for: item), content: .spacer)
        case .flexibleSpacer:
            return Tile(id: Self.trailingTileID(for: item), content: .flexibleSpacer)
        case .divider:
            return Tile(id: Self.trailingTileID(for: item), content: .divider)
        }
    }

    private func rebuildTiles() {
        let pinnedWithoutFinder = pinnedTiles.filter { !Self.isFinder($0) }
        let pinnedBundleIDs = Self.bundleIdentifiers(in: pinnedWithoutFinder)
        let hiddenBundleIDs = Set(preferences.hiddenAppBundleIdentifiers)

        let currentUnpinned = WorkspaceService.shared.runningApps
            .filter {
                $0.bundleIdentifier != Self.finderBundleID
                    && !pinnedBundleIDs.contains($0.bundleIdentifier)
                    && !hiddenBundleIDs.contains($0.bundleIdentifier)
            }

        displayedRunning = resolveDisplayedRunning(
            currentUnpinned: currentUnpinned,
            pinnedBundleIDs: pinnedBundleIDs
        )

        let shelveMode = preferences.enablesShelveMode
        let hidesFinder = shelveMode && preferences.shelveHidesFinder
        let hidesTrash = shelveMode && preferences.shelveHidesTrash
        let runningTiles: [Tile]
        if !preferences.showsRunningApps {
            runningTiles = []
        } else if preferences.hidesRecentApps {
            // "Hide recent apps" only suppresses the non-running tail ,
            // currently running unpinned apps still belong in the dock.
            // The only non-running entry `displayedRunning` ever holds is
            // the trailing "ghost" preserved by `resolveDisplayedRunning`
            // so a just-quit app's slot doesn't snap shut; filter it out.
            let liveBundleIDs = WorkspaceService.shared.runningBundleIdentifiers
            runningTiles = displayedRunning
                .filter { liveBundleIDs.contains($0.bundleIdentifier) }
                .map(Self.tile(for:))
        } else {
            runningTiles = displayedRunning.map(Self.tile(for:))
        }
        let minimizedWindowTiles = preferences.showsMinimizedWindows
            ? WorkspaceService.shared.minimizedWindows.map(Self.tile(for:))
            : []
        let mergedPinnedTiles = preferences.effectiveShowsActivePinnedSeparator
            ? pinnedWithoutFinder
            : pinnedWithoutFinder + runningTiles

        let leadingFinder: [Tile] = hidesFinder ? [] : [finderTile()]
        var result: [Tile] = tilesWithWidgets(appendedTo: leadingFinder)
        result.append(contentsOf: tilesWithWidgets(appendedTo: mergedPinnedTiles))
        if preferences.effectiveShowsActivePinnedSeparator, !runningTiles.isEmpty {
            result.append(Tile(id: "divider:running", content: .divider))
            result.append(contentsOf: tilesWithWidgets(appendedTo: runningTiles))
        }
        result.append(Tile(id: "divider:trailing", content: .divider))
        let trailing = trailingTiles(withInsertedMinimizedWindows: minimizedWindowTiles)
        result.append(contentsOf: hidesTrash ? trailing.filter { !Self.isTrash($0) } : trailing)
        tiles = result.map(applyingAppWidgetDisplay(to:))
    }

    /// Inserts every `layout.insertions` entry the active theme defines
    /// into the assembled tile list. Anchors are resolved against the
    /// current list, so themes can target stable structural ids
    /// (`divider:trailing`, `divider:running`) or any pinned/running
    /// app by its bundle identifier. Insertions whose anchor doesn't
    /// resolve are skipped silently, themes stay portable across
    /// docks that don't happen to contain the referenced app.
    ///
    /// Called by `DockPresentationService` rather than from `rebuildTiles`
    /// so the inserted tiles survive its transient editor/drag merge.
    /// Keeping this in the canonical presentation pipeline also guarantees
    /// the renderer and window measurement see identical insertions.
    static func applyingThemeLayoutInsertions(to tiles: [Tile]) -> [Tile] {
        guard let insertions = ThemeManager.shared.activeManifest?.layout?.insertions,
              !insertions.isEmpty else {
            return tiles
        }
        var result = tiles
        for (index, insertion) in insertions.enumerated() {
            guard let content = themeInsertionContent(insertion) else { continue }
            let anchorAfter = insertion.after
            let anchorBefore = insertion.before
            guard let anchor = anchorAfter ?? anchorBefore else { continue }
            guard let anchorIdx = themeInsertionAnchorIndex(in: result, anchor: anchor) else { continue }
            let insertAt = anchorAfter != nil ? anchorIdx + 1 : anchorIdx
            let tile = Tile(
                id: "theme:insert:\(index):\(insertion.kind)",
                content: content
            )
            result.insert(tile, at: insertAt)
        }
        return result
    }

    /// Resolves a `ThemeLayoutInsertion` to a `TileContent`. Structural
    /// primitives win first; otherwise the kind is parsed as a
    /// `WidgetKind` raw value and materialized via `WidgetCatalog` so
    /// a theme can drop e.g. a Search bar after Finder with the right
    /// owner-bundle wiring without the user having to do anything.
    private static func themeInsertionContent(_ insertion: ThemeLayoutInsertion) -> TileContent? {
        switch insertion.kind {
        case "spacer": return .spacer
        case "flexibleSpacer": return .flexibleSpacer
        case "divider": return .divider
        default:
            guard let widgetKind = WidgetKind(rawValue: insertion.kind),
                  let registration = WidgetCatalog.staticRegistrations.first(where: { $0.kind == widgetKind }) else {
                return nil
            }
            let span: TileSpan = insertion.span
                .flatMap(TileSpan.init(rawValue:)) ?? registration.defaultSpan
            return .widget(registration.makeTile(span: span))
        }
    }

    private static func themeInsertionAnchorIndex(in tiles: [Tile], anchor: String) -> Int? {
        if let exact = tiles.firstIndex(where: { $0.id == anchor }) {
            return exact
        }
        return tiles.firstIndex { tile in
            if case .app(let app) = tile.content, app.bundleIdentifier == anchor {
                return true
            }
            return false
        }
    }

    private static func isTrash(_ tile: Tile) -> Bool {
        if case .trash = tile.content { return true }
        return false
    }

    private func trailingTiles(withInsertedMinimizedWindows minimizedWindowTiles: [Tile]) -> [Tile] {
        guard !minimizedWindowTiles.isEmpty else {
            return trailingTiles
        }

        var result: [Tile] = []
        var insertedMinimizedWindows = false

        for tile in trailingTiles {
            if !insertedMinimizedWindows, case .trash = tile.content {
                result.append(contentsOf: minimizedWindowTiles)
                insertedMinimizedWindows = true
            }
            result.append(tile)
        }

        if !insertedMinimizedWindows {
            result.append(contentsOf: minimizedWindowTiles)
        }

        return result
    }

    private func tilesWithWidgets(appendedTo baseTiles: [Tile]) -> [Tile] {
        var result: [Tile] = []

        for tile in baseTiles {
            result.append(tile)
            if let bundleIdentifier = bundleIdentifier(of: tile) {
                result.append(contentsOf: widgetTiles(for: bundleIdentifier))
            } else if case .appFolder(let folder) = tile.content {
                result.append(contentsOf: openedAppTiles(for: folder))
            }
        }

        return result
    }

    private func openedAppTiles(for folder: AppFolderTile) -> [Tile] {
        if folder.contentViewMode == .inline {
            guard expandedInlineAppFolderIDs.contains(folder.identifier) else {
                return []
            }

            return folder.apps.map { app in
                Tile(
                    id: "folder-running:\(folder.identifier):\(app.bundleIdentifier)",
                    content: .app(app)
                )
            }
        }

        guard preferences.showsGroupedOpenedAppsInDock else {
            return []
        }

        let runningBundleIdentifiers = WorkspaceService.shared.runningBundleIdentifiers
        let hiddenBundleIdentifiers = Set(preferences.hiddenAppBundleIdentifiers)
        var result: [Tile] = []

        for app in folder.apps
        where runningBundleIdentifiers.contains(app.bundleIdentifier)
            && !hiddenBundleIdentifiers.contains(app.bundleIdentifier) {
            let tile = Tile(
                id: "folder-running:\(folder.identifier):\(app.bundleIdentifier)",
                content: .app(app)
            )
            result.append(tile)
            result.append(contentsOf: widgetTiles(for: app.bundleIdentifier))
        }

        return result
    }

    private func widgetTiles(for bundleIdentifier: String) -> [Tile] {
        guard !preferences.isAppHiddenInDocky(bundleIdentifier: bundleIdentifier) else {
            return []
        }

        return preferences.widgetPlacements
            .filter { $0.ownerBundleIdentifier == bundleIdentifier && $0.kind != .nowPlaying }
            .map { placement in
                Tile(
                    id: "widget:\(placement.id)",
                    content: .widget(WidgetTile(
                        identifier: placement.id,
                        title: placement.kind.title,
                        kind: placement.kind,
                        ownerBundleIdentifier: placement.ownerBundleIdentifier,
                        span: placement.span
                    ))
                )
            }
    }

    private func applyingAppWidgetDisplay(to tile: Tile) -> Tile {
        guard case .app(let app) = tile.content,
              let displayedWidget = displayedAppWidget(for: app.bundleIdentifier) else {
            return tile
        }

        return Tile(
            id: tile.id,
            content: .app(AppTile(
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.displayName,
                displayedWidget: displayedWidget
            ))
        )
    }

    private func displayedAppWidget(for bundleIdentifier: String) -> WidgetTile? {
        guard let display = appWidgetDisplay(bundleIdentifier: bundleIdentifier),
              !isAppInFolder(bundleIdentifier: bundleIdentifier),
              isAppWidgetDisplayActive(display) else {
            return nil
        }

        return Self.makeWidgetTile(
            kind: display.kind,
            ownerBundleIdentifier: bundleIdentifier,
            span: display.span
        )
    }

    private func isAppWidgetDisplayActive(_ display: AppWidgetDisplay) -> Bool {
        switch display.kind {
        case .nowPlaying:
            mediaPlayback.state(for: display.bundleIdentifier)?.hasContent == true
        case .calendar, .calendarDate, .reminders, .batteries, .systemStatus, .weather, .search, .photoFrame:
            true
        case .external:
            true
        }
    }

    private func defaultAppWidgetSpan(kind: WidgetKind, ownerBundleIdentifier: String) -> TileSpan {
        WidgetCatalog.staticRegistrations.first {
            $0.kind == kind && $0.ownerBundleIdentifier == ownerBundleIdentifier
        }?.defaultSpan ?? .three
    }

    private func allSmartStackWidgets() -> [WidgetTile] {
        let staticWidgets = WidgetCatalog.smartStackRegistrations.map {
            $0.makeTile()
        }

        let nowPlayingWidgets = mediaPlayback.statesByBundleIdentifier.values
            .filter(\.hasContent)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { state in
                Self.makeWidgetTile(
                    kind: .nowPlaying,
                    ownerBundleIdentifier: state.bundleIdentifier,
                    span: .three
                )
            }

        return staticWidgets + nowPlayingWidgets
    }

    private func visibleSmartStackWidgets(hiddenOwnerBundleIdentifiers: [String]) -> [WidgetTile] {
        let hiddenOwnerBundleIdentifierSet = Set(hiddenOwnerBundleIdentifiers)
        return allSmartStackWidgets().filter { !hiddenOwnerBundleIdentifierSet.contains($0.ownerBundleIdentifier) }
    }

    private static func makeSmartStackTile(identifier: String, widgets: [WidgetTile]) -> SmartStackTile {
        SmartStackTile(
            identifier: identifier,
            title: "Smart Stack",
            widgets: widgets,
            span: .three
        )
    }

    /// Preserves rightmost-unpinned-app position across exits. Rules:
    ///   - Still-running apps keep their display slot.
    ///   - Newly-launched apps append to the end.
    ///   - A non-rightmost exit drops the tile (shifts remaining left).
    ///   - A rightmost exit holds the slot as a ghost until something newer
    ///     launches to take its place (or the ghost's bundle gets pinned).
    private func resolveDisplayedRunning(
        currentUnpinned: [RunningApp],
        pinnedBundleIDs: Set<String>
    ) -> [RunningApp] {
        let hiddenBundleIDs = Set(preferences.hiddenAppBundleIdentifiers)
        let currentMap = Dictionary(
            currentUnpinned.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let lastIndex = displayedRunning.count - 1

        var survived: [RunningApp] = []
        var pendingGhost: RunningApp?

        for (index, existing) in displayedRunning.enumerated() {
            if pinnedBundleIDs.contains(existing.bundleIdentifier)
                || hiddenBundleIDs.contains(existing.bundleIdentifier) {
                continue
            }
            if let live = currentMap[existing.bundleIdentifier] {
                survived.append(live)
            } else if index == lastIndex {
                pendingGhost = existing
            }
        }

        let existingIDs = Set(displayedRunning.map(\.bundleIdentifier))
        for app in currentUnpinned
        where !existingIDs.contains(app.bundleIdentifier)
            && !hiddenBundleIDs.contains(app.bundleIdentifier) {
            survived.append(app)
        }

        if let ghost = pendingGhost,
           !hiddenBundleIDs.contains(ghost.bundleIdentifier) {
            let ghostLaunch = ghost.launchDate ?? .distantPast
            let hasNewer = survived.contains { app in
                (app.launchDate ?? .distantPast) > ghostLaunch
            }
            if !hasNewer {
                survived.append(ghost)
            }
        }

        return survived
    }

    private static func bundleIdentifiers(in tiles: [Tile]) -> Set<String> {
        var ids: Set<String> = []
        for tile in tiles {
            if case .app(let app) = tile.content, !app.bundleIdentifier.isEmpty {
                ids.insert(app.bundleIdentifier)
            } else if case .appFolder(let folder) = tile.content {
                ids.formUnion(folder.bundleIdentifiers)
            }
        }
        return ids
    }

    private static func isFinder(_ tile: Tile) -> Bool {
        if case .app(let app) = tile.content {
            return app.bundleIdentifier == finderBundleID
        }
        return false
    }

    private func finderTile() -> Tile {
        let app =
            makeAppTile(bundleIdentifier: Self.finderBundleID)
            ?? AppTile(
                bundleIdentifier: Self.finderBundleID,
                displayName: "Finder"
            )
        return Tile(
            id: "pinned:\(Self.finderBundleID)",
            content: .app(app)
        )
    }

    nonisolated private static func tile(for minimizedWindow: AppWindow) -> Tile {
        Tile(id: "minimized-window:\(minimizedWindow.windowIdentifier)", content: .minimizedWindow(minimizedWindow))
    }

    nonisolated private static func pinnedItem(from tile: Tile) -> PinnedTileItem? {
        switch tile.content {
        case .app(let app):
            guard !app.bundleIdentifier.isEmpty else {
                return nil
            }
            return .app(bundleIdentifier: app.bundleIdentifier)
        case .appFolder(let folder):
            guard folder.bundleIdentifiers.count >= 2 else {
                return nil
            }
            return .appFolder(
                id: folder.identifier,
                displayName: folder.displayName,
                bundleIdentifiers: folder.bundleIdentifiers,
                displayMode: folder.displayMode,
                contentViewMode: folder.contentViewMode
            )
        case .launchpad(let launchpad):
            return .launchpad(id: launchpad.identifier)
        case .startMenu(let menu):
            return .startMenu(id: menu.identifier)
        case .widget, .smartStack:
            return nil
        case .spacer:
            return PinnedTileItem(
                id: tile.id,
                kind: .spacer,
                bundleIdentifier: nil,
                folderDisplayName: nil,
                folderBundleIdentifiers: [],
                appFolderDisplayMode: nil,
                folderContentViewMode: nil,
                widgetKind: nil,
                widgetOwnerBundleIdentifier: nil,
                widgetSpan: nil,
                hiddenWidgetOwnerBundleIdentifiers: []
            )
        case .flexibleSpacer:
            return PinnedTileItem(
                id: tile.id,
                kind: .flexibleSpacer,
                bundleIdentifier: nil,
                folderDisplayName: nil,
                folderBundleIdentifiers: [],
                appFolderDisplayMode: nil,
                folderContentViewMode: nil,
                widgetKind: nil,
                widgetOwnerBundleIdentifier: nil,
                widgetSpan: nil,
                hiddenWidgetOwnerBundleIdentifiers: []
            )
        case .divider:
            return PinnedTileItem(
                id: tile.id,
                kind: .divider,
                bundleIdentifier: nil,
                folderDisplayName: nil,
                folderBundleIdentifiers: [],
                appFolderDisplayMode: nil,
                folderContentViewMode: nil,
                widgetKind: nil,
                widgetOwnerBundleIdentifier: nil,
                widgetSpan: nil,
                hiddenWidgetOwnerBundleIdentifiers: []
            )
        case .folder, .trash, .minimizedWindow:
            return nil
        }
    }

    nonisolated private static func pinnedTileID(
        for item: PinnedTileItem
    ) -> String {
        "pinned:\(item.id)"
    }

    nonisolated private static func trailingTileID(
        for item: TrailingTileItem
    ) -> String {
        "trailing:\(item.id)"
    }

    private static func matchesImportedPinnedItem(_ existing: PinnedTileItem, _ imported: PinnedTileItem) -> Bool {
        guard existing.kind == imported.kind else {
            return false
        }

        switch imported.kind {
        case .app:
            return existing.bundleIdentifier == imported.bundleIdentifier
        case .launchpad, .startMenu:
            return existing.id == imported.id
        case .spacer, .flexibleSpacer, .divider:
            return existing.id == imported.id
        case .appFolder:
            return existing.id == imported.id
        case .widget, .smartStack:
            return false
        }
    }

    func launchpadApps() -> [AppTile] {
        Self.installedApplications().map { app in
            AppTile(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
        }
    }

    nonisolated private static func trailingItem(from tile: Tile) -> TrailingTileItem? {
        switch tile.content {
        case .folder(let folder):
            return .folder(
                sourceTileID: tile.id,
                displayMode: folder.displayMode,
                contentViewMode: folder.contentViewMode
            )
        case .trash:
            return .trash()
        case .launchpad, .startMenu, .widget, .smartStack, .app, .appFolder, .spacer, .flexibleSpacer, .divider, .minimizedWindow:
            return nil
        }
    }

    private func normalizeAppFolderDisplayName(_ value: String) -> String {
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Folder" : normalized
    }

    // MARK: - Parsing plist entries

    nonisolated private static func parse(
        entry: [String: Any],
        fallbackID: String
    ) -> Tile? {
        let tileType = entry["tile-type"] as? String
        let tileData = entry["tile-data"] as? [String: Any] ?? [:]
        let guid = (entry["GUID"] as? NSNumber)?.stringValue ?? fallbackID

        switch tileType {
        case "file-tile":
            return parseAppTile(id: guid, data: tileData)
        case "directory-tile":
            return parseFolderTile(id: guid, data: tileData)
        case "spacer-tile", "small-spacer-tile":
            return Tile(id: guid, content: .spacer)
        default:
            return nil
        }
    }

    nonisolated private static func parseAppTile(
        id: String,
        data: [String: Any]
    ) -> Tile? {
        let label = (data["file-label"] as? String) ?? "Unknown"
        let fileData = data["file-data"] as? [String: Any]
        let urlString = fileData?["_CFURLString"] as? String
        let url = urlString.flatMap { URL(string: $0) }
        let bundleIdentifier = (data["bundle-identifier"] as? String)
            ?? inferBundleIdentifier(from: url)
            ?? ""
        return Tile(id: id, content: .app(AppTile(
            bundleIdentifier: bundleIdentifier,
            displayName: label
        )))
    }

    private static func makePinnedTile(from tile: Tile, item: PinnedTileItem) -> Tile? {
        guard case .app(let app) = tile.content else {
            return nil
        }

        return Tile(
            id: pinnedTileID(for: item),
            content: .app(AppTile(bundleIdentifier: item.bundleIdentifier ?? "", displayName: app.displayName))
        )
    }

    private func makePinnedTile(
        bundleIdentifier: String,
        item: PinnedTileItem
    ) -> Tile? {
        guard let app = makeAppTile(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        return Tile(
            id: Self.pinnedTileID(for: item),
            content: .app(app)
        )
    }

    private func makeAppTile(bundleIdentifier: String) -> AppTile? {
        guard !bundleIdentifier.isEmpty else {
            return nil
        }

        if let cached =
                applicationTilesByBundleIdentifier[bundleIdentifier] {
            return cached
        }
        if missingApplicationBundleIdentifiers.contains(bundleIdentifier) {
            return nil
        }

        scheduleApplicationMetadataResolution(for: bundleIdentifier)
        let fallbackName: String
        if bundleIdentifier == Self.finderBundleID {
            fallbackName = "Finder"
        } else {
            fallbackName =
                bundleIdentifier.split(separator: ".").last.map(String.init)
                ?? bundleIdentifier
        }
        return AppTile(
            bundleIdentifier: bundleIdentifier,
            displayName: fallbackName
        )
    }

    private static func makeWidgetTile(
        kind: WidgetKind,
        ownerBundleIdentifier: String,
        span: TileSpan,
        settings: WidgetSettings = [:]
    ) -> WidgetTile {
        WidgetTile(
            identifier: "\(ownerBundleIdentifier):\(kind.rawValue)",
            title: kind.title,
            kind: kind,
            ownerBundleIdentifier: ownerBundleIdentifier,
            span: span,
            settings: settings
        )
    }

    nonisolated private static func parseFolderTile(
        id: String,
        data: [String: Any]
    ) -> Tile? {
        let label = (data["file-label"] as? String) ?? "Folder"
        let fileData = data["file-data"] as? [String: Any]
        guard let urlString = fileData?["_CFURLString"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }

        let displayMode = parseFolderDisplayMode(from: data["displayas"])
        let contentViewMode = parseFolderContentViewMode(from: data["showas"])
        return Tile(
            id: id,
            content: .folder(FolderTile(
                url: url,
                displayName: label,
                displayMode: displayMode,
                contentViewMode: contentViewMode
            ))
        )
    }

    nonisolated private static func parseFolderDisplayMode(
        from rawValue: Any?
    ) -> FolderTileDisplayMode {
        guard (rawValue as? NSNumber)?.intValue == 1 else {
            return .contents
        }

        return .folder
    }

    nonisolated private static func parseFolderContentViewMode(
        from rawValue: Any?
    ) -> FolderTileContentViewMode {
        switch (rawValue as? NSNumber)?.intValue {
        case 3:
            return .list
        case 1, 2, nil:
            return .grid
        default:
            return .grid
        }
    }

    nonisolated private static func inferBundleIdentifier(
        from url: URL?
    ) -> String? {
        guard let url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    nonisolated private static func fallbackTileID(
        for entry: [String: Any],
        at index: Int,
        section: String
    ) -> String {
        let tileType = (entry["tile-type"] as? String) ?? "unknown"
        let tileData = entry["tile-data"] as? [String: Any] ?? [:]
        let fileData = tileData["file-data"] as? [String: Any]
        let urlString = fileData?["_CFURLString"] as? String
        let bundleIdentifier = tileData["bundle-identifier"] as? String
        let label = tileData["file-label"] as? String

        let signature = [tileType, bundleIdentifier, urlString, label]
            .compactMap { $0?.replacingOccurrences(of: ":", with: "_") }
            .joined(separator: ":")

        if signature.isEmpty {
            return "\(section):\(index):\(tileType)"
        }

        return "\(section):\(index):\(signature)"
    }

    // MARK: - Running-but-not-pinned tiles

    nonisolated private static func tile(for app: RunningApp) -> Tile {
        Tile(
            id: "running:\(app.bundleIdentifier)",
            content: .app(AppTile(
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.localizedName
            ))
        )
    }
}

private struct SystemDockSnapshot: @unchecked Sendable {
    let pinnedTiles: [Tile]
    let otherTiles: [Tile]
}

private struct SystemDockPreferenceSyncRequest {
    let credentials: ProfileMutationCredentials
    let marksSystemImportComplete: Bool
    let reason: String
}

private struct ResolvedApplicationMetadata: Sendable {
    let displayName: String
}
