//
//  HandoffSuggestionState.swift
//  Docky
//
//  Pure state reducer for the transient Handoff suggestion mirrored from the
//  system Dock. Keeping timing policy free of AppKit/AX makes disappearance,
//  transport-failure, permission, and post-continuation behavior testable.
//

import Foundation

nonisolated struct DockHandoffSuggestion: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
}

nonisolated enum DockHandoffObservation: Equatable, Sendable {
    case available(DockHandoffSuggestion)
    case absent
    case unresolved
    case inconclusive(errorCode: Int)
    case permissionUnavailable
}

nonisolated struct HandoffSuggestionState: Equatable, Sendable {
    private(set) var visibleSuggestion: DockHandoffSuggestion?
    private(set) var consecutiveMissCount = 0
    private(set) var suppressedBundleIdentifier: String?
    private(set) var suppressionAbsenceCount = 0

    let missThreshold: Int

    init(missThreshold: Int = 3) {
        self.missThreshold = max(1, missThreshold)
    }

    mutating func apply(_ observation: DockHandoffObservation) {
        switch observation {
        case .available(let suggestion):
            consecutiveMissCount = 0
            suppressionAbsenceCount = 0
            if suppressedBundleIdentifier
                == suggestion.bundleIdentifier {
                visibleSuggestion = nil
                return
            }
            suppressedBundleIdentifier = nil
            visibleSuggestion = suggestion

        case .absent:
            advanceSuppressionAbsence()
            advanceVisibleSuggestionMiss()

        case .unresolved:
            // The Dock still has a Handoff item, so this is not conclusive
            // evidence that either the visible or suppressed activity ended.
            return

        case .inconclusive:
            // AX transport failures preserve all state. Treating them as
            // absence caused the prototype's tile to flicker or disappear.
            return

        case .permissionUnavailable:
            clear()
        }
    }

    @discardableResult
    mutating func markContinuationSucceeded(
        expectedBundleIdentifier: String
    ) -> Bool {
        guard visibleSuggestion?.bundleIdentifier
                == expectedBundleIdentifier else {
            return false
        }
        visibleSuggestion = nil
        consecutiveMissCount = 0
        suppressedBundleIdentifier =
            expectedBundleIdentifier
        suppressionAbsenceCount = 0
        return true
    }

    mutating func clear() {
        visibleSuggestion = nil
        consecutiveMissCount = 0
        suppressedBundleIdentifier = nil
        suppressionAbsenceCount = 0
    }

    /// Clears a stale displayed suggestion only if it still represents the
    /// action the user invoked. A queued AX result must not remove a newer
    /// suggestion that arrived while the action was in flight.
    @discardableResult
    mutating func clearVisibleSuggestion(
        expectedBundleIdentifier: String
    ) -> Bool {
        guard visibleSuggestion?.bundleIdentifier
                == expectedBundleIdentifier else {
            return false
        }
        clear()
        return true
    }

    private mutating func advanceVisibleSuggestionMiss() {
        guard visibleSuggestion != nil else {
            consecutiveMissCount = 0
            return
        }
        consecutiveMissCount += 1
        if consecutiveMissCount >= missThreshold {
            visibleSuggestion = nil
            consecutiveMissCount = 0
        }
    }

    private mutating func advanceSuppressionAbsence() {
        guard suppressedBundleIdentifier != nil else {
            suppressionAbsenceCount = 0
            return
        }
        suppressionAbsenceCount += 1
        if suppressionAbsenceCount >= missThreshold {
            suppressedBundleIdentifier = nil
            suppressionAbsenceCount = 0
        }
    }
}
