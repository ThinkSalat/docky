//
//  FolderAccessService.swift
//  Docky
//
//  Reads folder contents for preview tiles. Access is evaluated against the
//  actual pinned URL; there is no global Full Disk Access probe because macOS
//  exposes no supported API whose result would describe every folder.
//

import AppKit
import Combine
import Dispatch
import Foundation

enum FolderContentsSnapshot: Equatable {
    case loaded([URL])
    case unreadable
}

final class FolderAccessService: ObservableObject {
    static let shared = FolderAccessService()

    @Published private(set) var changeToken: UInt64 = 0

    private let staleAfter: TimeInterval = 15
    private let loadWorker = FolderSnapshotLoadWorker()
    private let descriptorWorker = FolderWatcherDescriptorWorker()
    private var contentsCache: [URL: CachedFolderContents] = [:]
    private var loadGenerationByURL: [URL: UInt64] = [:]
    private var inFlightLoads: [URL: InFlightFolderLoad] = [:]
    private var watcherOwnerIDsByURL: [URL: Set<String>] = [:]
    private var watcherGenerationByURL: [URL: UInt64] = [:]
    private var inFlightWatcherOpens: [URL: InFlightFolderWatcherOpen] = [:]
    private var watchersByURL: [URL: FolderWatcher] = [:]

    private init() {}

    deinit {
        for request in inFlightWatcherOpens.values {
            request.task.cancel()
        }
        for watcher in watchersByURL.values {
            watcher.source.cancel()
        }
    }

    /// Returns a snapshot for an explicit folder-content interaction.
    ///
    /// Callers that render the dock itself must use the cached-only APIs
    /// below. Reading here can trigger macOS Files & Folders consent for
    /// protected locations such as Downloads, Desktop, and Documents.
    func loadSnapshot(of folderURL: URL) async -> FolderContentsSnapshot {
        let normalizedFolderURL = folderURL.standardizedFileURL

        if let cached = contentsCache[normalizedFolderURL],
           Date().timeIntervalSince(cached.date) < staleAfter {
            return .loaded(cached.items)
        }

        let generation = loadGenerationByURL[normalizedFolderURL, default: 0]
        let request: InFlightFolderLoad
        if let current = inFlightLoads[normalizedFolderURL],
           current.generation == generation {
            request = current
        } else {
            let requestID = UUID()
            let task = Task {
                await loadWorker.load(normalizedFolderURL)
            }
            request = InFlightFolderLoad(
                id: requestID,
                generation: generation,
                task: task
            )
            inFlightLoads[normalizedFolderURL] = request
        }

        let result = await request.task.value

        // A watcher event or explicit invalidation may retire this request
        // while its filesystem call is in flight. Never republish that stale
        // result over the newer generation.
        guard loadGenerationByURL[normalizedFolderURL, default: 0]
                == request.generation else {
            return contentsCache[normalizedFolderURL]
                .map { .loaded($0.items) }
                ?? .unreadable
        }

        if inFlightLoads[normalizedFolderURL]?.id == request.id {
            inFlightLoads.removeValue(forKey: normalizedFolderURL)
        }

        switch result {
        case .loaded(let loadedContents):
            let previousItems = contentsCache[normalizedFolderURL]?.items
            contentsCache[normalizedFolderURL] = CachedFolderContents(
                date: Date(),
                items: loadedContents.defaultItems,
                sortedItemsByMode: loadedContents.sortedItemsByMode,
                metadataByURL: loadedContents.metadataByURL
            )
            if previousItems != loadedContents.defaultItems {
                changeToken &+= 1
            }
            return .loaded(loadedContents.defaultItems)

        case .unreadable:
            if contentsCache.removeValue(forKey: normalizedFolderURL) != nil {
                changeToken &+= 1
            }
            return .unreadable
        }
    }

    /// Returns only data and sort metadata already loaded during this app
    /// session. This never enumerates or inspects an item URL and is therefore
    /// safe during launch and render.
    func cachedContentsIfPresent(
        of folderURL: URL,
        sortMode: FolderTileSortMode
    ) -> [URL]? {
        let normalizedFolderURL = folderURL.standardizedFileURL
        guard let cached = contentsCache[normalizedFolderURL] else {
            return nil
        }

        return cached.sortedItemsByMode[sortMode.rawValue] ?? cached.items
    }

