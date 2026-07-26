//
//  FeedbackBundleWorker.swift
//  Docky
//
//  Serial, cancellable preparation of feedback archives. The view captures
//  AppKit and preference state into immutable data first; everything that can
//  scan, copy, write, or launch a subprocess is confined to this worker.
//

import Darwin
import Foundation

nonisolated struct FeedbackPreparationGeneration: Sendable {
    nonisolated struct Token: Equatable, Sendable {
        fileprivate let rawValue: UInt64
    }

    private var rawValue: UInt64 = 0

    @discardableResult
    mutating func advance() -> Token {
        rawValue &+= 1
        if rawValue == 0 {
            rawValue = 1
        }
        return Token(rawValue: rawValue)
    }

    mutating func invalidate() {
        _ = advance()
    }

    func isCurrent(_ token: Token) -> Bool {
        token.rawValue == rawValue
    }
}

nonisolated enum FeedbackBundlePrivacy {
    static func dockyDefaults(
        from values: [String: Any]
    ) -> [String: Any] {
        values.filter { key, _ in
            key.hasPrefix("docky.")
        }
    }
}

nonisolated enum FeedbackTemporaryArtifactPolicy {
    static let prefix = "docky-feedback-"
    static let containerName = "DockyFeedbackBundles"

    static func containerURL(temporaryDirectory: URL) -> URL {
        temporaryDirectory.standardizedFileURL.appending(
            path: containerName,
            directoryHint: .isDirectory
        )
    }

    static func isOwnedBundle(
        _ url: URL,
        temporaryDirectory: URL
    ) -> Bool {
        isDirectTemporaryArtifact(url, temporaryDirectory: temporaryDirectory)
            && url.pathExtension == "zip"
    }

    static func isDirectTemporaryArtifact(
        _ url: URL,
        temporaryDirectory: URL
    ) -> Bool {
        let candidate = url.standardizedFileURL
        let container = containerURL(
            temporaryDirectory: temporaryDirectory
        )
        let parent = candidate.deletingLastPathComponent()
        return (
            parent == container
                || parent == temporaryDirectory.standardizedFileURL
        )
            && candidate.lastPathComponent.hasPrefix(prefix)
    }
}

/// A Sendable capability for copying a consistent diagnostics snapshot.
/// DiagnosticsTrace creates this on MainActor; invoking it from the feedback
/// worker drains and copies through the trace writer's own serial queue.
nonisolated struct FeedbackDiagnosticsSnapshot: Sendable {
    private let copyAction: @Sendable (URL) throws -> Void

    init(copyAction: @escaping @Sendable (URL) throws -> Void) {
        self.copyAction = copyAction
    }

    func copy(to destinationDirectory: URL) throws {
        try copyAction(destinationDirectory)
    }
}

/// Every value here is captured before leaving MainActor. Property-list and
/// JSON values are serialized during capture so arbitrary `Any` graphs never
/// cross an isolation boundary.
nonisolated struct FeedbackBundleSnapshot: Sendable {
    let feedbackText: String
    let dockyDefaultsPlist: Data
    let dockPlist: Data?
    let systemJSON: Data
    let attachmentURL: URL?
    let diagnostics: FeedbackDiagnosticsSnapshot
}

nonisolated enum FeedbackBundleWorkerError: LocalizedError {
    case mainThreadExecution
    case secureArchiveUnavailable
    case attachmentTooLarge(maximumBytes: Int)
    case invalidAttachment

    var errorDescription: String? {
        switch self {
        case .mainThreadExecution:
            return "Diagnostic file preparation was scheduled on the main thread."
        case .secureArchiveUnavailable:
            return "Feedback bundle export is temporarily unavailable because Docky cannot safely bind the system archiver to its private staging directory."
        case .attachmentTooLarge(let maximumBytes):
            let mebibytes = maximumBytes / (1_024 * 1_024)
            return "The attachment is larger than the \(mebibytes) MiB limit."
        case .invalidAttachment:
            return "The attachment must be a regular file, not a link, directory, pipe, or device."
        }
    }
}

