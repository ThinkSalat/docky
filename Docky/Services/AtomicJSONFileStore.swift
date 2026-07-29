//
//  AtomicJSONFileStore.swift
//  Docky
//
//  Small hostless persistence primitive used for state that must survive a
//  crash without exposing a partially-written document. The primary and
//  backup are complete JSON documents; callers provide semantic validation.
//
//  Before a replacement is renamed into place, its contents and metadata are
//  synchronized with F_FULLFSYNC (or fsync when the filesystem does not
//  support F_FULLFSYNC). After the atomic rename, the parent directory is
//  synchronized on a best-effort basis. A post-rename directory-sync failure
//  is deliberately not reported: the replacement is already authoritative
//  and cannot be rolled back safely. Consequently, all supported filesystems
//  get process-crash atomicity; filesystems supporting the full file and
//  directory sync sequence additionally get the strongest sudden-power-loss
//  durability macOS exposes.
//

import Foundation
import Darwin

// Swift imports Darwin's `struct flock` under the same qualified name as the
// BSD `flock(2)` function, so `Darwin.flock(...)` resolves to the struct in
// Swift 6. Bind the stable libc symbol under an unambiguous Swift name.
@_silgen_name("flock")
nonisolated private func dockyFileLock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

nonisolated enum SecureOwnedStorageError: Error, LocalizedError {
    case invalidDirectoryURL(String)
    case invalidPathComponent(String)
    case invalidFileName(String)
    case entryAlreadyExists(String)
    case unexpectedType(String)
    case unexpectedOwner(String)
    case unexpectedLinkCount(String)
    case fileTooLarge(name: String, maximumBytes: Int)
    case writeTooLarge(name: String, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidDirectoryURL:
            return "The secure-storage directory URL is invalid."
        case .invalidPathComponent:
            return "A secure-storage path component is invalid."
        case .invalidFileName:
            return "A secure-storage file name is invalid."
        case .entryAlreadyExists:
            return "A secure-storage entry already exists."
        case .unexpectedType:
            return "A secure-storage entry has an unexpected file type."
        case .unexpectedOwner:
            return "A secure-storage entry is not owned by the current user."
        case .unexpectedLinkCount:
            return "A secure-storage file is not uniquely linked."
        case .fileTooLarge(_, let maximumBytes):
            return "A secure-storage file exceeds the \(maximumBytes)-byte limit."
        case .writeTooLarge(_, let maximumBytes):
            return "A secure-storage write exceeds the \(maximumBytes)-byte limit."
        }
    }
}