    func cachedContents(
        of folderURL: URL,
        sortMode: FolderTileSortMode
    ) -> [URL] {
        cachedContentsIfPresent(
            of: folderURL,
            sortMode: sortMode
        ) ?? []
    }

    func cachedRecentContents(
        of folderURL: URL,
        sortMode: FolderTileSortMode,
        limit: Int = 3
    ) -> [URL] {
        Array(cachedContents(of: folderURL, sortMode: sortMode).prefix(limit))
    }

    /// Metadata captured by the off-main explicit load. This accessor never
    /// touches the item URL and is safe to call while SwiftUI is rendering or
    /// AppKit is tracking a menu.
    func cachedMetadata(
        for itemURL: URL,
        in folderURL: URL
    ) -> FolderItemMetadata? {
        contentsCache[folderURL.standardizedFileURL]?
            .metadataByURL[itemURL.standardizedFileURL]
    }

    /// Opens the least-privileged privacy pane relevant to a folder that the
    /// user has already tried to preview. This is called only from an explicit
    /// recovery action in an unreadable-folder UI.
    func openFilesAndFoldersSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Starts observing a folder after the user has explicitly opened its
    /// contents. Opening the descriptor can itself require protected-folder
    /// access, so dock rendering must never call this method.
    func beginWatching(_ folderURL: URL, ownerID: String) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        watcherOwnerIDsByURL[normalizedFolderURL, default: []]
            .insert(ownerID)
        startOpeningWatcherIfNeeded(for: normalizedFolderURL)
    }

    func endWatching(_ folderURL: URL, ownerID: String) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        guard var ownerIDs = watcherOwnerIDsByURL[normalizedFolderURL] else {
            return
        }

        ownerIDs.remove(ownerID)
        guard ownerIDs.isEmpty else {
            watcherOwnerIDsByURL[normalizedFolderURL] = ownerIDs
            return
        }

        watcherOwnerIDsByURL.removeValue(forKey: normalizedFolderURL)
        watcherGenerationByURL[normalizedFolderURL, default: 0] &+= 1
        inFlightWatcherOpens.removeValue(forKey: normalizedFolderURL)?
            .task.cancel()
        watchersByURL.removeValue(forKey: normalizedFolderURL)?
            .source.cancel()
    }

    func invalidateCache() {
        guard !contentsCache.isEmpty || !inFlightLoads.isEmpty else {
            return
        }
        let affectedURLs =
            Set(contentsCache.keys).union(inFlightLoads.keys)
        for folderURL in affectedURLs {
            advanceLoadGeneration(for: folderURL)
        }
        inFlightLoads.removeAll()
        contentsCache.removeAll()
        changeToken &+= 1
    }

    /// Invalidates one explicitly retried or changed folder without
    /// disrupting unrelated menus and previews that may still be loading.
    func invalidateCache(of folderURL: URL) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        advanceLoadGeneration(for: normalizedFolderURL)
        inFlightLoads.removeValue(forKey: normalizedFolderURL)
        contentsCache.removeValue(forKey: normalizedFolderURL)
    }

    private func advanceLoadGeneration(for folderURL: URL) {
        loadGenerationByURL[folderURL, default: 0] &+= 1
    }

    private func startOpeningWatcherIfNeeded(for folderURL: URL) {
        guard watchersByURL[folderURL] == nil,
              inFlightWatcherOpens[folderURL] == nil,
              let ownerIDs = watcherOwnerIDsByURL[folderURL],
              !ownerIDs.isEmpty else {
            return
        }

        let requestID = UUID()
        let generation = watcherGenerationByURL[folderURL, default: 0]
        let requestOwnerIDs = ownerIDs
        let descriptorWorker = descriptorWorker
        let task = Task { [weak self] in
            let descriptor = await descriptorWorker.openDescriptor(
                for: folderURL
            )
            guard let self else {
                if descriptor >= 0 {
                    close(descriptor)
                }
                return
            }
            self.finishOpeningWatcher(
                for: folderURL,
                requestID: requestID,
                generation: generation,
                requestOwnerIDs: requestOwnerIDs,
                descriptor: descriptor
            )
        }

        inFlightWatcherOpens[folderURL] = InFlightFolderWatcherOpen(
            id: requestID,
            generation: generation,
            ownerIDs: requestOwnerIDs,
            task: task
        )
    }

    private func finishOpeningWatcher(
        for folderURL: URL,
        requestID: UUID,
        generation: UInt64,
        requestOwnerIDs: Set<String>,
        descriptor: Int32
    ) {
        let isCurrentRequest =
            inFlightWatcherOpens[folderURL]?.id == requestID
        if isCurrentRequest {
            inFlightWatcherOpens.removeValue(forKey: folderURL)
        }

        guard descriptor >= 0 else {
            return
        }

        guard isCurrentRequest,
              watcherGenerationByURL[folderURL, default: 0] == generation,
              let currentOwnerIDs = watcherOwnerIDsByURL[folderURL],
              !currentOwnerIDs.isEmpty,
              !requestOwnerIDs.isDisjoint(with: currentOwnerIDs),
              watchersByURL[folderURL] == nil else {
            close(descriptor)
            if isCurrentRequest {
                startOpeningWatcherIfNeeded(for: folderURL)
            }
            return
        }

        let watcherID = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [
                .write,
                .rename,
                .delete,
                .attrib,
                .extend,
                .link,
                .revoke
            ],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.handleWatcherEvent(
                for: folderURL,
                watcherID: watcherID
            )
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        watchersByURL[folderURL] = FolderWatcher(
            id: watcherID,
            source: source
        )
        source.resume()
    }

    private func handleWatcherEvent(
        for folderURL: URL,
        watcherID: UUID
    ) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        guard let watcher = watchersByURL[normalizedFolderURL],
              watcher.id == watcherID else {
            return
        }

        let terminalEvents: DispatchSource.FileSystemEvent = [
            .rename,
            .delete,
            .revoke
        ]
        if !watcher.source.data.intersection(terminalEvents).isEmpty {
            // A vnode source cannot recover after its watched object is
            // renamed, deleted, or revoked. Retire it before publishing
            // the change so the resulting refresh can open a new source.
            watchersByURL.removeValue(forKey: normalizedFolderURL)
            watcher.source.cancel()
        }

        invalidateCache(of: normalizedFolderURL)
        changeToken &+= 1
    }

}

