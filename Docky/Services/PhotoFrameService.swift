//
//  PhotoFrameService.swift
//  Docky
//
//  Backing store for the Photo Frame widget. Owns the user's chosen
//  photos as an ordered list of file bookmarks (persisted globally in
//  DockyPreferences), resolves them to URLs, decodes them lazily, and
//  publishes the frame the widget should currently show. When more than
//  one photo is configured it drives a slideshow that cross-fades
//  between frames on a timer.
//
//  Docky is not sandboxed (ENABLE_APP_SANDBOX = NO), so plain file
//  bookmarks resolve across launches with full read access — no
//  security-scoped start/stop dance is required. Photos are referenced
//  in place rather than copied, so moving or deleting a source file
//  removes it from the slideshow on the next resolve.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

nonisolated struct PhotoFrameResolvedSnapshot: Sendable {
    let urls: [URL]
    let bookmarks: [Data]
}

nonisolated enum PhotoFrameWorker {
    static func createBookmarks(for urls: [URL]) -> [Data] {
        urls.compactMap { url in
            try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    static func resolveBookmarks(
        _ sourceBookmarks: [Data]
    ) -> PhotoFrameResolvedSnapshot {
        var urls: [URL] = []
        var bookmarks: [Data] = []

        for data in sourceBookmarks {
            guard !Task.isCancelled else { break }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            if isStale, let fresh = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarks.append(fresh)
            } else {
                bookmarks.append(data)
            }
            urls.append(url)
        }

        return PhotoFrameResolvedSnapshot(
            urls: urls,
            bookmarks: bookmarks
        )
    }
}

/// Owns all full-resolution photo decoding. Requests for the same file share
/// one job, and the job chain admits at most one synchronous ImageIO decode at
/// a time. A cancelled caller releases its lease and cancels an unshared job;
/// an already-running ImageIO call cannot be interrupted, but remains bounded
/// to this single worker instead of multiplying detached decode buffers.
private actor PhotoFrameImageDecodeWorker {
    private struct Job {
        let id: UUID
        let task: Task<DecodedLocalImage?, Never>
        var consumerIDs: Set<UUID>
    }

    private struct Lease: Sendable {
        let key: String
        let jobID: UUID
        let consumerID: UUID
        let task: Task<DecodedLocalImage?, Never>
    }

    private var jobByPath: [String: Job] = [:]
    private var serialTail: Task<Void, Never>?

    func decode(at url: URL) async -> DecodedLocalImage? {
        guard !Task.isCancelled else { return nil }
        let lease = acquire(url: url)

        return await withTaskCancellationHandler {
            let decoded = await lease.task.value
            release(lease)
            guard !Task.isCancelled else { return nil }
            return decoded
        } onCancel: {
            Task {
                await self.cancel(lease)
            }
        }
    }

    private func acquire(url: URL) -> Lease {
        let key = url.standardizedFileURL.path
        let consumerID = UUID()
        if var existing = jobByPath[key],
           !existing.task.isCancelled {
            existing.consumerIDs.insert(consumerID)
            jobByPath[key] = existing
            return Lease(
                key: key,
                jobID: existing.id,
                consumerID: consumerID,
                task: existing.task
            )
        }

        let jobID = UUID()
        let predecessor = serialTail
        let task = Task.detached(
            priority: .utility
        ) { () -> DecodedLocalImage? in
            if let predecessor {
                await predecessor.value
            }
            guard !Task.isCancelled else { return nil }
            return LocalImageDecoder.decode(at: url)
        }
        serialTail = Task.detached(priority: .utility) {
            _ = await task.value
        }
        jobByPath[key] = Job(
            id: jobID,
            task: task,
            consumerIDs: [consumerID]
        )
        return Lease(
            key: key,
            jobID: jobID,
            consumerID: consumerID,
            task: task
        )
    }

    private func release(_ lease: Lease) {
        guard var job = jobByPath[lease.key],
              job.id == lease.jobID else {
            return
        }
        job.consumerIDs.remove(lease.consumerID)
        if job.consumerIDs.isEmpty {
            jobByPath.removeValue(forKey: lease.key)
        } else {
            jobByPath[lease.key] = job
        }
    }

    private func cancel(_ lease: Lease) {
        guard var job = jobByPath[lease.key],
              job.id == lease.jobID else {
            return
        }
        job.consumerIDs.remove(lease.consumerID)
        if job.consumerIDs.isEmpty {
            job.task.cancel()
            jobByPath.removeValue(forKey: lease.key)
        } else {
            jobByPath[lease.key] = job
        }
    }
}

@MainActor
final class PhotoFrameService: ObservableObject {
    static let shared = PhotoFrameService()

    /// The frame currently shown in the widget. `nil` while no photos are
    /// configured (widget shows its empty-state CTA) or before the first
    /// image finishes decoding.
    @Published private(set) var currentImage: NSImage?

    /// Number of photos in the slideshow. The widget branches on this to
    /// choose between the CTA (0) and the photo view (>0); the context
    /// menu uses it to decide whether "Clear Photos" is offered.
    @Published private(set) var photoCount: Int = 0

    /// How long each photo stays on screen before the slideshow advances.
    private let slideshowInterval: TimeInterval = 8

    /// Upper bound on eagerly decoded frame memory. A count-only cap still
    /// allowed a handful of very large photos to pin gigabytes.
    private let maximumImageCacheBytes = 256 * 1_024 * 1_024
    /// Decoded-byte accounting excludes NSImage/CGImage object overhead, so a
    /// second entry limit prevents many tiny frames from growing it without
    /// bound.
    private let maximumImageCacheCount = 16

    private let preferences = DockyPreferences.shared
    private let imageDecodeWorker = PhotoFrameImageDecodeWorker()
    private var urls: [URL] = []
    private var imageCache: [Int: DecodedLocalImage] = [:]
    private var imageCacheBytes = 0
    private var currentIndex = 0
    private var slideshowTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var bookmarkCreationTask: Task<Void, Never>?
    private struct ImageLoad {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var imageLoadByIndex: [Int: ImageLoad] = [:]
    private var reloadGeneration: UInt64 = 0
    private var configurationGeneration: UInt64 = 0

    var hasPhotos: Bool { photoCount > 0 }

    init() {
        reload()
    }

    // MARK: - Configuration

    /// Prompts the user to pick one or more image files and makes them the
    /// slideshow. Replaces the existing selection so "Choose Photos…"
    /// reads as "these are my photos now".
    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Photos")
        panel.prompt = String(localized: "Choose")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]

        // Docky runs as an accessory app; bring it forward so the panel
        // opens in front and can take key focus.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK else { return }

        configurationGeneration &+= 1
        let generation = configurationGeneration
        let selectedURLs = panel.urls
        bookmarkCreationTask?.cancel()
        bookmarkCreationTask = Task { @MainActor [weak self] in
            let bookmarks = await Task.detached(
                priority: .userInitiated
            ) {
                PhotoFrameWorker.createBookmarks(for: selectedURLs)
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.configurationGeneration == generation,
                  !bookmarks.isEmpty else {
                return
            }
            self.bookmarkCreationTask = nil
            self.preferences.photoFrameBookmarks = bookmarks
            self.reload()
        }
    }

    /// Empties the slideshow, returning the widget to its CTA state.
    func clearPhotos() {
        guard !preferences.photoFrameBookmarks.isEmpty
                || bookmarkCreationTask != nil else {
            return
        }
        configurationGeneration &+= 1
        bookmarkCreationTask?.cancel()
        bookmarkCreationTask = nil
        preferences.photoFrameBookmarks = []
        reload()
    }

    // MARK: - Slideshow

    /// Advances to the next photo immediately (also invoked by the timer).
    func advance() {
        guard urls.count > 1 else { return }
        let next = (currentIndex + 1) % urls.count
        showImage(at: next)
        preload(at: (next + 1) % urls.count)
    }

    /// Rebuilds the URL list from persisted bookmarks and restarts the
    /// slideshow. Safe to call repeatedly; the widget triggers it on
    /// appear so a fresh launch resolves bookmarks lazily.
    func reload() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let sourceBookmarks = preferences.photoFrameBookmarks
        cancelImageWork()
        reloadTask?.cancel()
        stopTimer()

        guard !sourceBookmarks.isEmpty else {
            reloadTask = nil
            applyResolvedSnapshot(
                PhotoFrameResolvedSnapshot(urls: [], bookmarks: []),
                sourceBookmarks: sourceBookmarks,
                generation: generation
            )
            return
        }

        reloadTask = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                PhotoFrameWorker.resolveBookmarks(sourceBookmarks)
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.reloadGeneration == generation else {
                return
            }
            self.reloadTask = nil
            self.applyResolvedSnapshot(
                snapshot,
                sourceBookmarks: sourceBookmarks,
                generation: generation
            )
        }
    }

    private func applyResolvedSnapshot(
        _ snapshot: PhotoFrameResolvedSnapshot,
        sourceBookmarks: [Data],
        generation: UInt64
    ) {
        guard reloadGeneration == generation else { return }

        if snapshot.bookmarks != sourceBookmarks,
           preferences.photoFrameBookmarks == sourceBookmarks {
            preferences.photoFrameBookmarks = snapshot.bookmarks
        }

        urls = snapshot.urls
        imageCache.removeAll()
        imageCacheBytes = 0
        currentIndex = 0
        photoCount = urls.count
        currentImage = nil

        guard !urls.isEmpty else {
            return
        }
        showImage(at: 0)
        if urls.count > 1 {
            preload(at: 1)
        }
        startTimerIfNeeded()
    }

    // MARK: - Image loading

    private func showImage(at index: Int) {
        guard urls.indices.contains(index) else { return }
        currentIndex = index

        if let cached = imageCache[index] {
            currentImage = cached.image
            return
        }

        // `startImageLoadIfNeeded` reuses a preload already decoding this
        // index. Completion decides whether to publish from currentIndex, so
        // changing from "next" to "current" never starts a duplicate decode.
        startImageLoadIfNeeded(at: index)
    }

    private func preload(at index: Int) {
        guard urls.indices.contains(index),
              imageCache[index] == nil else {
            return
        }
        startImageLoadIfNeeded(at: index)
    }

    private func startImageLoadIfNeeded(at index: Int) {
        guard urls.indices.contains(index),
              imageCache[index] == nil,
              imageLoadByIndex[index] == nil else {
            return
        }

        let url = urls[index]
        let generation = reloadGeneration
        let loadID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let decoded = await self.imageDecodeWorker.decode(at: url)
            guard let ownedLoad = self.imageLoadByIndex[index],
                  ownedLoad.id == loadID else {
                return
            }
            self.imageLoadByIndex.removeValue(forKey: index)

            guard !Task.isCancelled,
                  self.reloadGeneration == generation,
                  self.urls.indices.contains(index),
                  self.urls[index] == url else {
                return
            }
            guard let decoded else {
                if self.currentIndex == index {
                    self.currentImage = nil
                }
                return
            }
            self.store(decoded, at: index)
            if self.currentIndex == index {
                self.currentImage = decoded.image
            }
        }
        imageLoadByIndex[index] = ImageLoad(id: loadID, task: task)
    }

    private func store(_ decoded: DecodedLocalImage, at index: Int) {
        if let replaced = imageCache.removeValue(forKey: index) {
            imageCacheBytes -= replaced.decodedByteCost
        }
        while (
            imageCacheBytes + decoded.decodedByteCost
                > maximumImageCacheBytes
            || imageCache.count >= maximumImageCacheCount
        ),
              let evictionIndex = imageCache.keys.first(where: {
                  $0 != currentIndex && $0 != index
              }),
              let evicted = imageCache.removeValue(
                  forKey: evictionIndex
              ) {
            imageCacheBytes -= evicted.decodedByteCost
        }
        guard index == currentIndex
                || imageCacheBytes + decoded.decodedByteCost
                    <= maximumImageCacheBytes else {
            return
        }
        imageCache[index] = decoded
        imageCacheBytes += decoded.decodedByteCost
    }

    private func cancelImageWork() {
        imageLoadByIndex.values.forEach { $0.task.cancel() }
        imageLoadByIndex.removeAll()
    }

    // MARK: - Timer

    private func startTimerIfNeeded() {
        stopTimer()
        guard urls.count > 1 else { return }
        let interval = slideshowInterval
        // The class is @MainActor, so this Task inherits main-actor
        // isolation and `advance()` runs on the main thread without a hop.
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.advance()
            }
        }
    }

    private func stopTimer() {
        slideshowTask?.cancel()
        slideshowTask = nil
    }
}
