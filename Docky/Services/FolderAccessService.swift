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
    private var contentsCache: [URL: (date: Date, items: [URL])] = [:]
    private var watchersByURL: [URL: FolderWatcher] = [:]

    private init() {}

    deinit {
        for watcher in watchersByURL.values {
            watcher.source.cancel()
        }
    }

    /// All visible contents of the folder, newest-modified first.
    /// Cached briefly to avoid hitting the filesystem on every view update.
    func contents(of folderURL: URL) -> [URL] {
        if case .loaded(let items) = snapshot(of: folderURL) {
            return items
        }
        return []
    }

    func snapshot(of folderURL: URL) -> FolderContentsSnapshot {
        cachedSnapshot(of: folderURL)
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

    func sortedContents(of folderURL: URL, sortMode: FolderTileSortMode) -> [URL] {
        sortedItems(in: contents(of: folderURL), sortMode: sortMode)
    }

    func sortedItems(in items: [URL], sortMode: FolderTileSortMode) -> [URL] {
        let entries = items.map(FolderSortEntry.init)

        return entries.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
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
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .dateCreated:
                if lhs.creationDate != rhs.creationDate {
                    return lhs.creationDate > rhs.creationDate
                }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .dateAdded:
                if lhs.addedDate != rhs.addedDate {
                    return lhs.addedDate > rhs.addedDate
                }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .kind:
                let kindComparison = lhs.kind.localizedStandardCompare(rhs.kind)
                if kindComparison != .orderedSame {
                    return kindComparison == .orderedAscending
                }
                let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }
            case .size:
                if lhs.size != rhs.size {
                    return lhs.size > rhs.size
                }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            }

            return lhs.url.path < rhs.url.path
        }
        .map(\.url)
    }

    func sortedItems(in snapshot: FolderContentsSnapshot, sortMode: FolderTileSortMode) -> [URL] {
        guard case .loaded(let items) = snapshot else {
            return []
        }

        return sortedItems(in: items, sortMode: sortMode)
    }

    /// Up to `limit` URLs from the folder, newest-modified first.
    func recentContents(of folderURL: URL, sortMode: FolderTileSortMode, limit: Int = 3) -> [URL] {
        Array(sortedContents(of: folderURL, sortMode: sortMode).prefix(limit))
    }

    func beginWatching(_ folderURL: URL, ownerID: String) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        if var watcher = watchersByURL[normalizedFolderURL] {
            watcher.ownerIDs.insert(ownerID)
            watchersByURL[normalizedFolderURL] = watcher
            return
        }

        let descriptor = open(normalizedFolderURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.handleWatcherEvent(for: normalizedFolderURL)
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        watchersByURL[normalizedFolderURL] = FolderWatcher(
            ownerIDs: [ownerID],
            source: source
        )
        source.resume()
    }

    func endWatching(_ folderURL: URL, ownerID: String) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        guard var watcher = watchersByURL[normalizedFolderURL] else {
            return
        }

        watcher.ownerIDs.remove(ownerID)
        guard watcher.ownerIDs.isEmpty else {
            watchersByURL[normalizedFolderURL] = watcher
            return
        }

        watchersByURL.removeValue(forKey: normalizedFolderURL)
        watcher.source.cancel()
    }

    private func cachedSnapshot(of folderURL: URL) -> FolderContentsSnapshot {
        let normalizedFolderURL = folderURL.standardizedFileURL

        if let cached = contentsCache[normalizedFolderURL],
           Date().timeIntervalSince(cached.date) < staleAfter {
            return .loaded(cached.items)
        }

        let keys: [URLResourceKey] = [
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .localizedNameKey,
            .localizedTypeDescriptionKey,
            .totalFileAllocatedSizeKey
        ]
        let loaded: [URL]
        do {
            loaded = try FileManager.default.contentsOfDirectory(
                at: normalizedFolderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ).sorted(by: { Self.modDate($0) > Self.modDate($1) })
        } catch {
            return .unreadable
        }

        contentsCache[normalizedFolderURL] = (Date(), loaded)
        return .loaded(loaded)
    }

    func invalidateCache() {
        contentsCache.removeAll()
    }

    private func invalidateCache(for folderURL: URL) {
        contentsCache.removeValue(forKey: folderURL.standardizedFileURL)
    }

    private func handleWatcherEvent(for folderURL: URL) {
        invalidateCache(for: folderURL)
        changeToken &+= 1
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

private struct FolderWatcher {
    var ownerIDs: Set<String>
    let source: DispatchSourceFileSystemObject
}

private struct FolderSortEntry {
    let url: URL
    let displayName: String
    let modificationDate: Date
    let creationDate: Date
    let addedDate: Date
    let kind: String
    let size: Int
    let isDirectory: Bool

    nonisolated init(url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
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
    }
}
