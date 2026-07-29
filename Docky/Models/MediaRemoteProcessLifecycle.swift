//
//  MediaRemoteProcessLifecycle.swift
//  Docky
//
//  Pure identity and lifecycle rules for Docky's MediaRemote adapter process.
//  The operating-system process inspection and signalling stay in
//  MediaPlaybackService; these rules are independently testable.
//

import Foundation

nonisolated struct MediaRemoteAdapterCommand: Equatable, Sendable {
    let executablePath: String
    let scriptPath: String
    let frameworkPath: String

    var arguments: [String] {
        [
            executablePath,
            scriptPath,
            frameworkPath,
            "stream",
        ]
    }
}

nonisolated struct MediaRemoteProcessSnapshot: Equatable, Sendable {
    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let executablePath: String
    let arguments: [String]
}

/// Matches only an adapter launched from this exact Docky bundle that has
/// already lost its parent. This intentionally rejects current children,
/// adapters belonging to another app, and even partially matching commands.
nonisolated enum MediaRemoteOrphanProcessPolicy {
    static func matchesOrphan(
        _ process: MediaRemoteProcessSnapshot,
        command: MediaRemoteAdapterCommand
    ) -> Bool {
        process.processIdentifier > 1
            && process.parentProcessIdentifier == 1
            && process.executablePath == command.executablePath
            && process.arguments == command.arguments
    }
}

/// Generation ownership prevents a delayed termination callback from an old
/// helper from clearing the reference to its replacement.
nonisolated struct MediaRemoteProcessLifecycleState: Equatable, Sendable {
    private(set) var activeGeneration: UInt64?
    private(set) var shutdownWasRequested = false
    private var nextGeneration: UInt64 = 0

    mutating func beginLaunch() -> UInt64? {
        guard !shutdownWasRequested else {
            return nil
        }

        nextGeneration &+= 1
        if nextGeneration == 0 {
            nextGeneration = 1
        }
        activeGeneration = nextGeneration
        return nextGeneration
    }

    mutating func acceptTermination(generation: UInt64) -> Bool {
        guard activeGeneration == generation else {
            return false
        }
        activeGeneration = nil
        return true
    }

    /// Returns true only for the first shutdown request.
    mutating func beginShutdown() -> Bool {
        guard !shutdownWasRequested else {
            return false
        }
        shutdownWasRequested = true
        activeGeneration = nil
        return true
    }
}

nonisolated enum MediaRemoteTerminationOutcome: Equatable, Sendable {
    case alreadyExited
    case terminated
    case forceKilled
    case stillRunning
}

/// Injected operations keep the bounded TERM/KILL/reap algorithm testable
/// without creating or signalling real processes.
nonisolated struct MediaRemoteTerminationOperations {
    let isRunning: () -> Bool
    let requestTermination: () -> Void
    let forceTermination: () -> Void
    let reap: () -> Void
    let pause: (TimeInterval) -> Void
}

nonisolated enum MediaRemoteProcessTerminator {
    static func terminate(
        using operations: MediaRemoteTerminationOperations,
        pollInterval: TimeInterval = 0.01,
        gracefulPollLimit: Int = 25,
        forcedPollLimit: Int = 25
    ) -> MediaRemoteTerminationOutcome {
        guard operations.isRunning() else {
            operations.reap()
            return .alreadyExited
        }

        operations.requestTermination()
        if waitUntilStopped(
            using: operations,
            pollInterval: pollInterval,
            pollLimit: gracefulPollLimit
        ) {
            operations.reap()
            return .terminated
        }

        operations.forceTermination()
        if waitUntilStopped(
            using: operations,
            pollInterval: pollInterval,
            pollLimit: forcedPollLimit
        ) {
            operations.reap()
            return .forceKilled
        }

        // Never make an unbounded waitUntilExit-style call while the process
        // still reports itself as running.
        return .stillRunning
    }

    private static func waitUntilStopped(
        using operations: MediaRemoteTerminationOperations,
        pollInterval: TimeInterval,
        pollLimit: Int
    ) -> Bool {
        for _ in 0..<max(0, pollLimit) {
            guard operations.isRunning() else {
                return true
            }
            operations.pause(max(0, pollInterval))
        }
        return !operations.isRunning()
    }
}
