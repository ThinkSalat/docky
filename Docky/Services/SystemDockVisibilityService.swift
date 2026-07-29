//
//  SystemDockVisibilityService.swift
//  Docky
//
//  Hides the macOS Dock by writing to com.apple.dock preferences
//  (autohide on, large delay, instant animation, no bouncing, no launch
//  animation). The user's previous values are snapshotted before the first
//  overwrite so they can be restored when the preference is turned off or
//  when Docky quits.
//

import AppKit
import Darwin
import Foundation

final class SystemDockVisibilityService {
    static let shared = SystemDockVisibilityService()

    private static let dockDomain = "com.apple.dock" as CFString
    private static let snapshotKey = "docky.systemDockVisibilitySnapshot"
    private static let snapshotNullMarker = "__docky_null__"
    private static let stateFilename = "SystemDockVisibilityState.plist"
    private static let fallbackBundleIdentifier = "gt.quintero.Docky"
    private static let watchdogAppName = "DockyDockWatchdog.app"

    private static let managedKeys: [String] = [
        "orientation",
        "autohide",
        "autohide-delay",
        "autohide-time-modifier",
        "no-bouncing",
        "launchanim"
    ]

    private static let hiddenValues: [String: CFPropertyList] = [
        "autohide": true as CFBoolean,
        "autohide-delay": 1000.0 as CFNumber,
        "autohide-time-modifier": 0.0 as CFNumber,
        "no-bouncing": true as CFBoolean,
        "launchanim": false as CFBoolean
    ]

    private let defaults = UserDefaults.standard
    private let sessionID = UUID().uuidString.lowercased()
    private var isWatchdogLaunchPendingOrRunning = false
    private var watchdogProcess: Process?

    private init() {}

    private struct VisibilityState {
        let active: Bool
        let restoreCompleted: Bool
        let ownerPID: pid_t
        let sessionID: String
        let snapshot: [String: Any]?
        let watchdogReady: Bool
        let watchdogPID: pid_t
    }

    private enum RestoreAuthorization {
        case currentSession(SystemDockRecoveryIdentity)
        case staleOwner(SystemDockRecoveryIdentity)
        case noActiveState
    }

    private struct TransactionFailure: Error {
        let message: String
    }

    var hasSnapshot: Bool {
        defaults.dictionary(forKey: Self.snapshotKey) != nil
    }

    @discardableResult
    func recoverStaleSnapshotIfNeeded()
        -> SystemDockVisibilityMutationResult
    {
        do {
            return try withRecoveryLock {
                recoverStaleSnapshotLocked()
            }
        } catch let failure as TransactionFailure {
            return fail(failure.message)
        } catch {
            return fail(
                "Docky could not lock the System Dock recovery state: "
                    + error.localizedDescription
            )
        }
    }

    private func recoverStaleSnapshotLocked()
        -> SystemDockVisibilityMutationResult
    {
        let state = readVisibilityState()
        let ownerPID = state?.ownerPID ?? 0
        let ownerProcessRunning = isProcessRunning(ownerPID)
        let disposition = SystemDockRecoveryCoordinationPolicy
            .disposition(
                stateIsActive: state?.active ?? false,
                restoreCompleted: state?.restoreCompleted ?? false,
                ownerPID: ownerPID,
                currentPID: ProcessInfo.processInfo.processIdentifier,
                stateSessionID: state?.sessionID ?? "",
                currentSessionID: sessionID,
                ownerProcessRunning: ownerProcessRunning
            )
        let hasStaleActiveState =
            disposition == .staleOwner
        let hasLegacySnapshot =
            state?.active != true
            && state?.restoreCompleted != true
            && hasSnapshot
        DiagnosticsTrace.shared.record(.systemDock, "staleSnapshotEvaluated", fields: [
            "statePresent": state != nil,
            "stateActive": state?.active ?? false,
            "restoreCompleted": state?.restoreCompleted ?? false,
            "ownerProcessRunning": ownerProcessRunning,
            "ownerPIDMatchesCurrentProcess":
                ownerPID == ProcessInfo.processInfo.processIdentifier,
            "sessionMatchesCurrentSession":
                state?.sessionID == sessionID,
            "disposition": String(describing: disposition),
            "hasPreferenceSnapshot": hasSnapshot,
            "hasStaleActiveState": hasStaleActiveState,
            "hasLegacySnapshot": hasLegacySnapshot,
        ])

        if let state, state.restoreCompleted {
            let identity = SystemDockRecoveryIdentity(
                ownerPID: state.ownerPID,
                sessionID: state.sessionID
            )
            switch clearRecoveryMetadataLocked(
                expectedIdentity: identity
            ) {
            case .success:
                return .restored
            case .failure(let failure):
                return fail(failure.message)
            }
        }

        if disposition == .liveForeignOwner {
            return fail(
                "Another running Docky session owns the System Dock "
                    + "recovery snapshot. Docky left that session's settings "
                    + "and recovery data untouched."
            )
        }

        guard hasStaleActiveState || hasLegacySnapshot else {
            return .restored
        }

        let snapshot =
            state?.snapshot
            ?? defaults.dictionary(forKey: Self.snapshotKey)
        let authorization: RestoreAuthorization
        if hasStaleActiveState, let state {
            authorization = .staleOwner(
                SystemDockRecoveryIdentity(
                    ownerPID: state.ownerPID,
                    sessionID: state.sessionID
                )
            )
        } else {
            authorization = .noActiveState
        }
        return restoreLocked(
            using: snapshot,
            authorization: authorization
        )
    }

