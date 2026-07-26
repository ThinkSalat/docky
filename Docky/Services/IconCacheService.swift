//
//  IconCacheService.swift
//  Docky
//
//  In-memory cache for icons surfaced in tiles. Wraps NSCache so eviction
//  under memory pressure is handled by the OS. `NSWorkspace.icon(forFile:)`
//  itself is fast but SwiftUI re-reads the icon every view update — caching
//  avoids repeated LaunchServices hops and redundant NSImage wrapping.
//

import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let dockyImageCacheDidInvalidate = Notification.Name(
        "gt.quintero.Docky.imageCacheDidInvalidate"
    )
}

final class IconCacheService {
    static let shared = IconCacheService()

    private struct PendingImageLoad {
        let id: UUID
        let generation: UInt64
        let task: Task<DecodedLocalImage?, Never>
    }

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 256 * 1_024 * 1_024
        return cache
    }()
    private let pendingImageLoadsLock = NSLock()
    private var pendingImageLoads: [String: PendingImageLoad] = [:]
    private var imageLoadGeneration: UInt64 = 0

    /// Nominal point size stamped onto every icon fetched from LaunchServices.
    /// `NSWorkspace.icon(forFile:)` returns a multi-representation image whose
    /// logical `size` is only 32x32, so `Image(nsImage:).resizable()` rasterizes
    /// at that nominal size and then upscales it into the tile — which is what
    /// made icons look blurry next to the native Dock (the native Dock draws
    /// straight from the 512px representation). Stamping a large nominal size
    /// makes SwiftUI select a high-resolution representation and downsample it
    /// instead. The representations stay lazy, so this does not eagerly allocate
    /// a bitmap per icon.
    ///
    /// 256 is the smallest standard `.icns` representation that still covers the
    /// largest size a tile is ever drawn at (a magnified tile tops out around
    /// ~192px), so every dock surface downsamples rather than upscales. Going
    /// higher (512/1024) would decode a source bitmap 4x larger for no visible
    /// gain in the dock and extra per-frame resampling work during magnification.
    nonisolated private static let normalizedIconExtent: CGFloat = 256

    private init() {}

    /// Fetches an icon from LaunchServices and normalizes its nominal size so
    /// downstream `resizable()` rendering downsamples a high-resolution
    /// representation rather than upscaling the default 32pt one. See
    /// `normalizedIconExtent`.
    nonisolated private static func workspaceIcon(forFile path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: normalizedIconExtent, height: normalizedIconExtent)
        return image
    }

    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage {
        let key = "bundle:\(bundleIdentifier)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = loadIcon(forBundleIdentifier: bundleIdentifier)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Synchronously returns the cached icon if present, without
    /// triggering a LaunchServices fetch. Use this to render hot
    /// icons inline and fall back to `loadIconAsync(forBundleIdentifier:)`
    /// for cold entries so the main thread never blocks on disk I/O.
    func cachedIcon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        let key = "bundle:\(bundleIdentifier)" as NSString
        return cache.object(forKey: key)
    }

    /// Loads the icon on a background priority and stores the result
    /// in the cache. NSWorkspace.icon is thread-safe and NSCache is
    /// thread-safe, so the load can run anywhere.
    func loadIconAsync(forBundleIdentifier bundleIdentifier: String) async -> NSImage {
        let key = "bundle:\(bundleIdentifier)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return await Task.detached(priority: .userInitiated) { [cache] in
            let image: NSImage
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                image = Self.workspaceIcon(forFile: url.path)
            } else {
                image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
            }
            cache.setObject(image, forKey: key)
            return image
        }.value
    }

    /// Decodes a configured image override away from MainActor. Native menus
    /// use the cached-only accessor while tracking and start this preload
    /// before presentation, so a cold custom icon can never stall a click.
    func loadImageAsync(forImageFileURL url: URL) async -> NSImage? {
        guard url.isFileURL else { return nil }

        let path = url.standardizedFileURL.path
        let key = "image:\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let pending = pendingImageLoad(path: path, url: url)
        let decoded = await pending.task.value
        return finishPendingImageLoad(
            path: path,
            key: key,
            pending: pending,
            decoded: decoded
        )
    }

    /// Cached-only counterpart to `loadImageAsync`. SwiftUI render paths use
    /// this accessor for their immediate frame, then schedule a background
    /// decode for a cold image rather than touching the filesystem inline.
    func cachedImage(forImageFileURL url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        return cache.object(forKey: "image:\(path)" as NSString)
    }

    func icon(forFileURL url: URL) -> NSImage {
        let path = Self.normalizedPath(for: url)
        let key = "path:\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = Self.workspaceIcon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Returns an already-loaded preview or file icon without reading the file
    /// or asking LaunchServices to inspect its path. Protected-folder tiles
    /// use this during dock render.
    func cachedIcon(forFileURL url: URL) -> NSImage? {
        let path = Self.normalizedPath(for: url)
        let imageKey = "image:\(path)" as NSString
        if let cachedImage = cache.object(forKey: imageKey) {
            return cachedImage
        }

        let iconKey = "path:\(path)" as NSString
        return cache.object(forKey: iconKey)
    }

    func preloadIcon(forBundleIdentifier bundleIdentifier: String, fileURL: URL) {
        let key = "bundle:\(bundleIdentifier)" as NSString
        cache.setObject(Self.workspaceIcon(forFile: fileURL.path), forKey: key)
    }

    func previewIcon(forFileURL url: URL) -> NSImage {
        if Self.isImageFileURL(url),
           let image = image(forImageFileURL: url) {
            return image
        }

        return icon(forFileURL: url)
    }

    /// Loads a cold file preview away from MainActor. Folder grids render an
    /// immediate cached/generic image and await this method, so cloud metadata,
    /// image decoding, and LaunchServices cannot freeze dock interaction.
    func loadPreviewIconAsync(forFileURL url: URL) async -> NSImage {
        let path = Self.normalizedPath(for: url)
        let imageKey = "image:\(path)" as NSString
        if let cachedImage = cache.object(forKey: imageKey) {
            return cachedImage
        }

        return await Task.detached(
            priority: .userInitiated
        ) { [cache] in
            if Self.isImageFileURLOffMain(url),
               let decoded = LocalImageDecoder.decode(at: url) {
                cache.setObject(
                    decoded.image,
                    forKey: imageKey,
                    cost: decoded.decodedByteCost
                )
                return decoded.image
            }

            let iconKey = "path:\(path)" as NSString
            if let cached = cache.object(forKey: iconKey) {
                return cached
            }
            let image = Self.workspaceIcon(forFile: path)
            cache.setObject(image, forKey: iconKey)
            return image
        }.value
    }

    func image(forImageFileURL url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        let key = "image:\(url.standardizedFileURL.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let decoded = LocalImageDecoder.decode(at: url) else {
            return nil
        }
        cache.setObject(
            decoded.image,
            forKey: key,
            cost: decoded.decodedByteCost
        )
        return decoded.image
    }

    func invalidate() {
        pendingImageLoadsLock.lock()
        imageLoadGeneration &+= 1
        let pending = pendingImageLoads.values.map(\.task)
        pendingImageLoads.removeAll()
        pendingImageLoadsLock.unlock()
        pending.forEach { $0.cancel() }
        cache.removeAllObjects()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .dockyImageCacheDidInvalidate,
                object: nil
            )
        }
    }

    private func loadIcon(forBundleIdentifier bundleIdentifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return Self.workspaceIcon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }

    private func pendingImageLoad(
        path: String,
        url: URL
    ) -> PendingImageLoad {
        pendingImageLoadsLock.lock()
        if let pending = pendingImageLoads[path] {
            pendingImageLoadsLock.unlock()
            return pending
        }

        let pending = PendingImageLoad(
            id: UUID(),
            generation: imageLoadGeneration,
            task: Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else {
                    return nil
                }
                return LocalImageDecoder.decode(at: url)
            }
        )
        pendingImageLoads[path] = pending
        pendingImageLoadsLock.unlock()
        return pending
    }

    private func finishPendingImageLoad(
        path: String,
        key: NSString,
        pending: PendingImageLoad,
        decoded: DecodedLocalImage?
    ) -> NSImage? {
        pendingImageLoadsLock.lock()
        defer { pendingImageLoadsLock.unlock() }

        guard imageLoadGeneration == pending.generation else {
            return nil
        }

        // Every waiter for the same path shares this task. Only the first
        // waiter owns cleanup/cache publication; later waiters must still
        // receive the value that first waiter published instead of treating
        // the removed pending entry as a stale request.
        if pendingImageLoads[path]?.id == pending.id {
            pendingImageLoads.removeValue(forKey: path)
            if let decoded {
                cache.setObject(
                    decoded.image,
                    forKey: key,
                    cost: decoded.decodedByteCost
                )
            }
            return decoded?.image
        }
        // The task result is authoritative for every waiter. NSCache may
        // evict between resumptions, so a cache lookup could turn the same
        // successful shared decode into nil for a later caller.
        return decoded?.image
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        isImageFileURLOffMain(url)
    }

    nonisolated private static func isImageFileURLOffMain(
        _ url: URL
    ) -> Bool {
        guard url.isFileURL else {
            return false
        }

        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        guard values?.isDirectory != true else {
            return false
        }

        if let contentType = values?.contentType {
            return contentType.conforms(to: .image)
        }

        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    nonisolated private static func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