/// Retains a verified directory descriptor and performs every child operation
/// relative to it. Production callers anchor this under the canonical user
/// Application Support directory; tests can anchor an isolated temporary
/// directory without weakening the production path.
nonisolated final class SecureOwnedDirectory: @unchecked Sendable {
    let url: URL

    private let descriptor: Int32
    private let ownerUID: uid_t
    private let transactionLock = NSLock()

    private init(url: URL, descriptor: Int32, ownerUID: uid_t) {
        self.url = url
        self.descriptor = descriptor
        self.ownerUID = ownerUID
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    static func applicationSupport(
        at applicationSupportURL: URL,
        descending components: [String]
    ) throws -> SecureOwnedDirectory {
        let canonicalURL = try canonicalExistingDirectoryURL(
            applicationSupportURL
        )
        let rootDescriptor = try openCanonicalDirectoryTree(
            at: canonicalURL,
            ownerUID: getuid()
        )
        return try descend(
            from: rootDescriptor,
            rootURL: canonicalURL,
            components: components,
            ownerUID: getuid(),
            secureRootMode: false
        )
    }

    /// Test/injection entry point. The nearest existing lexical ancestor is
    /// opened without following its final component, and every missing
    /// descendant is then created and opened with `mkdirat`/`openat`.
    static func openOrCreate(
        at directoryURL: URL
    ) throws -> SecureOwnedDirectory {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/") else {
            throw SecureOwnedStorageError.invalidDirectoryURL(
                directoryURL.path
            )
        }

        let targetURL = directoryURL.standardizedFileURL
        var existingAncestor = targetURL
        var missingComponents: [String] = []

        while !(try pathEntryExists(at: existingAncestor)) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                throw SecureOwnedStorageError.invalidDirectoryURL(
                    targetURL.path
                )
            }
            let component = existingAncestor.lastPathComponent
            try validateComponent(component)
            missingComponents.insert(component, at: 0)
            existingAncestor = parent
        }

        let rootDescriptor = try openVerifiedDirectory(
            at: existingAncestor,
            ownerUID: getuid()
        )
        return try descend(
            from: rootDescriptor,
            rootURL: existingAncestor,
            components: missingComponents,
            ownerUID: getuid(),
            secureRootMode: missingComponents.isEmpty
        )
    }

    func entryExists(named name: String) throws -> Bool {
        try validateFileName(name)
        return try metadataIfPresent(named: name) != nil
    }

    /// Serializes a complete multi-file transaction across every Docky process
    /// that has opened this directory. Locking the retained directory inode
    /// avoids a replaceable lock-file path and covers primary, backup, archive,
    /// and quarantine operations as one critical section.
    func withExclusiveLock<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        // flock locks belong to an open-file description, so a second thread
        // using this exact retained descriptor could otherwise re-enter the
        // lock. Pair it with a process-local mutex before taking the
        // cross-process inode lock.
        transactionLock.lock()
        defer { transactionLock.unlock() }

        while dockyFileLock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw Self.posixError(errno, path: url.path)
            }
        }
        defer {
            while dockyFileLock(descriptor, LOCK_UN) != 0,
                  errno == EINTR {}
        }
        return try body()
    }

    func readRegularFile(
        named name: String,
        maximumBytes: Int
    ) throws -> Data? {
        try validateFileName(name)
        guard maximumBytes >= 0 else {
            throw SecureOwnedStorageError.fileTooLarge(
                name: name,
                maximumBytes: maximumBytes
            )
        }

        let fileDescriptor = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileDescriptor >= 0 else {
            let errorCode = errno
            if errorCode == ENOENT {
                return nil
            }
            throw Self.posixError(
                errorCode,
                path: url.appendingPathComponent(name).path
            )
        }
        defer { _ = Darwin.close(fileDescriptor) }

        let metadata = try verifiedRegularFileMetadata(
            descriptor: fileDescriptor,
            name: name
        )
        guard metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            throw SecureOwnedStorageError.fileTooLarge(
                name: name,
                maximumBytes: maximumBytes
            )
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](
            repeating: 0,
            count: min(64 * 1_024, max(maximumBytes + 1, 1))
        )
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    fileDescriptor,
                    $0.baseAddress,
                    $0.count
                )
            }
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw Self.posixError(
                    errno,
                    path: url.appendingPathComponent(name).path
                )
            }
            guard data.count <= maximumBytes - count else {
                throw SecureOwnedStorageError.fileTooLarge(
                    name: name,
                    maximumBytes: maximumBytes
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func writeRegularFileAtomically(
        _ data: Data,
        named name: String,
        maximumBytes: Int,
        beforeSynchronize: ((URL) throws -> Void)? = nil,
        afterRename: ((URL) throws -> Void)? = nil,
        replaceExisting: Bool = true
    ) throws {
        try validateFileName(name)
        guard data.count <= maximumBytes else {
            throw SecureOwnedStorageError.writeTooLarge(
                name: name,
                maximumBytes: maximumBytes
            )
        }

        // Reject a symlink, directory, device, or foreign-owned destination
        // rather than letting renameat silently replace it.
        if let metadata = try metadataIfPresent(named: name) {
            try verifyRegularFileMetadata(metadata, name: name)
            guard replaceExisting else {
                throw SecureOwnedStorageError.entryAlreadyExists(name)
            }
        }

        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let temporaryURL = url.appendingPathComponent(temporaryName)
        let temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw Self.posixError(errno, path: temporaryURL.path)
        }

        var didRename = false
        defer {
            _ = Darwin.close(temporaryDescriptor)
            if !didRename {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(descriptor, $0, 0)
                }
            }
        }

        _ = try verifiedRegularFileMetadata(
            descriptor: temporaryDescriptor,
            name: temporaryName
        )
        guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
            throw Self.posixError(errno, path: temporaryURL.path)
        }
        try Self.writeAll(data, to: temporaryDescriptor, path: temporaryURL.path)
        try beforeSynchronize?(temporaryURL)
        try Self.synchronizeFileDescriptor(
            temporaryDescriptor,
            path: temporaryURL.path
        )

        // Re-check the destination immediately before publication. The
        // directory is private and retained, so other users cannot race this
        // name between validation and rename.
        if let metadata = try metadataIfPresent(named: name) {
            try verifyRegularFileMetadata(metadata, name: name)
            guard replaceExisting else {
                throw SecureOwnedStorageError.entryAlreadyExists(name)
            }
        }
        let renameResult = temporaryName.withCString { sourceName in
            name.withCString { destinationName in
                if replaceExisting {
                    Darwin.renameat(
                        descriptor,
                        sourceName,
                        descriptor,
                        destinationName
                    )
                } else {
                    Darwin.renameatx_np(
                        descriptor,
                        sourceName,
                        descriptor,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard renameResult == 0 else {
            throw Self.posixError(
                errno,
                path: url.appendingPathComponent(name).path
            )
        }
        didRename = true

        // The rename is the commit point. Directory synchronization is
        // best-effort because reporting failure after publication would make
        // the caller's in-memory state diverge from the committed file.
        try? afterRename?(url)
        try? synchronizeDirectory()
    }

    /// Appends one entry without following a final symlink. Returns false
    /// when the current generation must be rotated before the append.
    func appendRegularFile(
        _ data: Data,
        named name: String,
        maximumBytes: Int
    ) throws -> Bool {
        try validateFileName(name)
        guard data.count <= maximumBytes else {
            throw SecureOwnedStorageError.writeTooLarge(
                name: name,
                maximumBytes: maximumBytes
            )
        }

        let fileURL = url.appendingPathComponent(name)
        let fileDescriptor = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC
                    | O_NOFOLLOW | O_NONBLOCK,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            throw Self.posixError(errno, path: fileURL.path)
        }
        defer { _ = Darwin.close(fileDescriptor) }

        let metadata = try verifiedRegularFileMetadata(
            descriptor: fileDescriptor,
            name: name
        )
        guard metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            throw SecureOwnedStorageError.fileTooLarge(
                name: name,
                maximumBytes: maximumBytes
            )
        }
        let currentSize = Int(metadata.st_size)
        guard currentSize <= maximumBytes - data.count else {
            return false
        }
        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            throw Self.posixError(errno, path: fileURL.path)
        }
        try Self.writeAll(data, to: fileDescriptor, path: fileURL.path)
        return true
    }

    func rotateRegularFile(
        from sourceName: String,
        to destinationName: String
    ) throws {
        try validateFileName(sourceName)
        try validateFileName(destinationName)

        guard let sourceMetadata = try metadataIfPresent(named: sourceName)
        else {
            return
        }
        try verifyRegularFileMetadata(sourceMetadata, name: sourceName)
        if let destinationMetadata =
            try metadataIfPresent(named: destinationName) {
            try verifyRegularFileMetadata(
                destinationMetadata,
                name: destinationName
            )
        }

        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameat(
                    descriptor,
                    source,
                    descriptor,
                    destination
                )
            }
        }
        guard result == 0 else {
            throw Self.posixError(
                errno,
                path: url.appendingPathComponent(destinationName).path
            )
        }
        try? synchronizeDirectory()
    }

    private func metadataIfPresent(named name: String) throws -> stat? {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(
                descriptor,
                $0,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            return metadata
        }
        let errorCode = errno
        if errorCode == ENOENT {
            return nil
        }
        throw Self.posixError(
            errorCode,
            path: url.appendingPathComponent(name).path
        )
    }

    private func verifiedRegularFileMetadata(
        descriptor fileDescriptor: Int32,
        name: String
    ) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0 else {
            throw Self.posixError(
                errno,
                path: url.appendingPathComponent(name).path
            )
        }
        try verifyRegularFileMetadata(metadata, name: name)
        return metadata
    }

    private func verifyRegularFileMetadata(
        _ metadata: stat,
        name: String
    ) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw SecureOwnedStorageError.unexpectedType(name)
        }
        guard metadata.st_uid == ownerUID else {
            throw SecureOwnedStorageError.unexpectedOwner(name)
        }
        guard metadata.st_nlink == 1 else {
            throw SecureOwnedStorageError.unexpectedLinkCount(name)
        }
    }

    private func synchronizeDirectory() throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.posixError(errno, path: url.path)
        }
    }

    private static func descend(
        from rootDescriptor: Int32,
        rootURL: URL,
        components: [String],
        ownerUID: uid_t,
        secureRootMode: Bool
    ) throws -> SecureOwnedDirectory {
        var currentDescriptor = rootDescriptor
        var currentURL = rootURL
        var ownsCurrentDescriptor = true

        do {
            if secureRootMode {
                guard Darwin.fchmod(
                    currentDescriptor,
                    mode_t(0o700)
                ) == 0 else {
                    throw posixError(errno, path: currentURL.path)
                }
            }

            for component in components {
                try validateComponent(component)
                let createResult = component.withCString {
                    Darwin.mkdirat(
                        currentDescriptor,
                        $0,
                        mode_t(0o700)
                    )
                }
                if createResult != 0, errno != EEXIST {
                    throw posixError(
                        errno,
                        path: currentURL.appendingPathComponent(component).path
                    )
                }

                let childDescriptor = component.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    throw posixError(
                        errno,
                        path: currentURL.appendingPathComponent(component).path
                    )
                }
                do {
                    try verifyDirectoryDescriptor(
                        childDescriptor,
                        path: currentURL
                            .appendingPathComponent(component).path,
                        ownerUID: ownerUID
                    )
                    guard Darwin.fchmod(
                        childDescriptor,
                        mode_t(0o700)
                    ) == 0 else {
                        throw posixError(
                            errno,
                            path: currentURL
                                .appendingPathComponent(component).path
                        )
                    }
                } catch {
                    _ = Darwin.close(childDescriptor)
                    throw error
                }

                _ = Darwin.close(currentDescriptor)
                currentDescriptor = childDescriptor
                currentURL.appendPathComponent(component, isDirectory: true)
            }

            ownsCurrentDescriptor = false
            return SecureOwnedDirectory(
                url: currentURL,
                descriptor: currentDescriptor,
                ownerUID: ownerUID
            )
        } catch {
            if ownsCurrentDescriptor {
                _ = Darwin.close(currentDescriptor)
            }
            throw error
        }
    }

    private static func openVerifiedDirectory(
        at url: URL,
        ownerUID: uid_t
    ) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw posixError(errno, path: url.path)
        }
        do {
            try verifyDirectoryDescriptor(
                descriptor,
                path: url.path,
                ownerUID: ownerUID
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Opens every component of an already-canonical absolute path relative to
    /// the previously-verified directory descriptor. This closes the
    /// realpath/open gap where an intermediate component could otherwise be
    /// replaced with a symlink after canonicalization.
    private static func openCanonicalDirectoryTree(
        at url: URL,
        ownerUID: uid_t
    ) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SecureOwnedStorageError.invalidDirectoryURL(url.path)
        }

        var currentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw posixError(errno, path: "/")
        }

        let components = url.pathComponents.dropFirst()
        var currentPath = ""
        do {
            for (index, component) in components.enumerated() {
                try validateComponent(component)
                currentPath += "/\(component)"
                let childDescriptor = component.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    throw posixError(errno, path: currentPath)
                }
                do {
                    try verifyDirectoryDescriptor(
                        childDescriptor,
                        path: currentPath,
                        ownerUID:
                            index == components.count - 1
                            ? ownerUID
                            : nil
                    )
                } catch {
                    _ = Darwin.close(childDescriptor)
                    throw error
                }
                _ = Darwin.close(currentDescriptor)
                currentDescriptor = childDescriptor
            }
            return currentDescriptor
        } catch {
            _ = Darwin.close(currentDescriptor)
            throw error
        }
    }

    private static func verifyDirectoryDescriptor(
        _ descriptor: Int32,
        path: String,
        ownerUID: uid_t?
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError(errno, path: path)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw SecureOwnedStorageError.unexpectedType(path)
        }
        guard ownerUID == nil || metadata.st_uid == ownerUID else {
            throw SecureOwnedStorageError.unexpectedOwner(path)
        }
    }

    private static func canonicalExistingDirectoryURL(
        _ url: URL
    ) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SecureOwnedStorageError.invalidDirectoryURL(url.path)
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedPath: String? = url.path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                guard Darwin.realpath(
                    source,
                    destination.baseAddress
                ) != nil else {
                    return nil
                }
                return String(cString: destination.baseAddress!)
            }
        }
        guard let resolvedPath else {
            throw posixError(errno, path: url.path)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func pathEntryExists(at url: URL) throws -> Bool {
        var metadata = stat()
        let result = url.path.withCString {
            Darwin.lstat($0, &metadata)
        }
        if result == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw posixError(errno, path: url.path)
    }

    private static func validateComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\0") else {
            throw SecureOwnedStorageError.invalidPathComponent(component)
        }
    }

    private func validateFileName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw SecureOwnedStorageError.invalidFileName(name)
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        path: String
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError(errno, path: path)
                }
                guard count > 0 else {
                    throw posixError(EIO, path: path)
                }
                offset += count
            }
        }
    }

    private static func synchronizeFileDescriptor(
        _ descriptor: Int32,
        path: String
    ) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        let fullSyncError = errno
        guard fullSyncError == ENOTSUP
                || fullSyncError == EINVAL
                || fullSyncError == ENOTTY else {
            throw posixError(fullSyncError, path: path)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(errno, path: path)
        }
    }

    fileprivate static func posixError(
        _ code: Int32,
        path: String
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}