    @discardableResult
    func hide() -> SystemDockVisibilityMutationResult {
        DiagnosticsTrace.shared.record(.systemDock, "hideRequested", fields: [
            "hadSnapshot": hasSnapshot,
        ])

        let preparation: Result<[String: Any], TransactionFailure>
        do {
            preparation = try withRecoveryLock {
                prepareHideLocked()
            }
        } catch let failure as TransactionFailure {
            return fail(failure.message)
        } catch {
            return fail(error.localizedDescription)
        }

        let snapshot: [String: Any]
        switch preparation {
        case .success(let persistedSnapshot):
            snapshot = persistedSnapshot
        case .failure(let failure):
            return fail(failure.message)
        }

        switch startWatchdogIfNeeded() {
        case .success:
            break
        case .failure(let failure):
            return fail(
                failure.message
                    + " The recovery snapshot was retained; no additional "
                    + "Dock settings were changed."
            )
        }

        let hiddenResult: Result<Void, TransactionFailure>
        do {
            hiddenResult = try withRecoveryLock {
                applyHiddenValuesLocked(snapshot: snapshot)
            }
        } catch let failure as TransactionFailure {
            return fail(failure.message)
        } catch {
            return fail(error.localizedDescription)
        }

        switch hiddenResult {
        case .success:
            return .hidden
        case .failure(let failure):
            return fail(failure.message)
        }
    }

    private func prepareHideLocked()
        -> Result<[String: Any], TransactionFailure>
    {
        if let state = readVisibilityState() {
            if state.restoreCompleted {
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky has a completed System Dock recovery "
                            + "record that could not yet be cleaned up. No "
                            + "new recovery generation was created."
                    )
                )
            }

