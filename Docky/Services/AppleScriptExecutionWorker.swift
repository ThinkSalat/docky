//
//  AppleScriptExecutionWorker.swift
//  Docky
//
//  Serialized AppleScript compilation and execution. NSAppleScript is
//  intentionally confined to a private dispatch queue so a slow or hung
//  target application can never block AppKit's main actor.
//

import Foundation

nonisolated enum AppleScriptServiceError: Error, Equatable, Sendable {
    case permissionDenied
    case accessibilityDenied
    case compilationFailed
    case executionFailed(String)
    case timedOut
    case cancelled
}

private nonisolated enum AppleScriptExecutionResultKind: Sendable {
    case discardDescriptor
    case boolean
}

private nonisolated enum AppleScriptExecutionValue: Sendable {
    case completed
    case boolean(Bool)
}

/// Owns one continuation and admits exactly one terminal result. NSAppleScript
/// cannot be interrupted reliably, so timeout and cancellation resume the
/// caller promptly while any eventual worker result is safely discarded.
private nonisolated final class AppleScriptExecutionRequest:
    @unchecked Sendable
{
    typealias Outcome = Result<
        AppleScriptExecutionValue,
        AppleScriptServiceError
    >

    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<Outcome, Never>?
    private var pendingOutcome: Outcome?
    private var isFinished = false

    var shouldStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isFinished
    }

    func install(
        _ continuation: CheckedContinuation<Outcome, Never>
    ) {
        lock.lock()
        if let pendingOutcome {
            self.pendingOutcome = nil
            lock.unlock()
            continuation.resume(returning: pendingOutcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ outcome: Outcome) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        pendingOutcome = outcome
        lock.unlock()
    }
}

/// `nonisolated` is required because the project defaults declarations to
/// `MainActor`. All NSAppleScript objects and descriptors are created, read,
/// and released inside `executionQueue`.
nonisolated final class AppleScriptExecutionWorker:
    @unchecked Sendable
{
    private static let defaultTimeout: TimeInterval = 30

    private let executionQueue = DispatchQueue(
        label: "gt.quintero.Docky.AppleScriptExecutionWorker",
        qos: .userInitiated
    )
    private let timeoutQueue = DispatchQueue(
        label: "gt.quintero.Docky.AppleScriptExecutionTimeout",
        qos: .utility
    )

    func execute(
        source: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws {
        let value = try await submit(
            source: source,
            resultKind: .discardDescriptor,
            timeout: timeout
        )
        guard case .completed = value else {
            throw AppleScriptServiceError.executionFailed(
                "AppleScript returned an unexpected value."
            )
        }
    }

    func executeBoolean(
        source: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> Bool {
        let value = try await submit(
            source: source,
            resultKind: .boolean,
            timeout: timeout
        )
        guard case let .boolean(boolean) = value else {
            throw AppleScriptServiceError.executionFailed(
                "AppleScript returned an unexpected value."
            )
        }
        return boolean
    }

    private func submit(
        source: String,
        resultKind: AppleScriptExecutionResultKind,
        timeout: TimeInterval
    ) async throws -> AppleScriptExecutionValue {
        let request = AppleScriptExecutionRequest()
        let boundedTimeout = max(timeout, 0.1)

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.install(continuation)

                executionQueue.async {
                    guard request.shouldStart else { return }
                    request.finish(
                        Self.executeSynchronously(
                            source: source,
                            resultKind: resultKind
                        )
                    )
                }

                timeoutQueue.asyncAfter(
                    deadline: .now() + boundedTimeout
                ) {
                    request.finish(.failure(.timedOut))
                }
            }
        } onCancel: {
            request.finish(.failure(.cancelled))
        }

        return try outcome.get()
    }

    private static func executeSynchronously(
        source: String,
        resultKind: AppleScriptExecutionResultKind
    ) -> AppleScriptExecutionRequest.Outcome {
        // This guard is deliberately before NSAppleScript construction. It
        // turns any future queueing regression into a safe failure rather than
        // compiling or executing a script on AppKit's event thread.
        guard !Thread.isMainThread else {
            return .failure(
                .executionFailed(
                    "AppleScript worker was scheduled on the main thread."
                )
            )
        }

        return autoreleasepool {
            guard let script = NSAppleScript(source: source) else {
                return .failure(.compilationFailed)
            }

            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let error = scriptError(from: errorInfo) {
                return .failure(error)
            }

            switch resultKind {
            case .discardDescriptor:
                return .success(.completed)
            case .boolean:
                return .success(.boolean(descriptor.booleanValue))
            }
        }
    }

    private static func scriptError(
        from errorInfo: NSDictionary?
    ) -> AppleScriptServiceError? {
        guard let errorInfo else { return nil }
        let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?
            .intValue
        let message =
            (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "AppleScript execution failed."

        if number == -1743 {
            return .permissionDenied
        }
        if number == 1002 {
            return .accessibilityDenied
        }
        return .executionFailed(message)
    }
}