nonisolated final class FeedbackBundleWorker: @unchecked Sendable {
    static let shared = FeedbackBundleWorker()

    private static let staleArtifactAge: TimeInterval = 86_400
    static let maximumAttachmentBytes = 25 * 1_024 * 1_024
    static let attachmentFileName = "attachment.bin"

    private let workerQueue = DispatchQueue(
        label: "gt.quintero.Docky.FeedbackBundleWorker",
        qos: .userInitiated
    )

    func prepare(_ snapshot: FeedbackBundleSnapshot) async throws -> URL {
        try await submit { cancellation in
            try Self.buildSynchronously(
                snapshot,
                cancellation: cancellation
            )
        } discard: { bundleURL in
            Self.removeTemporaryBundleSynchronously(at: bundleURL)
        }
    }

    func prepareAndSave(
        _ snapshot: FeedbackBundleSnapshot,
        to destinationURL: URL
    ) async throws {
        try await submit { cancellation in
            let bundleURL = try Self.buildSynchronously(
                snapshot,
                cancellation: cancellation
            )
            defer {
                Self.removeTemporaryBundleSynchronously(at: bundleURL)
            }
            _ = destinationURL
            throw FeedbackBundleWorkerError.secureArchiveUnavailable
        }
    }

    /// Scheduling is intentionally synchronous and cheap. Removal itself
    /// happens on the worker queue, including the immediate cleanup path used
    /// for stale or cancelled view generations.
    func scheduleCleanup(
        of bundleURL: URL,
        after delay: TimeInterval = 3_600
    ) {
        workerQueue.asyncAfter(deadline: .now() + max(0, delay)) {
            Self.removeTemporaryBundleSynchronously(at: bundleURL)
        }
    }

    private func submit<Value: Sendable>(
        _ work: @escaping @Sendable (
            FeedbackProcessCancellation
        ) throws -> Value,
        discard: (@Sendable (Value) -> Void)? = nil
    ) async throws -> Value {
        let request = FeedbackWorkerRequest<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                workerQueue.async {
                    guard request.shouldStart else { return }
                    let outcome = Result {
                        try work(request.cancellation)
                    }
                    let wasDelivered = request.finish(outcome)
                    if !wasDelivered, case .success(let value) = outcome {
                        discard?(value)
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    private static func buildSynchronously(
        _ snapshot: FeedbackBundleSnapshot,
        cancellation: FeedbackProcessCancellation
    ) throws -> URL {
        guard !Thread.isMainThread else {
            throw FeedbackBundleWorkerError.mainThreadExecution
        }
        try cancellation.check()
        _ = snapshot
        // `ditto` follows a source symlink supplied as an argument and does
        // not accept a retained directory descriptor as its archive source.
        // A same-UID process could therefore redirect Docky's retained Full
        // Disk Access between staging and process launch. Fail closed until an
        // in-process or descriptor-bound ZIP writer replaces that path API.
        throw FeedbackBundleWorkerError.secureArchiveUnavailable
    }

    /// Copies a user-selected attachment without following its final symlink
    /// and without preserving a potentially sensitive source filename. The
    /// source descriptor is validated before any destination is created, and
    /// the partial fixed-name artifact is removed on every failure path.
    @discardableResult
    static func stageAttachmentSynchronously(
        from sourceURL: URL,
        in destinationDirectory: URL,
        maximumBytes: Int = maximumAttachmentBytes,
        cancellation: FeedbackProcessCancellation,
        didCopyChunk: (@Sendable (Int) -> Void)? = nil
    ) throws -> URL {
        try cancellation.check()
        let sourceDescriptor = sourceURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard sourceDescriptor >= 0 else {
            if errno == ELOOP {
                throw FeedbackBundleWorkerError.invalidAttachment
            }
            throw posixError(errno)
        }
        defer { _ = Darwin.close(sourceDescriptor) }

        var sourceMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0 else {
            throw posixError(errno)
        }
        guard sourceMetadata.st_mode & S_IFMT == S_IFREG,
              sourceMetadata.st_size >= 0 else {
            throw FeedbackBundleWorkerError.invalidAttachment
        }

        let boundedMaximum = max(0, maximumBytes)
        guard sourceMetadata.st_size <= off_t(boundedMaximum) else {
            throw FeedbackBundleWorkerError.attachmentTooLarge(
                maximumBytes: boundedMaximum
            )
        }

        var copiedBytes = 0
        var data = Data()
        data.reserveCapacity(Int(sourceMetadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellation.check()
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    sourceDescriptor,
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
            guard count <= boundedMaximum - copiedBytes else {
                throw FeedbackBundleWorkerError.attachmentTooLarge(
                    maximumBytes: boundedMaximum
                )
            }

            data.append(contentsOf: buffer.prefix(count))
            copiedBytes += count
            didCopyChunk?(copiedBytes)
        }

        try cancellation.check()
        let secureDirectory = try SecureOwnedDirectory.openOrCreate(
            at: destinationDirectory
        )
        try secureDirectory.writeRegularFileAtomically(
            data,
            named: attachmentFileName,
            maximumBytes: boundedMaximum
        )
        return secureDirectory.url.appending(path: attachmentFileName)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    static func cleanupStaleTemporaryArtifacts(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        let artifactDirectory =
            FeedbackTemporaryArtifactPolicy.containerURL(
                temporaryDirectory: temporaryDirectory
            )
        let cutoff = Date().addingTimeInterval(-staleArtifactAge)
        for directory in [artifactDirectory, temporaryDirectory] {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries where
                FeedbackTemporaryArtifactPolicy.isDirectTemporaryArtifact(
                    entry,
                    temporaryDirectory: temporaryDirectory
                ) {
                let modified = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                if let modified, modified < cutoff {
                    try? fileManager.removeItem(at: entry)
                }
            }
        }
    }

    private static func removeTemporaryBundleSynchronously(
        at bundleURL: URL
    ) {
        let fileManager = FileManager.default
        guard FeedbackTemporaryArtifactPolicy.isOwnedBundle(
            bundleURL,
            temporaryDirectory: fileManager.temporaryDirectory
        ) else {
            return
        }
        _ = bundleURL.path.withCString { Darwin.unlink($0) }
    }
}

private nonisolated final class FeedbackWorkerRequest<Value: Sendable>:
    @unchecked Sendable {
    typealias Outcome = Result<Value, Error>

    let cancellation = FeedbackProcessCancellation()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingOutcome: Outcome?
    private var isFinished = false

    var shouldStart: Bool {
        lock.withFeedbackLock { !isFinished }
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let pending = lock.withFeedbackLock { () -> Outcome? in
            if let pendingOutcome {
                self.pendingOutcome = nil
                return pendingOutcome
            }
            self.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(with: pending)
        }
    }

    /// Returns true only when this outcome won the completion race. A caller
    /// that loses with a successfully-created temporary URL must clean it up.
    @discardableResult
    func finish(_ outcome: Outcome) -> Bool {
        let completion = lock.withFeedbackLock {
            () -> (CheckedContinuation<Value, Error>?, Bool) in
            guard !isFinished else { return (nil, false) }
            isFinished = true
            if let continuation {
                self.continuation = nil
                return (continuation, true)
            }
            pendingOutcome = outcome
            return (nil, true)
        }

        if let continuation = completion.0 {
            continuation.resume(with: outcome)
        }
        return completion.1
    }

    func cancel() {
        cancellation.cancel()
        _ = finish(.failure(CancellationError()))
    }
}
