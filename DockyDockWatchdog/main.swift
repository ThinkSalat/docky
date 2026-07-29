import CoreFoundation
import Darwin
import Foundation

private let dockDomain = "com.apple.dock" as CFString
private let snapshotKey = "docky.systemDockVisibilitySnapshot" as CFString
private let managedKeys = [
    "orientation",
    "autohide",
    "autohide-delay",
    "autohide-time-modifier",
    "no-bouncing",
    "launchanim"
]

private struct WatchdogState {
    let active: Bool
    let restoreCompleted: Bool
    let ownerPID: pid_t
    let sessionID: String
    let snapshot: [String: Any]
    let watchdogReady: Bool
    let watchdogPID: pid_t
}

private enum RecoveryOutcome {
    case completed
    case generationChanged
    case restoreFailed
    case tombstoneFailed
    case snapshotCleanupFailed
    case stateCleanupFailed
    case lockFailed
}

private enum SnapshotEntry {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
}

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    exit(64)
}

let stateFileURL = URL(fileURLWithPath: arguments[1])
let ownerPID = pid_t(Int32(arguments[2]) ?? 0)
let sessionID = arguments[3]
let dockyBundleIdentifier = arguments[4]

guard markWatchdogReady() else {
    exit(65)
}

while stateMatches() {
    if isProcessRunning(ownerPID) {
        Thread.sleep(forTimeInterval: 0.5)
    } else {
        break
    }
}

switch performRecoveryIfStillOwned() {
case .completed, .generationChanged:
    exit(0)
case .restoreFailed:
    exit(70)
case .snapshotCleanupFailed:
    exit(71)
case .stateCleanupFailed:
    exit(72)
case .lockFailed:
    exit(73)
case .tombstoneFailed:
    exit(74)
}

private func stateMatches() -> Bool {
    guard let state = try? SystemDockRecoveryFileLock.withExclusiveLock(
        stateFileURL: stateFileURL,
        operation: readState
    ) else {
        return false
    }

    return state.active
        && !state.restoreCompleted
        && state.ownerPID == ownerPID
        && state.sessionID == sessionID
}

private func readState() -> WatchdogState? {
    guard let plist = readRawState(),
          let snapshot = plist["snapshot"] as? [String: Any] else {
        return nil
    }

    return WatchdogState(
        active: boolValue(plist["active"]) ?? false,
        restoreCompleted:
            boolValue(plist["restoreCompleted"]) ?? false,
        ownerPID: pid_t(intValue(plist["ownerPID"]) ?? 0),
        sessionID: plist["sessionID"] as? String ?? "",
        snapshot: snapshot,
        watchdogReady:
            boolValue(plist["watchdogReady"]) ?? false,
        watchdogPID:
            pid_t(intValue(plist["watchdogPID"]) ?? 0)
    )
}

private func readRawState() -> [String: Any]? {
    guard let data = try? Data(contentsOf: stateFileURL),
          let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
          ) as? [String: Any] else {
        return nil
    }
    return plist
}

private func markWatchdogReady() -> Bool {
    do {
        return try SystemDockRecoveryFileLock.withExclusiveLock(
            stateFileURL: stateFileURL
        ) {
            guard var plist = readRawState(),
                  boolValue(plist["active"]) == true,
                  boolValue(plist["restoreCompleted"]) != true,
                  pid_t(intValue(plist["ownerPID"]) ?? 0) == ownerPID,
                  plist["sessionID"] as? String == sessionID,
                  let snapshot = plist["snapshot"] as? [String: Any],
                  decodeSnapshot(snapshot) != nil else {
                return false
            }

            let watchdogPID =
                Int(ProcessInfo.processInfo.processIdentifier)
            plist["watchdogReady"] = true
            plist["watchdogPID"] = watchdogPID

            guard writeRawState(plist),
                  let verified = readState() else {
                return false
            }
            return verified.active
                && !verified.restoreCompleted
                && verified.ownerPID == ownerPID
                && verified.sessionID == sessionID
                && verified.watchdogReady
                && verified.watchdogPID == pid_t(watchdogPID)
        }
    } catch {
        return false
    }
}

private func performRecoveryIfStillOwned() -> RecoveryOutcome {
    do {
        return try SystemDockRecoveryFileLock.withExclusiveLock(
            stateFileURL: stateFileURL
        ) {
            guard let state = readState(),
                  state.active,
                  !state.restoreCompleted,
                  state.ownerPID == ownerPID,
                  state.sessionID == sessionID,
                  let decoded = decodeSnapshot(state.snapshot)
            else {
                return .generationChanged
            }

            // Recheck owner liveness under the generation lock immediately
            // before touching com.apple.dock. A newly-live or replacement
            // owner makes this helper stale, so it must leave everything
            // untouched.
            guard !isProcessRunning(ownerPID) else {
                return .generationChanged
            }
            guard restoreSnapshot(decoded) else {
                return .restoreFailed
            }

            restartDock()

            // Completion is made durable before either recovery copy is
            // deleted. If cleanup fails, later launches only retry cleanup;
            // they never replay this old snapshot over newer user changes.
            guard markRecoveryCompleted() else {
                return .tombstoneFailed
            }
            guard clearDockySnapshot() else {
                return .snapshotCleanupFailed
            }
            guard removeCompletedStateFile() else {
                return .stateCleanupFailed
            }
            return .completed
        }
    } catch {
        return .lockFailed
    }
}

