//
//  DockVisibilityReducer.swift
//  Docky
//

import Foundation

nonisolated enum DockVisibility: Equatable {
    case visible
    case hidden
}

/// Immutable snapshot of every input that can affect Docky's visibility.
///
/// Keeping this type free of AppKit makes the policy deterministic and
/// hostless-testable. MainWindow owns the timing (autohide delay and
/// fullscreen edge dwell), then asks this reducer for the one correct state.
nonisolated struct DockVisibilityInputs: Equatable {
    var autohidePreferenceEnabled: Bool
    var fullscreenHidingActive: Bool
    var maximizedHidingActive: Bool
    var pointerInside: Bool
    var pointerRevealAuthorized: Bool
    var activeInteractionLeaseIDs: Set<UUID>
    var editModeActive: Bool
    var dragActive: Bool
}

nonisolated struct DockVisibilityDecision: Equatable {
    let visibility: DockVisibility
    let effectivelyAutohides: Bool
    let contentOverlapHidingActive: Bool
    let requiresPointerRevealAuthorization: Bool
    let interactionLeaseBlocksPointerRevealAuthorization: Bool
}

nonisolated enum DockVisibilityReducer {
    static func reduce(_ inputs: DockVisibilityInputs) -> DockVisibilityDecision {
        let contentOverlapHidingActive =
            inputs.fullscreenHidingActive || inputs.maximizedHidingActive
        let effectivelyAutohides =
            inputs.autohidePreferenceEnabled || contentOverlapHidingActive
        let requiresPointerRevealAuthorization =
            contentOverlapHidingActive
            && inputs.pointerInside
            && !inputs.pointerRevealAuthorized
        let interactionLeaseBlocksPointerRevealAuthorization =
            requiresPointerRevealAuthorization
            && !inputs.activeInteractionLeaseIDs.isEmpty
        let pointerKeepsVisible =
            inputs.pointerInside && !requiresPointerRevealAuthorization
        let hasVisibilityHold =
            pointerKeepsVisible
            || !inputs.activeInteractionLeaseIDs.isEmpty
            || inputs.editModeActive
            || inputs.dragActive
        let visibility: DockVisibility =
            effectivelyAutohides && !hasVisibilityHold ? .hidden : .visible

        return DockVisibilityDecision(
            visibility: visibility,
            effectivelyAutohides: effectivelyAutohides,
            contentOverlapHidingActive: contentOverlapHidingActive,
            requiresPointerRevealAuthorization: requiresPointerRevealAuthorization,
            interactionLeaseBlocksPointerRevealAuthorization:
                interactionLeaseBlocksPointerRevealAuthorization
        )
    }
}

/// A presenter's independent, idempotent claim that Docky must remain visible.
///
/// Presenters retain the lease itself instead of retaining a weak anchor view
/// just so they can later decrement a shared counter. Explicit invalidation and
/// deinitialization both release exactly once.
nonisolated final class MainWindowInteractionLease {
    let id: UUID

    private let lock = NSLock()
    private var releaseHandler: ((UUID) -> Void)?
    private var activeState: (() -> Bool)?

    init(
        id: UUID = UUID(),
        onRelease: @escaping (UUID) -> Void,
        isActive: @escaping () -> Bool = { true }
    ) {
        self.id = id
        self.releaseHandler = onRelease
        self.activeState = isActive
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return releaseHandler != nil && (activeState?() ?? false)
    }

    func invalidate() {
        let handler: ((UUID) -> Void)?
        lock.lock()
        handler = releaseHandler
        releaseHandler = nil
        activeState = nil
        lock.unlock()
        handler?(id)
    }

    deinit {
        invalidate()
    }
}
