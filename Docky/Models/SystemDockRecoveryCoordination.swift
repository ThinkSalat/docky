import Darwin
import Foundation

nonisolated struct SystemDockRecoveryIdentity:
    Equatable,
    Sendable
{
    let ownerPID: Int32
    let sessionID: String
}

nonisolated enum SystemDockRecoveryDisposition:
    Equatable,
    Sendable
{
    case inactive
    case currentSession
    case liveForeignOwner
    case staleOwner
}

/// Classifies an active recovery generation without assuming that a PID alone
/// proves ownership. A different live PID may still be the Docky session that
/// created the snapshot, so it must be left untouched. If the recorded PID is
/// this process but the session token differs, the PID was recycled and the
/// old generation is stale.
nonisolated enum SystemDockRecoveryCoordinationPolicy {
    static func disposition(
        stateIsActive: Bool,
        restoreCompleted: Bool,
        ownerPID: Int32,
        currentPID: Int32,
        stateSessionID: String,
        currentSessionID: String,
        ownerProcessRunning: Bool
    ) -> SystemDockRecoveryDisposition {
        guard stateIsActive, !restoreCompleted else {
            return .inactive
        }

        if ownerPID > 0,
           ownerPID == currentPID,
           !stateSessionID.isEmpty,
           stateSessionID == currentSessionID {
            return .currentSession
        }

        if ownerPID > 0,
           ownerPID != currentPID,
           ownerProcessRunning {
            return .liveForeignOwner
        }

        return .staleOwner
    }

    static func generationMatches(
        expected: SystemDockRecoveryIdentity,
        actualOwnerPID: Int32,
        actualSessionID: String
    ) -> Bool {
        expected.ownerPID == actualOwnerPID
            && !expected.sessionID.isEmpty
            && expected.sessionID == actualSessionID
    }
}

nonisolated enum SystemDockRecoveryFileLockError:
    Error,
    LocalizedError
{
    case createDirectory(String)
    case open(String)
    case lock(String)

    var errorDescription: String? {
        switch self {
        case .createDirectory(let message):
            "Could not create the System Dock recovery directory: \(message)"
        case .open(let message):
            "Could not open the System Dock recovery lock: \(message)"
        case .lock(let message):
            "Could not lock the System Dock recovery state: \(message)"
        }
    }
}

/// Serializes every read-modify-write recovery transaction across Docky and
/// its watchdog. The lock file is deliberately stable and is never removed:
/// deleting an advisory lock file can let old and new descriptors protect
/// different inodes.
nonisolated enum SystemDockRecoveryFileLock {
    /// POSIX record locks are process-scoped, so serialize callers inside each
    /// process as well as taking the cross-process lock.
    private static let processLock = NSLock()

    static func withExclusiveLock<Result>(
        stateFileURL: URL,
        operation: () throws -> Result
    ) throws -> Result {
        processLock.lock()
        defer { processLock.unlock() }

        let directoryURL = stateFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw SystemDockRecoveryFileLockError.createDirectory(
                error.localizedDescription
            )
        }

        let lockFileURL = stateFileURL.appendingPathExtension("lock")
        let descriptor = lockFileURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw SystemDockRecoveryFileLockError.open(
                currentErrnoDescription()
            )
        }

        var lockResult: Int32
        repeat {
            lockResult = Darwin.lockf(descriptor, F_LOCK, 0)
        } while lockResult == -1 && errno == EINTR

        guard lockResult == 0 else {
            let message = currentErrnoDescription()
            Darwin.close(descriptor)
            throw SystemDockRecoveryFileLockError.lock(message)
        }

        defer {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
        }
        return try operation()
    }

    private static func currentErrnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