private struct CachedFolderContents {
    let date: Date
    let items: [URL]
    let sortedItemsByMode: [String: [URL]]
    let metadataByURL: [URL: FolderItemMetadata]
}

private struct InFlightFolderLoad {
    let id: UUID
    let generation: UInt64
    let task: Task<FolderSnapshotLoadResult, Never>
}

private struct FolderWatcher {
    let id: UUID
    let source: DispatchSourceFileSystemObject
}

private struct InFlightFolderWatcherOpen {
    let id: UUID
    let generation: UInt64
    let ownerIDs: Set<String>
    let task: Task<Void, Never>
}

nonisolated struct FolderItemMetadata: Equatable, Sendable {
    let url: URL
    let displayName: String
    let isNavigableFolder: Bool
}

private nonisolated struct FolderSortEntry: Sendable {
    let url: URL
    let displayName: String
    let modificationDate: Date
    let creationDate: Date
    let addedDate: Date
    let kind: String
    let size: Int
    let isDirectory: Bool

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isPackageKey,
            .localizedNameKey,
            .localizedTypeDescriptionKey,
            .totalFileAllocatedSizeKey
        ])
        self.url = url
        self.displayName = values?.localizedName ?? url.lastPathComponent
        self.modificationDate = values?.contentModificationDate ?? .distantPast
        self.creationDate = values?.creationDate ?? .distantPast
        self.addedDate = values?.addedToDirectoryDate ?? .distantPast
        self.kind = values?.localizedTypeDescription ?? ""
        self.size = values?.fileSize ?? values?.totalFileAllocatedSize ?? 0
        self.isDirectory = values?.isDirectory == true
        self.isPackage = values?.isPackage == true
    }

    let isPackage: Bool

    var metadata: FolderItemMetadata {
        FolderItemMetadata(
            url: url,
            displayName: displayName,
            isNavigableFolder: isDirectory && !isPackage
        )
    }
}

