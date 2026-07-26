//
//  RecentFilesService.swift
//  Docky
//
//  Live "Recents" list backed by Spotlight, mirroring Finder's sidebar
//  Recents canned search at:
//    /System/Library/CoreServices/Finder.app/Contents/Resources/
//      MyLibraries/myDocuments.cannedSearch/Resources/search.savedSearch
//
//  The predicate filters to files that have a kMDItemLastUsedDate set and
//  whose UTI tree is user-perceivable content (or Office docs, or archives).
//  Results stream in live; consumers observe immutable entry snapshots.
//

import AppKit
import Combine
import Foundation
import OSLog

nonisolated struct RecentFileEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let displayName: String

    var id: String {
        url.standardizedFileURL.path
    }
}

@MainActor
final class RecentFilesService: ObservableObject {
    static let shared = RecentFilesService()
    private static let logger = Logger(subsystem: "gt.quintero.Docky", category: "RecentFiles")

    @Published private(set) var recentEntries: [RecentFileEntry] = []

    var recentURLs: [URL] {
        recentEntries.map(\.url)
    }

    private let worker: RecentFilesWorker
    private var iconPreloadTask: Task<Void, Never>?
    private static let maxResults = 50

    private init() {
        worker = RecentFilesWorker(maxResults: Self.maxResults)
        worker.start { [weak self] entries in
            Task { @MainActor [weak self] in
                self?.publish(entries)
            }
        }
    }

    deinit {
        iconPreloadTask?.cancel()
        worker.stop()
    }

    private func publish(_ entries: [RecentFileEntry]) {
        guard entries != recentEntries else { return }
        Self.logger.info(
            "recentEntries updated count=\(entries.count, privacy: .public)"
        )
        recentEntries = entries

        iconPreloadTask?.cancel()
        let urls = entries.prefix(12).map(\.url)
        iconPreloadTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        _ = await IconCacheService.shared
                            .loadPreviewIconAsync(forFileURL: url)
                    }
                }
            }
        }
    }
}

private nonisolated final class RecentFilesWorker: @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let queue: OperationQueue
    private let maxResults: Int
    private var observers: [NSObjectProtocol] = []
    private var callback: (@Sendable ([RecentFileEntry]) -> Void)?

    init(maxResults: Int) {
        self.maxResults = maxResults
        let queue = OperationQueue()
        queue.name = "gt.quintero.Docky.recent-files"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.queue = queue

        query.operationQueue = queue
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let oldDate = Date(timeIntervalSince1970: 0) as NSDate
        query.predicate = NSPredicate(
            format: "kMDItemLastUsedDate > %@ AND (kMDItemContentTypeTree == %@ OR kMDItemContentTypeTree LIKE[cd] %@ OR kMDItemContentTypeTree == %@)",
            oldDate,
            "public.content",
            "com.microsoft.*",
            "public.archive"
        )
        query.sortDescriptors = [
            NSSortDescriptor(
                key: NSMetadataItemLastUsedDateKey,
                ascending: false
            )
        ]
        query.notificationBatchingInterval = 1
    }

    func start(
        callback: @escaping @Sendable ([RecentFileEntry]) -> Void
    ) {
        self.callback = callback
        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            .NSMetadataQueryDidUpdate,
        ] {
            observers.append(
                center.addObserver(
                    forName: name,
                    object: query,
                    queue: queue
                ) { [weak self] _ in
                    self?.publishSnapshot()
                }
            )
        }

        queue.addOperation { [weak self] in
            _ = self?.query.start()
        }
    }

    func stop() {
        callback = nil
        let tokens = observers
        observers.removeAll()
        tokens.forEach(NotificationCenter.default.removeObserver)
        queue.addOperation { [weak self] in
            self?.query.stop()
        }
    }

    private func publishSnapshot() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let count = min(query.resultCount, maxResults)
        var entries: [RecentFileEntry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let url = url(from: item) else {
                continue
            }
            let displayName =
                item.value(
                    forAttribute: NSMetadataItemDisplayNameKey
                ) as? String
                ?? url.deletingPathExtension().lastPathComponent
            entries.append(
                RecentFileEntry(url: url, displayName: displayName)
            )
        }
        callback?(entries)
    }

    private func url(from item: NSMetadataItem) -> URL? {
        if let value = item.value(forAttribute: NSMetadataItemURLKey) {
            if let url = value as? URL { return url }
            if let nsURL = value as? NSURL { return nsURL as URL }
        }
        if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
