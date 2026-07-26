//
//  CachedAsyncImageFile.swift
//  Docky
//
//  Renders a local image from the shared cache immediately and moves a cold
//  decode off MainActor. This keeps SwiftUI body evaluation free of file I/O.
//

import AppKit
import Combine
import SwiftUI

struct CachedAsyncImageFile<Content: View, Placeholder: View>: View {
    private struct LoadedImage {
        let key: String
        let image: NSImage
    }

    let url: URL?
    @ViewBuilder let content: (NSImage) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: LoadedImage?
    @State private var requestGeneration: UInt64 = 0
    @State private var cacheRevision: UInt64 = 0

    init(
        url: URL?,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder content: @escaping (NSImage) -> Content
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        let initialKey = Self.cacheKey(for: url).map { "\($0)#0" }
        let initialImage = url.flatMap {
            IconCacheService.shared.cachedImage(forImageFileURL: $0)
        }
        _loadedImage = State(
            initialValue: initialKey.flatMap { key in
                initialImage.map { LoadedImage(key: key, image: $0) }
            }
        )
    }

    var body: some View {
        Group {
            if let loadedImage, loadedImage.key == requestKey {
                content(loadedImage.image)
            } else {
                placeholder()
            }
        }
        .task(id: requestKey) {
            requestGeneration &+= 1
            let generation = requestGeneration
            guard let url, let requestedKey = requestKey else {
                loadedImage = nil
                return
            }

            if let cached = IconCacheService.shared.cachedImage(
                forImageFileURL: url
            ) {
                loadedImage = LoadedImage(key: requestedKey, image: cached)
                return
            }

            if loadedImage?.key != requestedKey {
                loadedImage = nil
            }
            let loaded = await IconCacheService.shared.loadImageAsync(
                forImageFileURL: url
            )
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  let loaded else {
                return
            }
            loadedImage = LoadedImage(key: requestedKey, image: loaded)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .dockyImageCacheDidInvalidate
            )
        ) { _ in
            loadedImage = nil
            cacheRevision &+= 1
        }
    }

    private var cacheKey: String? {
        Self.cacheKey(for: url)
    }

    private var requestKey: String? {
        cacheKey.map { "\($0)#\(cacheRevision)" }
    }

    private static func cacheKey(for url: URL?) -> String? {
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }
}

extension CachedAsyncImageFile where Placeholder == EmptyView {
    init(
        url: URL?,
        @ViewBuilder content: @escaping (NSImage) -> Content
    ) {
        self.init(url: url, placeholder: { EmptyView() }, content: content)
    }
}

struct CachedAsyncAppImage<Content: View, Placeholder: View>: View {
    private struct LoadedImage {
        let key: String
        let image: NSImage
    }

    let bundleIdentifier: String
    let overrideURL: URL?
    @ViewBuilder let content: (NSImage) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: LoadedImage?
    @State private var requestGeneration: UInt64 = 0
    @State private var cacheRevision: UInt64 = 0

    init(
        bundleIdentifier: String,
        overrideURL: URL?,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder content: @escaping (NSImage) -> Content
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.overrideURL = overrideURL
        self.placeholder = placeholder
        self.content = content

        let baseKey = Self.baseKey(
            bundleIdentifier: bundleIdentifier,
            overrideURL: overrideURL
        )
        let cached = overrideURL.flatMap {
            IconCacheService.shared.cachedImage(forImageFileURL: $0)
        } ?? IconCacheService.shared.cachedIcon(
            forBundleIdentifier: bundleIdentifier
        )
        _loadedImage = State(
            initialValue: cached.map {
                LoadedImage(key: "\(baseKey)#0", image: $0)
            }
        )
    }

    var body: some View {
        Group {
            if let loadedImage, loadedImage.key == requestKey {
                content(loadedImage.image)
            } else {
                placeholder()
            }
        }
        .task(id: requestKey) {
            requestGeneration &+= 1
            let generation = requestGeneration
            let key = requestKey

            let image: NSImage?
            if let overrideURL {
                if let cached = IconCacheService.shared.cachedImage(
                    forImageFileURL: overrideURL
                ) {
                    image = cached
                } else {
                    image = await IconCacheService.shared.loadImageAsync(
                        forImageFileURL: overrideURL
                    )
                }
            } else if let cached = IconCacheService.shared.cachedIcon(
                forBundleIdentifier: bundleIdentifier
            ) {
                image = cached
            } else {
                image = await IconCacheService.shared.loadIconAsync(
                    forBundleIdentifier: bundleIdentifier
                )
            }

            guard !Task.isCancelled,
                  requestGeneration == generation,
                  let image else {
                return
            }
            loadedImage = LoadedImage(key: key, image: image)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .dockyImageCacheDidInvalidate
            )
        ) { _ in
            loadedImage = nil
            cacheRevision &+= 1
        }
    }

    private var requestKey: String {
        "\(Self.baseKey(bundleIdentifier: bundleIdentifier, overrideURL: overrideURL))#\(cacheRevision)"
    }

    private static func baseKey(
        bundleIdentifier: String,
        overrideURL: URL?
    ) -> String {
        let overridePath = overrideURL?.standardizedFileURL.path ?? ""
        return "\(bundleIdentifier)|\(overridePath)"
    }
}

struct CachedAsyncFileImage<Content: View, Placeholder: View>: View {
    private struct LoadedImage {
        let key: String
        let image: NSImage
    }

    let url: URL
    @ViewBuilder let content: (NSImage) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: LoadedImage?
    @State private var requestGeneration: UInt64 = 0
    @State private var cacheRevision: UInt64 = 0

    init(
        url: URL,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder content: @escaping (NSImage) -> Content
    ) {
        self.url = url
        self.placeholder = placeholder
        self.content = content

        let key = "\(url.standardizedFileURL.path)#0"
        _loadedImage = State(
            initialValue: IconCacheService.shared.cachedIcon(
                forFileURL: url
            ).map { LoadedImage(key: key, image: $0) }
        )
    }

    var body: some View {
        Group {
            if let loadedImage, loadedImage.key == requestKey {
                content(loadedImage.image)
            } else {
                placeholder()
            }
        }
        .task(id: requestKey) {
            requestGeneration &+= 1
            let generation = requestGeneration
            let key = requestKey
            let image: NSImage
            if let cached = IconCacheService.shared.cachedIcon(
                forFileURL: url
            ) {
                image = cached
            } else {
                image = await IconCacheService.shared.loadPreviewIconAsync(
                    forFileURL: url
                )
            }

            guard !Task.isCancelled,
                  requestGeneration == generation else {
                return
            }
            loadedImage = LoadedImage(key: key, image: image)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .dockyImageCacheDidInvalidate
            )
        ) { _ in
            loadedImage = nil
            cacheRevision &+= 1
        }
    }

    private var requestKey: String {
        "\(url.standardizedFileURL.path)#\(cacheRevision)"
    }
}