private func restoreSnapshot(
    _ decoded: [String: SnapshotEntry]
) -> Bool {

    for key in managedKeys {
        guard let entry = decoded[key] else {
            return false
        }
        restoreKey(key, from: entry)
    }

    guard CFPreferencesAppSynchronize(dockDomain) else {
        return false
    }

    return managedKeys.allSatisfy { key in
        guard let entry = decoded[key] else {
            return false
        }
        return restoredValueMatches(key: key, entry: entry)
    }
}

private func writeRawState(_ plist: [String: Any]) -> Bool {
    do {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: stateFileURL, options: .atomic)
        return true
    } catch {
        return false
    }
}

private func markRecoveryCompleted() -> Bool {
    guard var plist = readRawState(),
          boolValue(plist["active"]) == true,
          boolValue(plist["restoreCompleted"]) != true,
          pid_t(intValue(plist["ownerPID"]) ?? 0) == ownerPID,
          plist["sessionID"] as? String == sessionID else {
        return false
    }

    plist["active"] = false
    plist["restoreCompleted"] = true
    plist["watchdogReady"] = false
    plist["watchdogPID"] = 0
    guard writeRawState(plist),
          let verified = readState() else {
        return false
    }
    return !verified.active
        && verified.restoreCompleted
        && verified.ownerPID == ownerPID
        && verified.sessionID == sessionID
}

private func decodeSnapshot(
    _ snapshot: [String: Any]
) -> [String: SnapshotEntry]? {
    var decoded: [String: SnapshotEntry] = [:]
    for key in managedKeys {
        guard let rawEntry = snapshot[key] as? [String: Any],
              let type = rawEntry["type"] as? String
        else {
            return nil
        }

        switch type {
        case "null":
            decoded[key] = .null
        case "bool":
            guard let value = strictBooleanValue(rawEntry["value"]) else {
                return nil
            }
            decoded[key] = .boolean(value)
        case "number":
            guard let value = strictNumberValue(rawEntry["value"]) else {
                return nil
            }
            decoded[key] = .number(value)
        case "string":
            guard let value = rawEntry["value"] as? String else {
                return nil
            }
            decoded[key] = .string(value)
        default:
            return nil
        }
    }
    return decoded
}

private func restoreKey(_ key: String, from entry: SnapshotEntry) {
    switch entry {
    case .null:
        CFPreferencesSetAppValue(key as CFString, nil, dockDomain)
    case .boolean(let value):
        CFPreferencesSetAppValue(
            key as CFString,
            NSNumber(value: value),
            dockDomain
        )
    case .number(let value):
        CFPreferencesSetAppValue(
            key as CFString,
            NSNumber(value: value),
            dockDomain
        )
    case .string(let value):
        CFPreferencesSetAppValue(
            key as CFString,
            value as CFString,
            dockDomain
        )
    }
}

private func restoredValueMatches(
    key: String,
    entry: SnapshotEntry
) -> Bool {
    let observed = CFPreferencesCopyAppValue(
        key as CFString,
        dockDomain
    )

    switch entry {
    case .null:
        return observed == nil
    case .boolean(let expected):
        return strictBooleanValue(observed) == expected
    case .number(let expected):
        return strictNumberValue(observed) == expected
    case .string(let expected):
        return observed as? String == expected
    }
}

private func clearDockySnapshot() -> Bool {
    guard let state = readState(),
          !state.active,
          state.restoreCompleted,
          state.ownerPID == ownerPID,
          state.sessionID == sessionID else {
        return false
    }

    let domain = dockyBundleIdentifier as CFString
    CFPreferencesSetAppValue(snapshotKey, nil, domain)
    guard CFPreferencesAppSynchronize(domain) else {
        return false
    }
    return CFPreferencesCopyAppValue(snapshotKey, domain) == nil
}

private func removeCompletedStateFile() -> Bool {
    guard let state = readState(),
          !state.active,
          state.restoreCompleted,
          state.ownerPID == ownerPID,
          state.sessionID == sessionID else {
        return false
    }

    do {
        try FileManager.default.removeItem(at: stateFileURL)
        return !FileManager.default.fileExists(
            atPath: stateFileURL.path
        )
    } catch {
        return false
    }
}

private func restartDock() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["Dock"]
    try? process.run()
}

private func isProcessRunning(_ pid: pid_t) -> Bool {
    guard pid > 0 else {
        return false
    }

    return kill(pid, 0) == 0 || errno == EPERM
}

private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
        return value
    }

    if let value = value as? NSNumber {
        return value.boolValue
    }

    if let value = value as? String {
        switch value.lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    return nil
}

private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }

    if let value = value as? NSNumber {
        return value.intValue
    }

    if let value = value as? String {
        return Int(value)
    }

    return nil
}

private func strictBooleanValue(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
        return nil
    }
    return number.boolValue
}

private func strictNumberValue(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
        return nil
    }
    return number.doubleValue
}