/// Two-generation bounded JSONL storage used by the diagnostics writer. It is
/// hostless so symlink and rotation behavior can be tested without launching
/// Docky or touching the user's actual Application Support directory.
nonisolated final class SecureBoundedLogStore: @unchecked Sendable {
    private let directoryResult: Result<SecureOwnedDirectory, Error>
    private let currentName: String
    private let previousName: String
    private let maximumFileBytes: Int

    init(
        directoryResult: Result<SecureOwnedDirectory, Error>,
        currentName: String,
        previousName: String,
        maximumFileBytes: Int
    ) {
        self.directoryResult = directoryResult
        self.currentName = currentName
        self.previousName = previousName
        self.maximumFileBytes = maximumFileBytes
    }

    convenience init(
        directoryURL: URL,
        currentName: String,
        previousName: String,
        maximumFileBytes: Int
    ) {
        self.init(
            directoryResult: Result {
                try SecureOwnedDirectory.openOrCreate(at: directoryURL)
            },
            currentName: currentName,
            previousName: previousName,
            maximumFileBytes: maximumFileBytes
        )
    }

    static func applicationSupport(
        at applicationSupportURL: URL,
        descending components: [String],
        currentName: String,
        previousName: String,
        maximumFileBytes: Int
    ) -> SecureBoundedLogStore {
        SecureBoundedLogStore(
            directoryResult: Result {
                try SecureOwnedDirectory.applicationSupport(
                    at: applicationSupportURL,
                    descending: components
                )
            },
            currentName: currentName,
            previousName: previousName,
            maximumFileBytes: maximumFileBytes
        )
    }

    func append(_ data: Data) throws {
        let directory = try directoryResult.get()
        guard try directory.appendRegularFile(
            data,
            named: currentName,
            maximumBytes: maximumFileBytes
        ) else {
            try directory.rotateRegularFile(
                from: currentName,
                to: previousName
            )
            guard try directory.appendRegularFile(
                data,
                named: currentName,
                maximumBytes: maximumFileBytes
            ) else {
                throw SecureOwnedStorageError.writeTooLarge(
                    name: currentName,
                    maximumBytes: maximumFileBytes
                )
            }
            return
        }
    }

    func copyRetainedLogs(to destinationDirectoryURL: URL) throws {
        let sourceDirectory = try directoryResult.get()
        let destinationDirectory = try SecureOwnedDirectory.openOrCreate(
            at: destinationDirectoryURL
        )
        for name in [previousName, currentName] {
            guard let data = try sourceDirectory.readRegularFile(
                named: name,
                maximumBytes: maximumFileBytes
            ) else {
                continue
            }
            try destinationDirectory.writeRegularFileAtomically(
                data,
                named: name,
                maximumBytes: maximumFileBytes
            )
        }
    }
}

