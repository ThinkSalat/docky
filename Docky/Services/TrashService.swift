//
//  TrashService.swift
//  Docky
//

import AppKit
import Combine
import Dispatch
import Foundation

final class TrashService: ObservableObject {
    static let shared = TrashService()

    @Published private(set) var isEmpty = true

    private let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    private let worker = TrashFilesystemWorker()
    private var trashSource: DispatchSourceFileSystemObject?
    private var refreshGeneration: UInt64 = 0
    private var watcherGeneration: UInt64 = 0

    private init() {
        refresh()
        startWatchingTrashDirectory()
    }

    deinit {
        trashSource?.cancel()
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let empty = await worker.isEmpty(trashURL)
            guard !Task.isCancelled,
                  refreshGeneration == generation else {
                return
            }
            isEmpty = empty
        }
    }

    private func startWatchingTrashDirectory() {
        watcherGeneration &+= 1
        let generation = watcherGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let descriptor = await worker.openWatcher(trashURL)
            guard !Task.isCancelled,
                  watcherGeneration == generation,
                  descriptor >= 0 else {
                if descriptor >= 0 {
                    close(descriptor)
                }
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: DispatchQueue.main
            )
            source.setEventHandler { [weak self] in
                self?.refresh()
            }
            source.setCancelHandler { [descriptor] in
                close(descriptor)
            }
            trashSource = source
            source.resume()
        }
    }
}

/// Keeps even the first directory read and vnode descriptor open off the UI
/// actor. Trash can contain thousands of entries or live on a slow home
/// volume; neither condition should delay dock clicks.
private nonisolated final class TrashFilesystemWorker:
    @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "gt.quintero.Docky.trash-filesystem",
        qos: .utility,
        attributes: .concurrent
    )

    func isEmpty(_ trashURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let enumerator = FileManager.default.enumerator(
                    at: trashURL,
                    includingPropertiesForKeys: nil,
                    options: [
                        .skipsHiddenFiles,
                        .skipsPackageDescendants,
                    ]
                )
                continuation.resume(returning: enumerator?.nextObject() == nil)
            }
        }
    }

    func openWatcher(_ trashURL: URL) async -> CInt {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: open(
                        trashURL.path,
                        O_EVTONLY | O_CLOEXEC
                    )
                )
            }
        }
    }
}
