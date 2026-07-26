import CryptoKit
import Darwin
import Foundation

enum ManagedUserAssetError: Error, Equatable {
    case emptyAsset
    case assetTooLarge(maximumBytes: Int)
    case invalidSourceAsset
    case invalidManagedDirectory
    case invalidManagedAsset
}

/// Sendable boundary value for picker-driven imports. Foundation's error
/// existential is intentionally flattened before the detached task returns.
nonisolated struct ManagedUserAssetImportResult: Equatable, Sendable {
    let destinationPath: String?
    let errorDomain: String?
    let errorCode: Int?

    var succeeded: Bool {
        destinationPath != nil
    }
}

/// Coordinates picker imports and reclamation for each logical asset slot.
/// A completed import remains protected until DockyPreferences either commits
/// or abandons it, closing the gap where an older cleanup could otherwise
/// unlink a newer selection before its MainActor preference write.
private nonisolated final class ManagedUserAssetOperationCoordinator:
    @unchecked Sendable {
    static let shared = ManagedUserAssetOperationCoordinator()

    private let stateLock = NSLock()
    private let operationLock = NSLock()
    private var pendingPathCountsBySlot: [String: [String: Int]] = [:]
    private var latestCleanupPlan:
        (revision: UInt64, preservingPaths: Set<String>)?

    func withOperationLock<T>(
        forSlot _: String,
        _ operation: () throws -> T
    ) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try operation()
    }

    func registerPending(path: String, forSlot slot: String) {
        stateLock.lock()
        var counts = pendingPathCountsBySlot[slot] ?? [:]
        counts[path, default: 0] += 1
        pendingPathCountsBySlot[slot] = counts
        stateLock.unlock()
    }

    func resolvePending(path: String, forSlot slot: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var counts = pendingPathCountsBySlot[slot],
              let count = counts[path] else {
            return
        }
        if count > 1 {
            counts[path] = count - 1
            pendingPathCountsBySlot[slot] = counts
        } else {
            counts.removeValue(forKey: path)
            if counts.isEmpty {
                pendingPathCountsBySlot.removeValue(forKey: slot)
            } else {
                pendingPathCountsBySlot[slot] = counts
            }
        }
    }

    func pendingPaths(forSlot slot: String) -> Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let counts = pendingPathCountsBySlot[slot] else {
            return []
        }
        return Set(counts.keys)
    }

    func announceCleanupPlan(
        forSlot _: String,
        revision: UInt64,
        preservingPaths: Set<String>
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard latestCleanupPlan?.revision ?? 0 <= revision else {
            return
        }
        latestCleanupPlan = (
            revision: revision,
            preservingPaths: preservingPaths
        )
    }

    func preservingPaths(
        forSlot _: String,
        requestedRevision: UInt64?,
        fallback: Set<String>
    ) -> Set<String> {
        guard requestedRevision != nil else { return fallback }
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestCleanupPlan?.preservingPaths
            ?? fallback
    }

}

