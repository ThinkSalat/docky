//
//  BoundedProcessRunner.swift
//  Docky
//
//  Cancellation-aware subprocess execution with concurrent, bounded pipe
//  draining. Theme ZIP tooling uses fixed executable URLs and output limits.
//

import Darwin
import Foundation

nonisolated struct BoundedProcessResult: Sendable {
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

nonisolated enum BoundedProcessError: LocalizedError, Equatable {
    case timedOut
    case outputWouldNotDrain
    case wouldNotTerminate

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The archive operation took too long and was stopped."
        case .outputWouldNotDrain:
            return "The archive process did not close its output streams."
        case .wouldNotTerminate:
            return "The archive process could not be stopped."
        }
    }
}

nonisolated enum BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int
    ) async throws -> BoundedProcessResult {
        let cancellation = ProcessCancellationSignal()
        let operation = Task.detached(priority: .utility) {
            try runSynchronously(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout,
                maximumStandardOutputBytes: maximumStandardOutputBytes,
                maximumStandardErrorBytes: maximumStandardErrorBytes,
                cancellation: cancellation
            )
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            cancellation.cancel()
            operation.cancel()
        }
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int,
        cancellation: ProcessCancellationSignal
    ) throws -> BoundedProcessResult {
        try cancellation.check()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // Do not inherit UNZIP/ZIPINFO/DITTO option variables from a shell or
        // launcher. Fixed executables plus a small environment make archive
        // interpretation deterministic.
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

        let outputDrain = BoundedPipeDrain(
            handle: outputPipe.fileHandleForReading,
            maximumBytes: maximumStandardOutputBytes
        )
        let errorDrain = BoundedPipeDrain(
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
            if cancellation.isCancelled || Task.isCancelled {
                terminalError = CancellationError()
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                terminalError = BoundedProcessError.timedOut
                break
            }
        }

        if terminalError != nil {
            if process.isRunning {
                process.terminate()
            }
            if processExited.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                if processExited.wait(
                    timeout: .now() + 2
                ) == .timedOut {
                    outputDrain.stop()
                    errorDrain.stop()
                    _ = drainGroup.wait(timeout: .now() + 1)
                    throw BoundedProcessError.wouldNotTerminate
                }
            }
        }

        // Bound the drain phase too. A descendant must not keep inherited
        // stdout/stderr descriptors open forever after the direct child exits.
        if drainGroup.wait(timeout: .now() + 2) == .timedOut {
            outputDrain.stop()
            errorDrain.stop()
            guard drainGroup.wait(timeout: .now() + 1) == .success else {
                throw BoundedProcessError.outputWouldNotDrain
            }
            if let terminalError {
                throw terminalError
            }
            throw BoundedProcessError.outputWouldNotDrain
        }

        if let terminalError {
            throw terminalError
        }
        try cancellation.check()
        return BoundedProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputDrain.data,
            standardError: errorDrain.data,
            standardOutputWasTruncated: outputDrain.wasTruncated,
            standardErrorWasTruncated: errorDrain.wasTruncated
        )
    }

    private static func stopDrainsIfNeeded(
        _ outputDrain: BoundedPipeDrain,
        _ errorDrain: BoundedPipeDrain,
        group: DispatchGroup
    ) {
        guard group.wait(timeout: .now() + 1) == .timedOut else {
            return
        }
        outputDrain.stop()
        errorDrain.stop()
        _ = group.wait(timeout: .now() + 1)
    }
}

private nonisolated final class ProcessCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }
}

private nonisolated final class BoundedPipeDrain: @unchecked Sendable {
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
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
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
                    if errno == EINTR { continue }
                    return
                }

                let readCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
                if readCount == 0 { return }
                if readCount < 0 {
                    if errno == EINTR || errno == EAGAIN {
                        continue
                    }
                    return
                }

                lock.lock()
                let remaining = maximumBytes - storedData.count
                if remaining > 0 {
                    storedData.append(
                        contentsOf: buffer.prefix(min(readCount, remaining))
                    )
                }
                if readCount > max(0, remaining) {
                    truncated = true
                }
                lock.unlock()
            }
        }
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }
}
