//
//  FeedbackBoundedProcessRunner.swift
//  Docky
//
//  A cancellation-aware subprocess primitive with independently bounded
//  lifetime, stdout capture, stderr capture, and post-exit pipe draining.
//

import Darwin
import Foundation

nonisolated final class FeedbackProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withFeedbackLock { cancelled }
    }

    func cancel() {
        lock.withFeedbackLock {
            cancelled = true
        }
    }

    func check() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

nonisolated struct FeedbackBoundedProcessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
    let standardOutputWasTruncated: Bool
    let standardErrorWasTruncated: Bool

    var standardErrorString: String {
        var value = String(data: standardError, encoding: .utf8) ?? ""
        if standardErrorWasTruncated {
            value += "\n[output truncated]"
        }
        return value
    }
}

nonisolated enum FeedbackProcessError: LocalizedError, Equatable {
    case timedOut
    case outputWouldNotDrain
    case wouldNotTerminate

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The diagnostic archive operation took too long and was stopped."
        case .outputWouldNotDrain:
            return "The diagnostic archive process did not close its output streams."
        case .wouldNotTerminate:
            return "The diagnostic archive process could not be stopped."
        }
    }
}

nonisolated enum FeedbackBoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int,
        cancellation: FeedbackProcessCancellation
    ) throws -> FeedbackBoundedProcessResult {
        try cancellation.check()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputDrain = FeedbackBoundedPipeDrain(
            handle: outputPipe.fileHandleForReading,
            maximumBytes: maximumStandardOutputBytes
        )
        let errorDrain = FeedbackBoundedPipeDrain(
            handle: errorPipe.fileHandleForReading,
            maximumBytes: maximumStandardErrorBytes
        )
        let drainGroup = DispatchGroup()
        outputDrain.start(in: drainGroup)
        errorDrain.start(in: drainGroup)

        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            processExited.signal()
        }

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            stopDrainsIfNeeded(
                outputDrain,
                errorDrain,
                group: drainGroup
            )
            throw error
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let deadline = ProcessInfo.processInfo.systemUptime
            + max(0.1, timeout)
        var terminalError: Error?
        while processExited.wait(
            timeout: .now() + .milliseconds(50)
        ) == .timedOut {
            if cancellation.isCancelled {
                terminalError = CancellationError()
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                terminalError = FeedbackProcessError.timedOut
                break
            }
        }

        if terminalError != nil {
            if process.isRunning {
                process.terminate()
            }
            if processExited.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                guard processExited.wait(timeout: .now() + 2) == .success else {
                    stopDrains(
                        outputDrain,
                        errorDrain,
                        group: drainGroup
                    )
                    throw FeedbackProcessError.wouldNotTerminate
                }
            }
        }

        // Both readers have been draining since before launch. Bound this
        // final phase too: a descendant must not keep an inherited pipe open
        // forever after the direct child exits.
        if drainGroup.wait(timeout: .now() + 2) == .timedOut {
            outputDrain.stop()
            errorDrain.stop()
            guard drainGroup.wait(timeout: .now() + 1) == .success else {
                throw FeedbackProcessError.outputWouldNotDrain
            }
            if let terminalError {
                throw terminalError
            }
            throw FeedbackProcessError.outputWouldNotDrain
        }

        if let terminalError {
            throw terminalError
        }
        try cancellation.check()
        return FeedbackBoundedProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputDrain.data,
            standardError: errorDrain.data,
            standardOutputWasTruncated: outputDrain.wasTruncated,
            standardErrorWasTruncated: errorDrain.wasTruncated
        )
    }

    private static func stopDrainsIfNeeded(
        _ outputDrain: FeedbackBoundedPipeDrain,
        _ errorDrain: FeedbackBoundedPipeDrain,
        group: DispatchGroup
    ) {
        guard group.wait(timeout: .now() + 1) == .timedOut else {
            return
        }
        outputDrain.stop()
        errorDrain.stop()
        _ = group.wait(timeout: .now() + 1)
    }

    private static func stopDrains(
        _ outputDrain: FeedbackBoundedPipeDrain,
        _ errorDrain: FeedbackBoundedPipeDrain,
        group: DispatchGroup
    ) {
        outputDrain.stop()
        errorDrain.stop()
        _ = group.wait(timeout: .now() + 1)
    }
}

private nonisolated final class FeedbackBoundedPipeDrain:
    @unchecked Sendable {
    private let handle: FileHandle
    private let maximumBytes: Int
    private let lock = NSLock()
    private var storedData = Data()
    private var truncated = false
    private var stopRequested = false

    init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = max(0, maximumBytes)
    }

    var data: Data {
        lock.withFeedbackLock { storedData }
    }

    var wasTruncated: Bool {
        lock.withFeedbackLock { truncated }
    }

    func stop() {
        lock.withFeedbackLock {
            stopRequested = true
        }
    }

    func start(in group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                group.leave()
            }

            let descriptor = handle.fileDescriptor
            let currentFlags = Darwin.fcntl(descriptor, F_GETFL)
            if currentFlags >= 0 {
                _ = Darwin.fcntl(
                    descriptor,
                    F_SETFL,
                    currentFlags | O_NONBLOCK
                )
            }

            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while !shouldStop {
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(&pollDescriptor, 1, 100)
                if pollResult == 0 {
                    continue
                }
                if pollResult < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }

                let readCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
                if readCount == 0 {
                    return
                }
                if readCount < 0 {
                    if errno == EINTR
                        || errno == EAGAIN
                        || errno == EWOULDBLOCK {
                        continue
                    }
                    return
                }

                let count = Int(readCount)
                lock.withFeedbackLock {
                    let remaining = max(0, maximumBytes - storedData.count)
                    if remaining > 0 {
                        storedData.append(
                            contentsOf: buffer.prefix(min(count, remaining))
                        )
                    }
                    if count > remaining {
                        truncated = true
                    }
                }
            }
        }
    }

    private var shouldStop: Bool {
        lock.withFeedbackLock { stopRequested }
    }
}

extension NSLock {
    nonisolated func withFeedbackLock<Value>(
        _ body: () throws -> Value
    ) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