nonisolated struct AtomicJSONFileStore<Value: Codable & Equatable> {
    enum Source: String, Equatable {
        case primary
        case backup
    }

    enum PrimaryExpectation {
        /// Compatibility mode for callers that have not adopted stale-writer
        /// detection yet.
        case unchecked
        /// The transaction is valid only if no primary exists.
        case missing
        /// The transaction is valid only if the on-disk primary still equals
        /// the durable predecessor supplied by the persistence coordinator.
        case value(Value)
    }

    struct LoadResult {
        let value: Value
        let source: Source
        let recoveredPrimary: Bool
        let primaryFailureDescription: String?
        let primaryRepairFailureDescription: String?
        let quarantinedPrimaryURL: URL?
    }

    enum StoreError: Error, LocalizedError {
        case noValidCopy(primary: String?, backup: String?)
        case primaryRecoveryRejected(String)
        case primaryReadFailed(String)
        case backupReadFailed(String)
        case existingPrimaryInvalid(String)
        case primaryMissingWhileBackupExists
        case primaryChangedSinceLoad
        case encodedValueFailedValidation(String)
        case documentTooLarge(maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .noValidCopy(let primary, let backup):
                return [
                    primary.map { "primary: \($0)" },
                    backup.map { "backup: \($0)" },
                ]
                .compactMap { $0 }
                .joined(separator: "; ")
            case .primaryRecoveryRejected(let reason):
                return "The primary document cannot be replaced by its backup: \(reason)"
            case .primaryReadFailed(let reason):
                return "The primary document could not be read and was left untouched: \(reason)"
            case .backupReadFailed(let reason):
                return "The backup document could not be read and was left untouched: \(reason)"
            case .existingPrimaryInvalid(let reason):
                return "The existing primary document is invalid: \(reason)"
            case .primaryMissingWhileBackupExists:
                return "The primary document is missing while a backup still exists."
            case .primaryChangedSinceLoad:
                return "The primary document changed after it was loaded; the stale write was rejected."
            case .encodedValueFailedValidation(let reason):
                return "The encoded document failed its own validation: \(reason)"
            case .documentTooLarge(let maximumBytes):
                return "The profile document exceeds the \(maximumBytes)-byte limit."
            }
        }
    }

    let primaryURL: URL
    let backupURL: URL
    let previousBackupURL: URL

    private static var defaultMaximumDocumentBytes: Int {
        16 * 1_024 * 1_024
    }

    private let directoryResult: Result<SecureOwnedDirectory, Error>
    private let readDataOverride: ((URL) throws -> Data)?
    private let pathEntryExistsOverride: ((URL) throws -> Bool)?
    private let synchronizeFileBeforeRename: ((URL) throws -> Void)?
    private let synchronizeDirectoryAfterRename: ((URL) throws -> Void)?
    private let maximumDocumentBytes: Int

    init(
        primaryURL: URL,
        backupURL: URL,
        previousBackupURL: URL? = nil,
        fileManager: FileManager = .default,
        readData: ((URL) throws -> Data)? = nil,
        pathEntryExists: ((URL) throws -> Bool)? = nil,
        synchronizeFileBeforeRename: ((URL) throws -> Void)? = nil,
        synchronizeDirectoryAfterRename: ((URL) throws -> Void)? = nil,
        maximumDocumentBytes: Int = Self.defaultMaximumDocumentBytes
    ) {
        _ = fileManager
        self.primaryURL = primaryURL.standardizedFileURL
        self.backupURL = backupURL.standardizedFileURL
        self.previousBackupURL = (
            previousBackupURL
                ?? Self.defaultPreviousBackupURL(for: self.backupURL)
        ).standardizedFileURL
        let primaryDirectory =
            self.primaryURL.deletingLastPathComponent()
        let backupDirectory =
            self.backupURL.deletingLastPathComponent()
        let previousDirectory =
            self.previousBackupURL.deletingLastPathComponent()
        let names = Set([
            self.primaryURL.lastPathComponent,
            self.backupURL.lastPathComponent,
            self.previousBackupURL.lastPathComponent,
        ])
        if primaryDirectory.path == backupDirectory.path,
           primaryDirectory.path == previousDirectory.path,
           names.count == 3 {
            directoryResult = Result {
                try SecureOwnedDirectory.openOrCreate(at: primaryDirectory)
            }
        } else {
            directoryResult = .failure(
                SecureOwnedStorageError.invalidDirectoryURL(
                    backupDirectory.path
                )
            )
        }
        readDataOverride = readData
        pathEntryExistsOverride = pathEntryExists
        self.synchronizeFileBeforeRename = synchronizeFileBeforeRename
        self.synchronizeDirectoryAfterRename = synchronizeDirectoryAfterRename
        self.maximumDocumentBytes = maximumDocumentBytes
    }

    /// Production initializer. The returned directory descriptor is anchored
    /// under the canonical user Application Support directory before Docky
    /// and Profiles are descended component-by-component.
    init(
        applicationSupportURL: URL,
        relativeDirectoryComponents: [String],
        primaryFileName: String,
        backupFileName: String,
        previousBackupFileName: String? = nil,
        maximumDocumentBytes: Int = Self.defaultMaximumDocumentBytes
    ) {
        let directoryURL = relativeDirectoryComponents.reduce(
            applicationSupportURL.standardizedFileURL
        ) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let resolvedPreviousBackupFileName =
            previousBackupFileName
                ?? Self.defaultPreviousBackupFileName(
                    for: backupFileName
                )
        primaryURL = directoryURL.appendingPathComponent(primaryFileName)
        backupURL = directoryURL.appendingPathComponent(backupFileName)
        previousBackupURL = directoryURL.appendingPathComponent(
            resolvedPreviousBackupFileName
        )
        let requestedFileNames = [
            primaryFileName,
            backupFileName,
            resolvedPreviousBackupFileName,
        ]
        let distinctFileNames = Set([
            primaryURL.lastPathComponent,
            backupURL.lastPathComponent,
            previousBackupURL.lastPathComponent,
        ])
        if requestedFileNames.allSatisfy(Self.isValidFileName),
           distinctFileNames.count == 3 {
            directoryResult = Result {
                try SecureOwnedDirectory.applicationSupport(
                    at: applicationSupportURL,
                    descending: relativeDirectoryComponents
                )
            }
        } else {
            directoryResult = .failure(
                SecureOwnedStorageError.invalidFileName(
                    primaryFileName
                )
            )
        }
        readDataOverride = nil
        pathEntryExistsOverride = nil
        synchronizeFileBeforeRename = nil
        synchronizeDirectoryAfterRename = nil
        self.maximumDocumentBytes = maximumDocumentBytes
    }

    func load(
        validate: (Value) throws -> Void,
        canRecoverPrimaryFailure: (Error) -> Bool = { _ in true }
    ) throws -> LoadResult? {
        let directory = try directoryResult.get()
        return try directory.withExclusiveLock {
            try loadWhileLocked(
                validate: validate,
                canRecoverPrimaryFailure: canRecoverPrimaryFailure
            )
        }
    }

    private func loadWhileLocked(
        validate: (Value) throws -> Void,
        canRecoverPrimaryFailure: (Error) -> Bool
    ) throws -> LoadResult? {
        var primaryFailure: Error?
        let primaryData: Data?
        do {
            primaryData = try dataIfPresent(at: primaryURL)
        } catch {
            // A read or presence-probe failure says nothing about document
            // validity. Never replace a possibly-newer primary merely because
            // its bytes were temporarily unavailable.
            throw StoreError.primaryReadFailed(Self.describe(error))
        }
        if let primaryData {
            do {
                let value = try decodedValue(from: primaryData, validate: validate)
                return LoadResult(
                    value: value,
                    source: .primary,
                    recoveredPrimary: false,
                    primaryFailureDescription: nil,
                    primaryRepairFailureDescription: nil,
                    quarantinedPrimaryURL: nil
                )
            } catch {
                guard canRecoverPrimaryFailure(error) else {
                    throw StoreError.primaryRecoveryRejected(Self.describe(error))
                }
                primaryFailure = error
            }
        }

        var backupFailure: Error?
        let backupData: Data?
        do {
            backupData = try dataIfPresent(at: backupURL)
        } catch {
            backupData = nil
            backupFailure = error
        }
        if let backupData {
            do {
                let value = try decodedValue(from: backupData, validate: validate)
                var repairFailure: Error?
                var quarantinedPrimaryURL: URL?
                do {
                    try ensureParentDirectory()
                    if let primaryData {
                        quarantinedPrimaryURL =
                            try writeImmutableSnapshot(
                                primaryData,
                                role: "quarantine"
                            )
                    }
                    try atomicWrite(backupData, to: primaryURL)
                } catch {
                    // The backup is still a valid authoritative value even
                    // when repairing the primary is temporarily impossible.
                    // Surface the blocked persistence state to the caller
                    // without discarding good user configuration.
                    repairFailure = error
                }
                return LoadResult(
                    value: value,
                    source: .backup,
                    recoveredPrimary: repairFailure == nil,
                    primaryFailureDescription: primaryFailure.map(Self.describe),
                    primaryRepairFailureDescription:
                        repairFailure.map(Self.describe),
                    quarantinedPrimaryURL: quarantinedPrimaryURL
                )
            } catch {
                backupFailure = error
            }
        }

        if primaryData == nil, backupData == nil, backupFailure == nil {
            return nil
        }

        throw StoreError.noValidCopy(
            primary: primaryFailure.map(Self.describe),
            backup: backupFailure.map(Self.describe)
        )
    }

    @discardableResult
    func save(
        _ value: Value,
        validate: (Value) throws -> Void,
        validateExisting:
            ((Value) throws -> Void)? = nil,
        expectedPrimary: PrimaryExpectation = .unchecked,
        archiveExistingGenerations: Bool = false
    ) throws -> Int {
        try validate(value)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        guard encoded.count <= maximumDocumentBytes else {
            throw StoreError.documentTooLarge(
                maximumBytes: maximumDocumentBytes
            )
        }

        do {
            let roundTripped = try JSONDecoder().decode(Value.self, from: encoded)
            try validate(roundTripped)
        } catch {
            throw StoreError.encodedValueFailedValidation(Self.describe(error))
        }

        try ensureParentDirectory()
        let directory = try directoryResult.get()
        return try directory.withExclusiveLock {
            try saveWhileLocked(
                encoded,
                validate: validate,
                validateExisting: validateExisting,
                expectedPrimary: expectedPrimary,
                archiveExistingGenerations:
                    archiveExistingGenerations
            )
        }
    }

    private func saveWhileLocked(
        _ encoded: Data,
        validate: (Value) throws -> Void,
        validateExisting: ((Value) throws -> Void)?,
        expectedPrimary: PrimaryExpectation,
        archiveExistingGenerations: Bool
    ) throws -> Int {
        let currentPrimary: Data?
        do {
            currentPrimary = try dataIfPresent(at: primaryURL)
        } catch {
            throw StoreError.primaryReadFailed(Self.describe(error))
        }
        let currentValue: Value?
        if let currentPrimary {
            do {
                if let validateExisting {
                    currentValue = try decodedValue(
                        from: currentPrimary,
                        validate: validateExisting
                    )
                } else {
                    currentValue = try decodedValue(
                        from: currentPrimary,
                        validate: validate
                    )
                }
            } catch {
                throw StoreError.existingPrimaryInvalid(Self.describe(error))
            }
        } else {
            currentValue = nil
        }

        switch expectedPrimary {
        case .unchecked:
            break
        case .missing:
            guard currentPrimary == nil else {
                throw StoreError.primaryChangedSinceLoad
            }
        case .value(let expected):
            guard currentValue == expected else {
                throw StoreError.primaryChangedSinceLoad
            }
        }

        let currentBackup: Data?
        do {
            currentBackup = try dataIfPresent(at: backupURL)
        } catch {
            throw StoreError.backupReadFailed(Self.describe(error))
        }

        if currentPrimary == nil, currentBackup != nil {
            // A missing primary with a surviving backup indicates an
            // interrupted or externally-modified store. Preserve it and
            // require an explicit load/recovery before accepting writes.
            throw StoreError.primaryMissingWhileBackupExists
        }

        if archiveExistingGenerations,
           let currentPrimary {
            try archiveGenerations(
                primary: currentPrimary,
                backup: currentBackup
            )
        }

        if let currentPrimary {
            // Keep the older backup in a third slot before rotating the
            // current primary over it. If publishing the new primary fails,
            // both durable predecessors remain available.
            if let currentBackup,
               currentBackup != currentPrimary {
                try atomicWrite(
                    currentBackup,
                    to: previousBackupURL
                )
            }
            try atomicWrite(currentPrimary, to: backupURL)
        } else {
            // Seed a complete recovery copy before publishing the first
            // primary. A crash between these two atomic renames is recovered
            // from the backup on the next load.
            try atomicWrite(encoded, to: backupURL)
        }

        try atomicWrite(encoded, to: primaryURL)
        return encoded.count
    }

    /// Production reads are fd-relative, no-follow, regular-file-only, and
    /// bounded. Injected readers remain available for deterministic failure
    /// tests, with the same fail-closed presence-probe behavior.
    private func dataIfPresent(at url: URL) throws -> Data? {
        guard let readDataOverride else {
            return try directoryResult.get().readRegularFile(
                named: url.lastPathComponent,
                maximumBytes: maximumDocumentBytes
            )
        }
        do {
            let data = try readDataOverride(url)
            guard data.count <= maximumDocumentBytes else {
                throw SecureOwnedStorageError.fileTooLarge(
                    name: url.lastPathComponent,
                    maximumBytes: maximumDocumentBytes
                )
            }
            return data
        } catch {
            guard Self.isNoSuchFile(error) else { throw error }
            if try entryExists(at: url) {
                throw error
            }
            return nil
        }
    }

    private func entryExists(at url: URL) throws -> Bool {
        if let pathEntryExistsOverride {
            return try pathEntryExistsOverride(url)
        }
        return try directoryResult.get().entryExists(
            named: url.lastPathComponent
        )
    }

    private func decodedValue(
        from data: Data,
        validate: (Value) throws -> Void
    ) throws -> Value {
        let value = try JSONDecoder().decode(Value.self, from: data)
        try validate(value)
        return value
    }

    private func ensureParentDirectory() throws {
        _ = try directoryResult.get()
    }

    private func archiveGenerations(
        primary: Data,
        backup: Data?
    ) throws {
        let transactionID = UUID().uuidString.lowercased()
        _ = try writeImmutableSnapshot(
            primary,
            role: "migration-archive.primary",
            transactionID: transactionID
        )
        if let backup {
            _ = try writeImmutableSnapshot(
                backup,
                role: "migration-archive.backup",
                transactionID: transactionID
            )
        }
    }

    @discardableResult
    private func writeImmutableSnapshot(
        _ data: Data,
        role: String,
        transactionID: String = UUID().uuidString.lowercased()
    ) throws -> URL {
        let snapshotURL = primaryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".atomic-json.\(role).\(transactionID).json"
            )
        try atomicWrite(
            data,
            to: snapshotURL,
            replaceExisting: false
        )
        return snapshotURL
    }

    private func atomicWrite(
        _ data: Data,
        to url: URL,
        replaceExisting: Bool = true
    ) throws {
        try directoryResult.get().writeRegularFileAtomically(
            data,
            named: url.lastPathComponent,
            maximumBytes: maximumDocumentBytes,
            beforeSynchronize: synchronizeFileBeforeRename,
            afterRename: synchronizeDirectoryAfterRename,
            replaceExisting: replaceExisting
        )
    }

    nonisolated private static func defaultPreviousBackupURL(
        for backupURL: URL
    ) -> URL {
        backupURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                defaultPreviousBackupFileName(
                    for: backupURL.lastPathComponent
                )
            )
    }

    nonisolated private static func defaultPreviousBackupFileName(
        for backupFileName: String
    ) -> String {
        let fileURL = URL(fileURLWithPath: backupFileName)
        let fileExtension = fileURL.pathExtension
        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard !fileExtension.isEmpty else {
            return "\(stem).previous"
        }
        return "\(stem).previous.\(fileExtension)"
    }

    nonisolated private static func isValidFileName(
        _ name: String
    ) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    nonisolated private static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(ENOENT) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNoSuchFile(underlying)
        }
        return false
    }

    nonisolated private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }
}