            if state.active {
                let disposition =
                    SystemDockRecoveryCoordinationPolicy.disposition(
                        stateIsActive: state.active,
                        restoreCompleted: state.restoreCompleted,
                        ownerPID: state.ownerPID,
                        currentPID:
                            ProcessInfo.processInfo.processIdentifier,
                        stateSessionID: state.sessionID,
                        currentSessionID: sessionID,
                        ownerProcessRunning:
                            isProcessRunning(state.ownerPID)
                    )
                guard disposition == .currentSession else {
                    let ownerDescription =
                        disposition == .liveForeignOwner
                        ? "another running Docky session"
                        : "a stale Docky session"
                    return .failure(
                        TransactionFailure(
                            message:
                                "Docky did not hide the System Dock because "
                                + "\(ownerDescription) owns the recovery "
                                + "record. Recover that generation before "
                                + "creating a new one."
                        )
                    )
                }
            }
        }

        let snapshot: [String: Any]
        switch persistedSnapshotForHide() {
        case .success(let persisted):
            snapshot = persisted
        case .failure(let failure):
            return .failure(failure)
        }

        switch writeActiveStateLocked(snapshot: snapshot) {
        case .success:
            return .success(snapshot)
        case .failure(let failure):
            return .failure(
                TransactionFailure(
                    message:
                        failure.message
                        + " Recovery metadata was retained for safe "
                        + "inspection or retry."
                )
            )
        }
    }

    private func applyHiddenValuesLocked(
        snapshot: [String: Any]
    ) -> Result<Void, TransactionFailure> {
        guard currentActiveStateMatches(snapshot: snapshot) else {
            return .failure(
                TransactionFailure(
                    message:
                        "The System Dock recovery owner changed before the "
                        + "hidden settings were applied. No Dock settings "
                        + "were changed."
                )
            )
        }

        switch applyHiddenValues() {
        case .success:
            restartDock()
            return .success(())
        case .failure(let failure):
            let rollback = applySnapshot(snapshot)
            let rollbackDetail: String
            switch rollback {
            case .success:
                restartDock()
                let completion = completeRecoveryLocked(
                    snapshot: snapshot,
                    authorization: .currentSession(currentStateIdentity)
                )
                switch completion {
                case .success:
                    rollbackDetail =
                        " The original Dock settings were restored."
                case .failure(let completionFailure):
                    rollbackDetail =
                        " The original Dock settings were restored, but "
                        + completionFailure.message
                }
            case .failure(let rollbackFailure):
                rollbackDetail =
                    " Rollback also failed: \(rollbackFailure.message) "
                    + "The recovery snapshot was retained."
            }
            return .failure(
                TransactionFailure(
                    message: failure.message + rollbackDetail
                )
            )
        }
    }

    @discardableResult
    func setOrientation(
        _ orientation: DockSettingsService.Orientation
    ) -> SystemDockVisibilityMutationResult {
        DiagnosticsTrace.shared.record(.systemDock, "orientationWriteRequested", fields: [
            "orientation": orientation.rawValue,
        ])

        do {
            return try withRecoveryLock {
                guard let state = readVisibilityState(),
                      !state.restoreCompleted,
                      SystemDockRecoveryCoordinationPolicy.disposition(
                        stateIsActive: state.active,
                        restoreCompleted: state.restoreCompleted,
                        ownerPID: state.ownerPID,
                        currentPID:
                            ProcessInfo.processInfo.processIdentifier,
                        stateSessionID: state.sessionID,
                        currentSessionID: sessionID,
                        ownerProcessRunning:
                            isProcessRunning(state.ownerPID)
                      ) == .currentSession,
                      state.snapshot != nil,
                      hasSnapshot
                else {
                    return fail(
                        "Docky did not change the System Dock orientation "
                            + "because this session has no verified recovery "
                            + "snapshot."
                    )
                }

                let expected: [String: Any] = [
                    "orientation": orientation.rawValue,
                ]
                switch applyDockValues(
                    expected,
                    eventName: "orientationApplied"
                ) {
                case .success:
                    restartDock()
                    return .hidden
                case .failure(let failure):
                    return fail(failure.message)
                }
            }
        } catch let failure as TransactionFailure {
            return fail(failure.message)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    @discardableResult
    func restore() -> SystemDockVisibilityMutationResult {
        DiagnosticsTrace.shared.record(.systemDock, "restoreRequested", fields: [
            "hasSnapshot": hasSnapshot,
        ])
        do {
            return try withRecoveryLock {
                let state = readVisibilityState()
                let preferenceSnapshot =
                    defaults.dictionary(forKey: Self.snapshotKey)
                guard state != nil || preferenceSnapshot != nil else {
                    return .restored
                }
                if let state, state.restoreCompleted {
                    let identity = SystemDockRecoveryIdentity(
                        ownerPID: state.ownerPID,
                        sessionID: state.sessionID
                    )
                    switch clearRecoveryMetadataLocked(
                        expectedIdentity: identity
                    ) {
                    case .success:
                        return .restored
                    case .failure(let failure):
                        return fail(failure.message)
                    }
                }
                guard let state,
                      SystemDockRecoveryCoordinationPolicy.disposition(
                        stateIsActive: state.active,
                        restoreCompleted: state.restoreCompleted,
                        ownerPID: state.ownerPID,
                        currentPID:
                            ProcessInfo.processInfo.processIdentifier,
                        stateSessionID: state.sessionID,
                        currentSessionID: sessionID,
                        ownerProcessRunning:
                            isProcessRunning(state.ownerPID)
                      ) == .currentSession
                else {
                    return fail(
                        "Docky's System Dock recovery state is not owned by "
                            + "this running session. It was left untouched "
                            + "so another session's snapshot cannot be "
                            + "restored or erased."
                    )
                }

                let identity = SystemDockRecoveryIdentity(
                    ownerPID: state.ownerPID,
                    sessionID: state.sessionID
                )
                let snapshot = state.snapshot ?? preferenceSnapshot
                return restoreLocked(
                    using: snapshot,
                    authorization: .currentSession(identity)
                )
            }
        } catch let failure as TransactionFailure {
            return fail(failure.message)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func restoreLocked(
        using snapshot: [String: Any]?,
        authorization: RestoreAuthorization
    ) -> SystemDockVisibilityMutationResult {
        guard let snapshot else {
            if readVisibilityState()?.active == true {
                return fail(
                    "The System Dock recovery state is active, but its "
                        + "snapshot is unavailable. No settings were erased."
                )
            }
            DiagnosticsTrace.shared.record(.systemDock, "restoreSkipped", fields: [
                "reason": "snapshotUnavailable",
            ])
            return .restored
        }

        DiagnosticsTrace.shared.record(.systemDock, "restoreApplyingSnapshot", fields: [
            "managedKeyCount": snapshot.count,
        ])

        // This generation and liveness check deliberately sits immediately
        // before the external preference write while the cross-process lock
        // is held. An old helper cannot validate A and then apply A after B
        // has become the authoritative generation.
        guard restoreAuthorizedLocked(authorization) else {
            return fail(
                "The System Dock recovery owner or liveness changed before "
                    + "restore. No recovery values or metadata were modified."
            )
        }
        switch applySnapshot(snapshot) {
        case .success:
            break
        case .failure(let failure):
            return fail(
                failure.message
                    + " The recovery snapshot was retained for retry."
            )
        }

        restartDock()

        switch completeRecoveryLocked(
            snapshot: snapshot,
            authorization: authorization
        ) {
        case .success:
            break
        case .failure(let failure):
            return fail(
                failure.message
                    + " The restored values were verified, and remaining "
                    + "recovery metadata was retained where possible."
            )
        }

        DiagnosticsTrace.shared.record(.systemDock, "restoreCompleted")
        return .restored
    }

    private func captureSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for key in Self.managedKeys {
            if let value = CFPreferencesCopyAppValue(key as CFString, Self.dockDomain) {
                snapshot[key] = value
            } else {
                snapshot[key] = Self.snapshotNullMarker
            }
        }
        DiagnosticsTrace.shared.record(.systemDock, "snapshotCaptured", fields: [
            "managedKeyCount": snapshot.count,
        ])
        return snapshot
    }

    private func persistedSnapshotForHide()
        -> Result<[String: Any], TransactionFailure>
    {
        if let persisted = defaults.dictionary(forKey: Self.snapshotKey) {
            guard isCompleteSupportedSnapshot(persisted) else {
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky's existing System Dock recovery snapshot "
                            + "is incomplete or invalid, so no Dock settings "
                            + "were changed."
                    )
                )
            }
            return .success(persisted)
        }

        let snapshot = captureSnapshot()
        guard isCompleteSupportedSnapshot(snapshot) else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky could not safely represent every current "
                        + "System Dock setting, so no Dock settings were changed."
                )
            )
        }
        defaults.set(snapshot, forKey: Self.snapshotKey)
        guard defaults.synchronize(),
              let persisted = defaults.dictionary(
                  forKey: Self.snapshotKey
              ),
              snapshotsEqual(snapshot, persisted)
        else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky could not durably save the System Dock "
                        + "recovery snapshot, so no Dock settings were changed."
                )
            )
        }
        return .success(persisted)
    }

    private func applyHiddenValues()
        -> Result<Void, TransactionFailure>
    {
        applyDockValues(
            Self.hiddenValues,
            eventName: "hiddenValuesApplied"
        )
    }

    private func applySnapshot(
        _ snapshot: [String: Any]
    ) -> Result<Void, TransactionFailure> {
        guard isCompleteSupportedSnapshot(snapshot) else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky rejected an incomplete or invalid System Dock "
                        + "recovery snapshot."
                )
            )
        }

        let managedSnapshot = Dictionary(
            uniqueKeysWithValues: Self.managedKeys.compactMap { key in
                snapshot[key].map { (key, $0) }
            }
        )
        return applyDockValues(
            managedSnapshot,
            eventName: "snapshotApplied"
        )
    }

    private func applyDockValues(
        _ values: [String: Any],
        eventName: String
    ) -> Result<Void, TransactionFailure> {
        if let invalidKey = values.first(where: {
            snapshotValue($0.value) == .unsupported
        })?.key {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky rejected an invalid recovery value "
                        + "for \(invalidKey)."
                )
            )
        }

        for (key, stored) in values {
            switch snapshotValue(stored) {
            case .null:
                CFPreferencesSetAppValue(
                    key as CFString,
                    nil,
                    Self.dockDomain
                )
            case .boolean, .number, .string:
                let propertyList = stored as CFPropertyList
                CFPreferencesSetAppValue(
                    key as CFString,
                    propertyList,
                    Self.dockDomain
                )
            case .unsupported:
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky rejected an invalid recovery value "
                            + "for \(key)."
                    )
                )
            }
        }

        guard CFPreferencesAppSynchronize(Self.dockDomain) else {
            return .failure(
                TransactionFailure(
                    message:
                        "macOS did not synchronize the requested System "
                        + "Dock settings."
                )
            )
        }

        guard dockValuesMatch(values) else {
            return .failure(
                TransactionFailure(
                    message:
                        "macOS did not confirm every requested System Dock "
                        + "setting."
                )
            )
        }

        DiagnosticsTrace.shared.record(.systemDock, eventName, fields: [
            "managedKeyCount": values.count,
        ])
        return .success(())
    }

    private func dockValuesMatch(_ expected: [String: Any]) -> Bool {
        expected.allSatisfy { key, expectedValue in
            let observed = CFPreferencesCopyAppValue(
                key as CFString,
                Self.dockDomain
            )
            return snapshotValue(observed)
                == snapshotValue(expectedValue)
        }
    }

    private func snapshotsEqual(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        Self.managedKeys.allSatisfy { key in
            snapshotValue(lhs[key]) == snapshotValue(rhs[key])
        }
    }

    private func isCompleteSupportedSnapshot(
        _ snapshot: [String: Any]
    ) -> Bool {
        Self.managedKeys.allSatisfy { key in
            guard let stored = snapshot[key] else {
                return false
            }
            return snapshotValue(stored) != .unsupported
        }
    }

    private func snapshotValue(_ value: Any?) -> SystemDockSnapshotScalar {
        SystemDockSnapshotTypingPolicy.scalar(
            for: value,
            nullMarker: Self.snapshotNullMarker
        )
    }

    private func fail(
        _ message: String
    ) -> SystemDockVisibilityMutationResult {
        DiagnosticsTrace.shared.record(
            .systemDock,
            "visibilityMutationFailed",
            fields: [
                "error":
                    DiagnosticPrivacy.redactedTextDescriptor(message),
            ]
        )
        return .failed(message)
    }

    private func restartDock() {
        let dockApplications = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
        var terminationRequestCount = 0
        dockApplications.forEach {
            if $0.forceTerminate() {
                terminationRequestCount += 1
            }
        }
        DiagnosticsTrace.shared.record(.systemDock, "restartRequested", fields: [
            "runningDockProcessCount": dockApplications.count,
            "acceptedTerminationCount": terminationRequestCount,
        ])
    }

    private var stateFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Docky", isDirectory: true)
            .appendingPathComponent(Self.stateFilename)
    }

    private func withRecoveryLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        guard let stateFileURL else {
            throw TransactionFailure(
                message:
                    "Docky could not resolve the System Dock recovery state "
                    + "location, so no Dock settings were changed."
            )
        }

        do {
            return try SystemDockRecoveryFileLock.withExclusiveLock(
                stateFileURL: stateFileURL,
                operation: operation
            )
        } catch let failure as TransactionFailure {
            throw failure
        } catch {
            throw TransactionFailure(
                message:
                    "Docky could not safely lock the System Dock recovery "
                    + "state: \(error.localizedDescription)"
            )
        }
    }

    private func writeActiveStateLocked(
        snapshot: [String: Any]
    ) -> Result<Void, TransactionFailure> {
        guard let stateFileURL else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky could not resolve the System Dock recovery "
                        + "state location, so no Dock settings were changed."
                )
            )
        }

        do {
            if let state = readVisibilityState() {
                guard !state.restoreCompleted else {
                    return .failure(
                        TransactionFailure(
                            message:
                                "Docky refused to overwrite a completed "
                                + "System Dock recovery record."
                        )
                    )
                }
                if state.active {
                    let disposition =
                        SystemDockRecoveryCoordinationPolicy.disposition(
                            stateIsActive: state.active,
                            restoreCompleted: state.restoreCompleted,
                            ownerPID: state.ownerPID,
                            currentPID:
                                ProcessInfo.processInfo.processIdentifier,
                            stateSessionID: state.sessionID,
                            currentSessionID: sessionID,
                            ownerProcessRunning:
                                isProcessRunning(state.ownerPID)
                        )
                    guard disposition == .currentSession else {
                        return .failure(
                            TransactionFailure(
                                message:
                                    "Docky refused to overwrite another "
                                    + "System Dock recovery generation."
                            )
                        )
                    }
                }
            }

            let existingWatchdog = verifiedCurrentWatchdogProcess()

            guard isCompleteSupportedSnapshot(snapshot) else {
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky rejected an incomplete or invalid System "
                            + "Dock recovery snapshot before writing state."
                    )
                )
            }

            let state: [String: Any] = [
                "active": true,
                "restoreCompleted": false,
                "ownerPID": Int(ProcessInfo.processInfo.processIdentifier),
                "sessionID": sessionID,
                "snapshot": serializedSnapshot(snapshot),
                "watchdogReady": existingWatchdog != nil,
                "watchdogPID":
                    Int(existingWatchdog?.processIdentifier ?? 0),
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: state,
                format: .xml,
                options: 0
            )
            try data.write(to: stateFileURL, options: .atomic)

            guard let persisted = readVisibilityState(),
                  persisted.active,
                  !persisted.restoreCompleted,
                  persisted.ownerPID
                      == ProcessInfo.processInfo.processIdentifier,
                  persisted.sessionID == sessionID,
                  let persistedSnapshot = persisted.snapshot,
                  snapshotsEqual(snapshot, persistedSnapshot)
            else {
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky could not verify its durable System Dock "
                            + "recovery state, so no Dock settings were changed."
                    )
                )
            }

            DiagnosticsTrace.shared.record(.systemDock, "watchdogStateWritten", fields: [
                "snapshotKeyCount": snapshot.count,
                "encodedBytes": data.count,
            ])
            return .success(())
        } catch {
            NSLog("[Docky] Failed to write system Dock visibility watchdog state: \(error.localizedDescription)")
            DiagnosticsTrace.shared.record(.systemDock, "watchdogStateWriteFailed", fields: [
                "errorType": String(describing: type(of: error)),
            ])
            return .failure(
                TransactionFailure(
                    message:
                        "Docky could not durably save its System Dock "
                        + "recovery state: \(error.localizedDescription)"
                )
            )
        }
    }

    private func completeRecoveryLocked(
        snapshot: [String: Any],
        authorization: RestoreAuthorization
    ) -> Result<Void, TransactionFailure> {
        let identity: SystemDockRecoveryIdentity
        switch authorization {
        case .currentSession(let expected),
             .staleOwner(let expected):
            identity = expected
        case .noActiveState:
            identity = currentStateIdentity
        }

        switch markRecoveryCompletedLocked(
            snapshot: snapshot,
            authorization: authorization,
            completedIdentity: identity
        ) {
        case .success:
            break
        case .failure(let failure):
            return .failure(failure)
        }

        return clearRecoveryMetadataLocked(
            expectedIdentity: identity
        )
    }

    private func markRecoveryCompletedLocked(
        snapshot: [String: Any],
        authorization: RestoreAuthorization,
        completedIdentity: SystemDockRecoveryIdentity
    ) -> Result<Void, TransactionFailure> {
        guard let stateFileURL else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky restored the System Dock but could not resolve "
                        + "the recovery state location."
                )
            )
        }

        var plist: [String: Any]
        switch authorization {
        case .currentSession(let expected),
             .staleOwner(let expected):
            guard var existing = readRawVisibilityState(),
                  boolValue(existing["active"]) == true,
                  boolValue(existing["restoreCompleted"]) != true,
                  SystemDockRecoveryCoordinationPolicy.generationMatches(
                    expected: expected,
                    actualOwnerPID:
                        pid_t(intValue(existing["ownerPID"]) ?? 0),
                    actualSessionID:
                        existing["sessionID"] as? String ?? ""
                  )
            else {
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky restored the System Dock but did not mark "
                            + "recovery complete because the generation "
                            + "changed."
                    )
                )
            }
            existing["active"] = false
            existing["restoreCompleted"] = true
            existing["watchdogReady"] = false
            existing["watchdogPID"] = 0
            plist = existing

        case .noActiveState:
            guard readVisibilityState()?.active != true else {
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky restored a legacy snapshot but did not "
                            + "mark it complete because a new active recovery "
                            + "generation appeared."
                    )
                )
            }
            plist = [
                "active": false,
                "restoreCompleted": true,
                "ownerPID": Int(completedIdentity.ownerPID),
                "sessionID": completedIdentity.sessionID,
                "snapshot": serializedSnapshot(snapshot),
                "watchdogReady": false,
                "watchdogPID": 0,
            ]
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky restored the System Dock but could not write "
                        + "its completed recovery tombstone: "
                        + error.localizedDescription
                )
            )
        }

        guard let completed = readVisibilityState(),
              !completed.active,
              completed.restoreCompleted,
              SystemDockRecoveryCoordinationPolicy.generationMatches(
                expected: completedIdentity,
                actualOwnerPID: completed.ownerPID,
                actualSessionID: completed.sessionID
              ),
              let persistedSnapshot = completed.snapshot,
              snapshotsEqual(snapshot, persistedSnapshot)
        else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky restored the System Dock but could not verify "
                        + "its completed recovery tombstone."
                )
            )
        }

        DiagnosticsTrace.shared.record(
            .systemDock,
            "recoveryMarkedCompleted"
        )
        return .success(())
    }

    private func clearCompletedStateLocked(
        expectedIdentity: SystemDockRecoveryIdentity
    )
        -> Result<Void, TransactionFailure>
    {
        guard let stateFileURL,
              let state = readVisibilityState(),
              !state.active,
              state.restoreCompleted,
              SystemDockRecoveryCoordinationPolicy.generationMatches(
                expected: expectedIdentity,
                actualOwnerPID: state.ownerPID,
                actualSessionID: state.sessionID
              )
        else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky did not remove the System Dock recovery state "
                        + "because it was not the expected completed "
                        + "generation."
                )
            )
        }

        do {
            try FileManager.default.removeItem(at: stateFileURL)
            guard !FileManager.default.fileExists(
                atPath: stateFileURL.path
            ) else {
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky could not verify removal of the System "
                            + "Dock recovery state."
                    )
                )
            }
            if watchdogProcess?.isRunning == true {
                watchdogProcess?.terminate()
            }
            watchdogProcess = nil
            isWatchdogLaunchPendingOrRunning = false
            DiagnosticsTrace.shared.record(.systemDock, "watchdogStateCleared")
            return .success(())
        } catch {
            NSLog("[Docky] Failed to clear system Dock visibility watchdog state: \(error.localizedDescription)")
            DiagnosticsTrace.shared.record(.systemDock, "watchdogStateClearFailed", fields: [
                "errorType": String(describing: type(of: error)),
            ])
            return .failure(
                TransactionFailure(
                    message:
                        "Docky restored the System Dock but could not clear "
                        + "its recovery state: \(error.localizedDescription)"
                )
            )
        }
    }

    private func clearRecoveryMetadataLocked(
        expectedIdentity: SystemDockRecoveryIdentity
    )
        -> Result<Void, TransactionFailure>
    {
        guard let state = readVisibilityState(),
              !state.active,
              state.restoreCompleted,
              SystemDockRecoveryCoordinationPolicy.generationMatches(
                expected: expectedIdentity,
                actualOwnerPID: state.ownerPID,
                actualSessionID: state.sessionID
              )
        else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky did not clear System Dock recovery metadata "
                        + "because its completed generation changed."
                )
            )
        }

        defaults.removeObject(forKey: Self.snapshotKey)
        guard defaults.synchronize(),
              defaults.object(forKey: Self.snapshotKey) == nil
        else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky restored the System Dock but could not clear "
                        + "the saved recovery snapshot."
                )
            )
        }

        guard let stateAfterSnapshotClear = readVisibilityState(),
              !stateAfterSnapshotClear.active,
              stateAfterSnapshotClear.restoreCompleted,
              SystemDockRecoveryCoordinationPolicy.generationMatches(
                expected: expectedIdentity,
                actualOwnerPID: stateAfterSnapshotClear.ownerPID,
                actualSessionID: stateAfterSnapshotClear.sessionID
              )
        else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky did not remove System Dock recovery state "
                        + "because the completed generation changed while "
                        + "clearing its snapshot."
                )
            )
        }

        return clearCompletedStateLocked(
            expectedIdentity: expectedIdentity
        )
    }

    private var currentStateIdentity: SystemDockRecoveryIdentity {
        SystemDockRecoveryIdentity(
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            sessionID: sessionID
        )
    }

    private func currentActiveStateMatches(
        snapshot: [String: Any]
    ) -> Bool {
        guard let state = readVisibilityState(),
              SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: state.active,
                restoreCompleted: state.restoreCompleted,
                ownerPID: state.ownerPID,
                currentPID: ProcessInfo.processInfo.processIdentifier,
                stateSessionID: state.sessionID,
                currentSessionID: sessionID,
                ownerProcessRunning: isProcessRunning(state.ownerPID)
              ) == .currentSession,
              let stateSnapshot = state.snapshot,
              snapshotsEqual(snapshot, stateSnapshot),
              let preferenceSnapshot =
                  defaults.dictionary(forKey: Self.snapshotKey),
              snapshotsEqual(snapshot, preferenceSnapshot)
        else {
            return false
        }
        return true
    }

    private func restoreAuthorizedLocked(
        _ authorization: RestoreAuthorization
    ) -> Bool {
        switch authorization {
        case .noActiveState:
            guard let state = readVisibilityState() else {
                return true
            }
            return !state.active && !state.restoreCompleted

        case .currentSession(let expected):
            guard let state = readVisibilityState(),
                  SystemDockRecoveryCoordinationPolicy.generationMatches(
                    expected: expected,
                    actualOwnerPID: state.ownerPID,
                    actualSessionID: state.sessionID
                  )
            else {
                return false
            }
            return SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: state.active,
                restoreCompleted: state.restoreCompleted,
                ownerPID: state.ownerPID,
                currentPID: ProcessInfo.processInfo.processIdentifier,
                stateSessionID: state.sessionID,
                currentSessionID: sessionID,
                ownerProcessRunning: isProcessRunning(state.ownerPID)
            ) == .currentSession

        case .staleOwner(let expected):
            guard let state = readVisibilityState(),
                  SystemDockRecoveryCoordinationPolicy.generationMatches(
                    expected: expected,
                    actualOwnerPID: state.ownerPID,
                    actualSessionID: state.sessionID
                  )
            else {
                return false
            }
            return SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: state.active,
                restoreCompleted: state.restoreCompleted,
                ownerPID: state.ownerPID,
                currentPID: ProcessInfo.processInfo.processIdentifier,
                stateSessionID: state.sessionID,
                currentSessionID: sessionID,
                ownerProcessRunning: isProcessRunning(state.ownerPID)
            ) == .staleOwner
        }
    }

    private func readRawVisibilityState() -> [String: Any]? {
        guard let stateFileURL,
              let data = try? Data(contentsOf: stateFileURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private func readVisibilityState() -> VisibilityState? {
        guard let plist = readRawVisibilityState() else {
            return nil
        }

        let snapshot =
            (plist["snapshot"] as? [String: Any])
                .flatMap(deserializedSnapshot)
        return VisibilityState(
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

    private func startWatchdogIfNeeded()
        -> Result<Void, TransactionFailure>
    {
        if let existingWatchdog = verifiedCurrentWatchdogProcess() {
            DiagnosticsTrace.shared.record(.systemDock, "watchdogLaunchSkipped", fields: [
                "reason": "verifiedAlreadyRunning",
                "pid": existingWatchdog.processIdentifier,
            ])
            return .success(())
        }

        if watchdogProcess?.isRunning == true {
            watchdogProcess?.terminate()
        }
        watchdogProcess = nil
        isWatchdogLaunchPendingOrRunning = false

        guard let stateFileURL else {
            return .failure(
                TransactionFailure(
                    message:
                        "Docky could not resolve the System Dock watchdog "
                        + "state location, so no Dock settings were changed."
                )
            )
        }

        let helperAppURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent(Self.watchdogAppName, isDirectory: true)
        let executableURL = helperAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("DockyDockWatchdog")
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            NSLog(
                "[Docky] Failed to locate executable System Dock watchdog "
                    + "at \(executableURL.path)"
            )
            return .failure(
                TransactionFailure(
                    message:
                        "Docky's executable System Dock recovery helper "
                        + "is missing, "
                        + "so no Dock settings were changed."
                )
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            stateFileURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            sessionID,
            Bundle.main.bundleIdentifier ?? Self.fallbackBundleIdentifier
        ]

        DiagnosticsTrace.shared.record(.systemDock, "watchdogLaunchRequested")
        do {
            try process.run()
        } catch {
            DiagnosticsTrace.shared.record(
                .systemDock,
                "watchdogLaunchFailed",
                fields: [
                    "errorType": String(
                        describing: type(of: error)
                    ),
                ]
            )
            return .failure(
                TransactionFailure(
                    message:
                        "Docky's System Dock recovery helper could not "
                        + "start, so no Dock settings were changed: "
                        + error.localizedDescription
                )
            )
        }

        watchdogProcess = process
        isWatchdogLaunchPendingOrRunning = true

        let deadline =
            Date().addingTimeInterval(1.0)
        repeat {
            guard process.isRunning else {
                watchdogProcess = nil
                isWatchdogLaunchPendingOrRunning = false
                return .failure(
                    TransactionFailure(
                        message:
                            "Docky's System Dock recovery helper exited "
                            + "before confirming readiness."
                    )
                )
            }

            if let readyState = readVisibilityState(),
               readyState.active,
               !readyState.restoreCompleted,
               readyState.ownerPID
                   == ProcessInfo.processInfo.processIdentifier,
               readyState.sessionID == sessionID,
               readyState.watchdogReady,
               readyState.watchdogPID
                   == process.processIdentifier,
               process.isRunning {
                DiagnosticsTrace.shared.record(
                    .systemDock,
                    "watchdogLaunchCompleted",
                    fields: [
                        "pid": process.processIdentifier,
                        "ready": true,
                    ]
                )
                return .success(())
            }

            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline

        if process.isRunning {
            process.terminate()
        }
        watchdogProcess = nil
        isWatchdogLaunchPendingOrRunning = false
        return .failure(
            TransactionFailure(
                message:
                    "Docky's System Dock recovery helper did not confirm "
                    + "readiness before the safety timeout, so no Dock "
                    + "settings were changed."
            )
        )
    }

    private func verifiedCurrentWatchdogProcess() -> Process? {
        guard isWatchdogLaunchPendingOrRunning,
              let process = watchdogProcess,
              process.isRunning,
              let state = readVisibilityState(),
              SystemDockRecoveryCoordinationPolicy.disposition(
                stateIsActive: state.active,
                restoreCompleted: state.restoreCompleted,
                ownerPID: state.ownerPID,
                currentPID: ProcessInfo.processInfo.processIdentifier,
                stateSessionID: state.sessionID,
                currentSessionID: sessionID,
                ownerProcessRunning: isProcessRunning(state.ownerPID)
              ) == .currentSession,
              state.watchdogReady,
              state.watchdogPID == process.processIdentifier
        else {
            return nil
        }

        return process
    }

    private func serializedSnapshot(_ snapshot: [String: Any]) -> [String: Any] {
        var serialized: [String: Any] = [:]
        for key in Self.managedKeys {
            serialized[key] = serializedSnapshotEntry(snapshot[key])
        }
        return serialized
    }

    private func serializedSnapshotEntry(_ stored: Any?) -> [String: Any] {
        switch snapshotValue(stored) {
        case .null:
            return ["type": "null"]
        case .boolean(let value):
            return ["type": "bool", "value": value]
        case .number(let value):
            return ["type": "number", "value": value]
        case .string(let value):
            return ["type": "string", "value": value]
        case .unsupported:
            return ["type": "unsupported"]
        }
    }

    private func deserializedSnapshot(
        _ serialized: [String: Any]
    ) -> [String: Any]? {
        var snapshot: [String: Any] = [:]
        for key in Self.managedKeys {
            guard let entry = serialized[key] as? [String: Any],
                  let type = entry["type"] as? String else {
                return nil
            }

            switch type {
            case "bool":
                guard let value = strictBooleanValue(entry["value"]) else {
                    return nil
                }
                snapshot[key] = value
            case "number":
                guard let value = strictNumberValue(entry["value"]) else {
                    return nil
                }
                snapshot[key] = value
            case "string":
                guard let value = entry["value"] as? String else {
                    return nil
                }
                snapshot[key] = value
            case "null":
                snapshot[key] = Self.snapshotNullMarker
            default:
                return nil
            }
        }
        return snapshot
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
}