/// Copies explicitly selected images into Docky-owned storage while the
/// picker grant is active. Render-time accessors accept only direct children
/// of that storage directory, so stale preferences cannot probe protected
/// folders during launch or view construction.
nonisolated enum ManagedUserAssetStore {
    static let maximumAssetBytes = 50 * 1_024 * 1_024

    private struct PreparedAsset: Sendable {
        let data: Data
        let sourceExtension: String
        let maximumBytes: Int
    }

    static var directoryURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return applicationSupport
            .appendingPathComponent("Docky", isDirectory: true)
            .appendingPathComponent("UserAssets", isDirectory: true)
            .standardizedFileURL
    }

    static func managedURL(
        forPath path: String?,
        within directory: URL = directoryURL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let candidate = managedCandidateURL(
            forPath: path,
            within: directory
        ) else {
            return nil
        }
        let root = directory.standardizedFileURL
        guard fileType(at: root, fileManager: fileManager) == .typeDirectory,
              fileType(
                at: candidate,
                fileManager: fileManager
              ) == .typeRegular else {
            return nil
        }
        return candidate
    }

    /// Performs only lexical containment. Render-time preference accessors use
    /// this pure check so SwiftUI body evaluation never stats protected paths;
    /// the image worker performs the authoritative no-symlink/regular-file
    /// validation before reading any bytes.
    static func managedCandidateURL(
        forPath path: String?,
        within directory: URL = directoryURL
    ) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let root = directory.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path else {
            return nil
        }
        return candidate
    }

    static func importAsset(
        from sourceURL: URL,
        slot: String,
        into directory: URL = directoryURL,
        maximumBytes: Int = maximumAssetBytes,
        afterPublication: ((URL) throws -> Void)? = nil
    ) throws -> URL {
        let prepared = try prepareAsset(
            from: sourceURL,
            maximumBytes: maximumBytes
        )
        return try install(
            prepared,
            slot: slot,
            into: directory,
            afterPublication: afterPublication
        )
    }

    private static func install(
        _ prepared: PreparedAsset,
        slot: String,
        into directory: URL,
        afterPublication: ((URL) throws -> Void)? = nil
    ) throws -> URL {
        let directory = directory.standardizedFileURL
        let slotDigest = slotDigest(for: slot)
        let secureDirectory: SecureOwnedDirectory
        do {
            if directory.path == directoryURL.path {
                let applicationSupport = directory
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                secureDirectory =
                    try SecureOwnedDirectory.applicationSupport(
                        at: applicationSupport,
                        descending: ["Docky", "UserAssets"]
                    )
            } else {
                secureDirectory = try SecureOwnedDirectory.openOrCreate(
                    at: directory
                )
            }
        } catch {
            throw ManagedUserAssetError.invalidManagedDirectory
        }

        let contentDigest = SHA256.hash(data: prepared.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let sourceExtension = prepared.sourceExtension
        let safeExtension = sourceExtension.range(
            of: #"^[a-z0-9]{1,12}$"#,
            options: .regularExpression
        ) == nil ? "asset" : sourceExtension
        let destinationName =
            "\(slotDigest)-\(contentDigest).\(safeExtension)"
        let destination = secureDirectory.url.appendingPathComponent(
            destinationName,
            isDirectory: false
        )
        try secureDirectory.writeRegularFileAtomically(
            prepared.data,
            named: destinationName,
            maximumBytes: prepared.maximumBytes,
            afterRename: { _ in
                try afterPublication?(destination)
            }
        )
        return destination
    }

    /// Removes superseded files for one logical preference slot while
    /// preserving every path still referenced by preferences. Slot hashes
    /// make cleanup bounded to files Docky itself named for that slot; direct
    /// `unlink` avoids recursively deleting a directory if a local race swaps
    /// an entry after its type check.
    @discardableResult
    static func pruneUnreferencedAssets(
        forSlot slot: String,
        preservingPaths: Set<String>,
        within directory: URL = directoryURL,
        fileManager: FileManager = .default
    ) throws -> Int {
        let root = directory.standardizedFileURL
        guard fileType(at: root, fileManager: fileManager) == .typeDirectory
        else {
            if !fileManager.fileExists(atPath: root.path) {
                return 0
            }
            throw ManagedUserAssetError.invalidManagedDirectory
        }

        let protectedPaths = Set(
            preservingPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        )
        let prefix = "\(slotDigest(for: slot))-"
        let candidates = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        var removedCount = 0
        for candidate in candidates {
            let candidate = candidate.standardizedFileURL
            guard candidate.deletingLastPathComponent().path == root.path,
                  candidate.lastPathComponent.hasPrefix(prefix),
                  !protectedPaths.contains(candidate.path),
                  fileType(
                      at: candidate,
                      fileManager: fileManager
                  ) == .typeRegular else {
                continue
            }
            if unlink(candidate.path) == 0 {
                removedCount += 1
            }
        }
        return removedCount
    }

    /// Deletes one abandoned import only if no current preference references
    /// it. The authoritative managed-path check rejects external paths,
    /// nested entries, symlinks, and directories.
    @discardableResult
    static func removeUnreferencedAsset(
        atPath path: String,
        preservingPaths: Set<String>,
        within directory: URL = directoryURL,
        fileManager: FileManager = .default
    ) -> Bool {
        let standardizedPath =
            URL(fileURLWithPath: path).standardizedFileURL.path
        guard !preservingPaths.contains(standardizedPath),
              let candidate = managedURL(
                  forPath: standardizedPath,
                  within: directory,
                  fileManager: fileManager
              ) else {
            return false
        }
        return unlink(candidate.path) == 0
    }

    /// Performs all source reads, hashing, directory checks, and writes away
    /// from MainActor. File pickers call this after their panel has closed so
    /// importing a large image cannot stall Settings or Dock interaction.
    static func importAssetOffMain(
        from sourceURL: URL,
        slot: String,
        into directory: URL = directoryURL,
        maximumBytes: Int = maximumAssetBytes
    ) async -> ManagedUserAssetImportResult {
        let cancellation = ManagedUserAssetCancellation()
        let operation = Task.detached(priority: .userInitiated) {
            let coordinator = ManagedUserAssetOperationCoordinator.shared
            do {
                // Picker grants can point at FIFOs or very large files. Open,
                // validate, and read the selected source before contending
                // with cleanup or another slot mutation.
                let prepared = try prepareAsset(
                    from: sourceURL,
                    maximumBytes: maximumBytes,
                    cancellation: cancellation
                )
                try cancellation.check()
                return coordinator.withOperationLock(forSlot: slot) {
                    do {
                        try cancellation.check()
                        let destination = try install(
                            prepared,
                            slot: slot,
                            into: directory
                        )
                        // Registration is part of the same mutation critical
                        // section as installation. Do not add a cancellation
                        // point between them: a cancelled caller still
                        // receives the destination and resolves this lease.
                        coordinator.registerPending(
                            path: destination.path,
                            forSlot: slot
                        )
                        return ManagedUserAssetImportResult(
                            destinationPath: destination.path,
                            errorDomain: nil,
                            errorCode: nil
                        )
                    } catch {
                        return importFailure(error)
                    }
                }
            } catch {
                return importFailure(error)
            }
        }

        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            cancellation.cancel()
            operation.cancel()
        }
    }

    private static func importFailure(
        _ error: Error
    ) -> ManagedUserAssetImportResult {
        let cocoaError = error as NSError
        return ManagedUserAssetImportResult(
            destinationPath: nil,
            errorDomain: cocoaError.domain,
            errorCode: cocoaError.code
        )
    }

    private static func prepareAsset(
        from sourceURL: URL,
        maximumBytes: Int,
        cancellation: ManagedUserAssetCancellation? = nil
    ) throws -> PreparedAsset {
        PreparedAsset(
            data: try readBounded(
                from: sourceURL,
                maximumBytes: maximumBytes,
                cancellation: cancellation
            ),
            sourceExtension: sourceURL.pathExtension.lowercased(),
            maximumBytes: max(0, maximumBytes)
        )
    }

    /// Publishes the newest preference snapshot before its detached cleanup
    /// can run. Older cleanup tasks always consult this plan, so reverse task
    /// scheduling cannot unlink a path committed by a newer choice.
    static func announceCleanupPlan(
        forSlot slot: String,
        revision: UInt64,
        preservingPaths: Set<String>
    ) {
        ManagedUserAssetOperationCoordinator.shared.announceCleanupPlan(
            forSlot: slot,
            revision: revision,
            preservingPaths: preservingPaths
        )
    }

    static func pruneUnreferencedAssetsOffMain(
        forSlot slot: String,
        preservingPaths: Set<String>,
        cleanupRevision: UInt64? = nil,
        within directory: URL = directoryURL
    ) async -> Int {
        await Task.detached(priority: .utility) {
            let coordinator = ManagedUserAssetOperationCoordinator.shared
            return coordinator.withOperationLock(forSlot: slot) {
                let currentReferences = coordinator.preservingPaths(
                    forSlot: slot,
                    requestedRevision: cleanupRevision,
                    fallback: preservingPaths
                )
                let protectedPaths = currentReferences.union(
                    coordinator.pendingPaths(forSlot: slot)
                )
                return (try? pruneUnreferencedAssets(
                    forSlot: slot,
                    preservingPaths: protectedPaths,
                    within: directory
                )) ?? 0
            }
        }.value
    }

    static func resolvePendingImportOffMain(
        atPath path: String,
        forSlot slot: String,
        preservingPaths: Set<String>,
        cleanupRevision: UInt64? = nil,
        within directory: URL = directoryURL
    ) async -> Int {
        await Task.detached(priority: .utility) {
            let coordinator = ManagedUserAssetOperationCoordinator.shared
            return coordinator.withOperationLock(forSlot: slot) {
                coordinator.resolvePending(path: path, forSlot: slot)
                let currentReferences = coordinator.preservingPaths(
                    forSlot: slot,
                    requestedRevision: cleanupRevision,
                    fallback: preservingPaths
                )
                let protectedPaths = currentReferences.union(
                    coordinator.pendingPaths(forSlot: slot)
                )
                return (try? pruneUnreferencedAssets(
                    forSlot: slot,
                    preservingPaths: protectedPaths,
                    within: directory
                )) ?? 0
            }
        }.value
    }

    /// `attributesOfItem(atPath:)` reports the link itself rather than
    /// following it, allowing callers to reject direct-child symlinks.
    private static func fileType(
        at url: URL,
        fileManager: FileManager
    ) -> FileAttributeType? {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ) else {
            return nil
        }
        return attributes[.type] as? FileAttributeType
    }

    private static func slotDigest(for slot: String) -> String {
        SHA256.hash(data: Data(slot.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func readBounded(
        from sourceURL: URL,
        maximumBytes: Int,
        cancellation: ManagedUserAssetCancellation?
    ) throws -> Data {
        try cancellation?.check()
        let descriptor = sourceURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ManagedUserAssetError.invalidSourceAsset
            }
            throw posixError(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError(errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else {
            throw ManagedUserAssetError.invalidSourceAsset
        }

        let boundedMaximum = max(0, maximumBytes)
        guard metadata.st_size <= off_t(boundedMaximum) else {
            throw ManagedUserAssetError.assetTooLarge(
                maximumBytes: boundedMaximum
            )
        }

        var data = Data()
        if metadata.st_size > 0 {
            data.reserveCapacity(Int(metadata.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellation?.check()
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if readCount == 0 {
                break
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw posixError(errno)
            }

            let count = Int(readCount)
            guard count <= boundedMaximum - data.count else {
                throw ManagedUserAssetError.assetTooLarge(
                    maximumBytes: boundedMaximum
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        try cancellation?.check()
        guard !data.isEmpty else {
            throw ManagedUserAssetError.emptyAsset
        }
        return data
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private nonisolated final class ManagedUserAssetCancellation:
    @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }
}