private nonisolated struct LoadedFolderContents: Sendable {
    let defaultItems: [URL]
    let sortedItemsByMode: [String: [URL]]
    let metadataByURL: [URL: FolderItemMetadata]
}

private nonisolated enum FolderSnapshotLoadResult: Sendable {
    case loaded(LoadedFolderContents)
    case unreadable
}

/// Opens vnode descriptors away from MainActor. Protected folders, network
/// mounts, and file providers can all make `open` wait. The main actor owns
/// the registration state and validates the request again before installing
/// any descriptor returned by this worker.
private nonisolated final class FolderWatcherDescriptorWorker:
    @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "gt.quintero.Docky.folder-watcher-descriptor",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func openDescriptor(for folderURL: URL) async -> Int32 {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: open(
                        folderURL.path,
                        O_EVTONLY | O_CLOEXEC
                    )
                )
            }
        }
    }
}

/// Filesystem worker. Protected-folder enumeration and every item metadata
/// read stay off MainActor. Different folders use a concurrent queue so one
/// hung network mount or file provider cannot head-of-line block every later
/// folder interaction; callers still coalesce duplicate loads per URL.
private nonisolated final class FolderSnapshotLoadWorker:
    @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "gt.quintero.Docky.folder-snapshot-loader",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func load(_ folderURL: URL) async -> FolderSnapshotLoadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: Self.loadSynchronously(folderURL)
                )
            }
        }
    }

    private static func loadSynchronously(
        _ folderURL: URL
    ) -> FolderSnapshotLoadResult {
        let keys: [URLResourceKey] = [
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isPackageKey,
            .localizedNameKey,
            .localizedTypeDescriptionKey,
            .totalFileAllocatedSizeKey
        ]

        let discoveredItems: [URL]
        do {
            discoveredItems = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .unreadable
        }

        let entries = discoveredItems.map(FolderSortEntry.init)
        var sortedItemsByMode: [String: [URL]] = [:]
        for sortMode in FolderSortMode.allCases {
            sortedItemsByMode[sortMode.rawValue] =
                entries.sorted {
                    Self.precedes($0, $1, sortMode: sortMode)
                }
                .map(\.url)
        }

        return .loaded(
            LoadedFolderContents(
                defaultItems:
                    sortedItemsByMode[FolderSortMode.dateModified.rawValue]
                    ?? [],
                sortedItemsByMode: sortedItemsByMode,
                metadataByURL: Dictionary(
                    uniqueKeysWithValues: entries.map {
                        ($0.url.standardizedFileURL, $0.metadata)
                    }
                )
            )
        )
    }

    private enum FolderSortMode: String, CaseIterable {
        case name
        case dateModified
        case dateCreated
        case dateAdded
        case kind
        case size
    }

    private static func precedes(
        _ lhs: FolderSortEntry,
        _ rhs: FolderSortEntry,
        sortMode: FolderSortMode
    ) -> Bool {
        switch sortMode {
        case .name:
            let comparison = lhs.displayName.localizedStandardCompare(
                rhs.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
        case .dateModified:
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            let comparison = lhs.displayName.localizedStandardCompare(
                rhs.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        case .dateCreated:
            if lhs.creationDate != rhs.creationDate {
                return lhs.creationDate > rhs.creationDate
            }
            let comparison = lhs.displayName.localizedStandardCompare(
                rhs.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        case .dateAdded:
            if lhs.addedDate != rhs.addedDate {
                return lhs.addedDate > rhs.addedDate
            }
            let comparison = lhs.displayName.localizedStandardCompare(
                rhs.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        case .kind:
            let kindComparison = lhs.kind.localizedStandardCompare(rhs.kind)
            if kindComparison != .orderedSame {
                return kindComparison == .orderedAscending
            }
            let nameComparison = lhs.displayName.localizedStandardCompare(
                rhs.displayName
            )
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
        case .size:
            if lhs.size != rhs.size {
                return lhs.size > rhs.size
            }
            let comparison = lhs.displayName.localizedStandardCompare(
                rhs.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }

        return lhs.url.path < rhs.url.path
    }
}
