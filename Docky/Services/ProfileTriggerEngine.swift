//
//  ProfileTriggerEngine.swift
//  Docky
//
//  Serial, fail-closed reconciliation of profile automation signals.
//

import AppKit
import Combine
import Foundation
import Observation

nonisolated struct CurrentSpaceAssignmentProposal:
    Equatable,
    Identifiable,
    Sendable {
    let snapshot: ActiveSpaceSnapshot
    let identity: MissionControlSpaceIdentity
    let existingProfileID: String?
    let targetProfileID: String

    var id: String {
        "\(identity.storageKey):\(targetProfileID)"
    }
}

@Observable
@MainActor
final class ProfileTriggerEngine {
    static let shared = ProfileTriggerEngine()

    private(set) var isRunning = false
    private(set) var spaceTransitionPending = true
    private(set) var settledSpaceSnapshot: ActiveSpaceSnapshot?
    private(set) var spacePresentations:
        [MissionControlSpacePresentation] = []
    private(set) var assignmentFailureMessage: String?

    @ObservationIgnored
    private let profileService = ProfileService.shared
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored
    private var minuteTimer: Timer?
    @ObservationIgnored
    private var spaceWatchdogTimer: Timer?
    @ObservationIgnored
    private var spaceReconciliationTask: Task<Void, Never>?
    @ObservationIgnored
    private var reconciliationGeneration: UInt64 = 0
    @ObservationIgnored
    private var pendingSamplingEpoch =
        ProfileTriggerSamplingEpochState()
    @ObservationIgnored
    private var runEpoch: UInt64 = 0
    @ObservationIgnored
    private var lifecycleSignalSerial: UInt64 = 0
    @ObservationIgnored
    private var transitionSerial: UInt64 = 0
    @ObservationIgnored
    private var freshReconciliationGate =
        ProfileFreshReconciliationGate()
    @ObservationIgnored
    private var automationSignalDeferral =
        ProfileTriggerAutomationSignalDeferral()

    @ObservationIgnored
    private var spaceReconciler = SpaceTransitionReconciler()
    @ObservationIgnored
    private var lastCommittedSnapshot: ActiveSpaceSnapshot?
    @ObservationIgnored
    private var transitionOriginSnapshot: ActiveSpaceSnapshot?
    @ObservationIgnored
    private var currentFrontmostBundleID: String?
    @ObservationIgnored
    private var currentSpaceApps: Set<String> = []
    @ObservationIgnored
    private var lastCommittedEvidence:
        ProfileTriggerSpaceEvidence?
    @ObservationIgnored
    private var genericRulesAllowedOnCurrentUnassignedSpace = false
    @ObservationIgnored
    private var residencyState = ProfileSpaceResidencyState()
    @ObservationIgnored
    private var fastArrivalState =
        ProfileFastSpaceArrivalState()

    /// A manual selection is explicit state, not an inference based on whether
    /// the active profile happens to equal the last automatic profile.
    @ObservationIgnored
    private var manualOverride = ProfileManualOverrideState()

    private init() {}

    func start() {
        stop()

        isRunning = true
        runEpoch &+= 1
        let epoch = runEpoch
        spaceReconciler = SpaceTransitionReconciler()
        spaceTransitionPending = true
        settledSpaceSnapshot = nil
        spacePresentations = []
        lastCommittedSnapshot = nil
        transitionOriginSnapshot = nil
        currentFrontmostBundleID =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        currentSpaceApps = []
        lastCommittedEvidence = nil
        pendingSamplingEpoch.reset()
        genericRulesAllowedOnCurrentUnassignedSpace = false
        residencyState.reset()
        fastArrivalState.reset()
        freshReconciliationGate.invalidate()
        automationSignalDeferral.reset()
        manualOverride.clear()
        assignmentFailureMessage = nil

        observeFrontmostApp(runEpoch: epoch)
        observeSpaceLifecycle(runEpoch: epoch)
        observeDockTargetChanges(runEpoch: epoch)
        observeProfileState(runEpoch: epoch)
        scheduleSpaceWatchdog(runEpoch: epoch)
        scheduleMinuteTick(runEpoch: epoch)
        fastArrivalState.beginArrival()
        activateDurablyAssignedSpaceImmediately(
            reason: "start",
            purpose: .startup
        )
        invalidateSpace(
            reason: "start",
            purpose: .startup,
            lifecycleSignal: false,
            scheduleReconciliation: true
        )

        DiagnosticsTrace.shared.record(
            .spaces,
            "profileTriggerEngineStarted",
            fields: [
                "frontmostAppToken":
                    DiagnosticsTrace.shared.token(
                        currentFrontmostBundleID
                    ),
                "activeProfileToken":
                    DiagnosticsTrace.shared.token(
                        profileService.activeProfileID
                    ),
            ]
        )
    }

    func stop() {
        isRunning = false
        runEpoch &+= 1
        lifecycleSignalSerial &+= 1
        cancellables.removeAll()
        minuteTimer?.invalidate()
        minuteTimer = nil
        spaceWatchdogTimer?.invalidate()
        spaceWatchdogTimer = nil
        spaceReconciliationTask?.cancel()
        spaceReconciliationTask = nil
        reconciliationGeneration &+= 1
        spaceReconciler.invalidate()
        spaceTransitionPending = true
        settledSpaceSnapshot = nil
        spacePresentations = []
        lastCommittedSnapshot = nil
        transitionOriginSnapshot = nil
        currentSpaceApps = []
        lastCommittedEvidence = nil
        pendingSamplingEpoch.reset()
        genericRulesAllowedOnCurrentUnassignedSpace = false
        residencyState.reset()
        fastArrivalState.reset()
        freshReconciliationGate.invalidate()
        automationSignalDeferral.reset()
        manualOverride.clear()
        assignmentFailureMessage = nil
    }

    /// Starts a new post-click reconciliation epoch. The returned proposal is
    /// descriptive only; callers must pass it back to `commitSpaceAssignment`
    /// so the identity and previous owner can be revalidated after confirmation.
    func prepareSpaceAssignment(
        to targetProfileID: String
    ) async -> CurrentSpaceAssignmentProposal? {
        let operationEpoch = runEpoch
        assignmentFailureMessage = nil
        guard profileService.profiles.contains(where: {
            $0.id == targetProfileID
        }) else {
            assignmentFailureMessage =
                "That profile no longer exists."
            return nil
        }
        let observedSnapshot = await freshlyReconciledSnapshot(
            reason: "spaceAssignmentPrepare"
        )
        guard isCurrentRun(operationEpoch) else {
            return nil
        }
        guard let snapshot = observedSnapshot,
              let identity = snapshot.assignableIdentity
        else {
            if assignmentFailureMessage == nil {
                assignmentFailureMessage =
                    "The current Desktop could not be identified safely. No assignment was changed."
            }
            return nil
        }

        assignmentFailureMessage = nil
        return CurrentSpaceAssignmentProposal(
            snapshot: snapshot,
            identity: identity,
            existingProfileID:
                profileService.profileIDAssigned(to: identity),
            targetProfileID: targetProfileID
        )
    }

    /// Re-observes the current Desktop after the user confirms. A lifecycle
    /// signal, identity change, owner change, or unresolved snapshot aborts the
    /// operation without touching the assignment table.
    func commitSpaceAssignment(
        _ proposal: CurrentSpaceAssignmentProposal
    ) async -> Bool {
        await commitVerifiedSpaceAssignment(
            proposal,
            legacyRepair: nil
        )
    }

    /// Uses the same post-confirmation authorization as a normal assignment,
    /// but commits the ownership change and legacy-row removal as one profile
    /// document transaction.
    func commitLegacySpaceRepair(
        _ proposal: CurrentSpaceAssignmentProposal,
        triggerID: String,
        in profileID: String
    ) async -> Bool {
        guard proposal.targetProfileID == profileID else {
            assignmentFailureMessage =
                "The legacy binding target changed. No assignment was changed."
            return false
        }
        return await commitVerifiedSpaceAssignment(
            proposal,
            legacyRepair: (
                triggerID: triggerID,
                profileID: profileID
            )
        )
    }

    private func commitVerifiedSpaceAssignment(
        _ proposal: CurrentSpaceAssignmentProposal,
        legacyRepair: (
            triggerID: String,
            profileID: String
        )?
    ) async -> Bool {
        let operationEpoch = runEpoch
        assignmentFailureMessage = nil
        guard profileService.profiles.contains(where: {
            $0.id == proposal.targetProfileID
        }) else {
            assignmentFailureMessage =
                "That profile no longer exists. No assignment was changed."
            return false
        }
        let observedSnapshot = await freshlyReconciledSnapshot(
            reason: "spaceAssignmentCommit"
        )
        guard isCurrentRun(operationEpoch) else {
            return false
        }
        guard let snapshot = observedSnapshot,
              let identity = snapshot.assignableIdentity
        else {
            if assignmentFailureMessage == nil {
                assignmentFailureMessage =
                    "The Desktop changed or could not be identified. No assignment was changed."
            }
            return false
        }
        let currentOwnerProfileID =
            profileService.profileIDAssigned(to: identity)
        guard CurrentSpaceAssignmentAuthorizationPolicy
            .permitsCommit(
                proposedIdentity: proposal.identity,
                proposedOwnerProfileID:
                    proposal.existingProfileID,
                freshlyObservedIdentity: identity,
                currentOwnerProfileID:
                    currentOwnerProfileID
            )
        else {
            assignmentFailureMessage =
                identity == proposal.identity
                ? "This Desktop’s assignment changed while it was being reviewed. No assignment was changed."
                : "The Desktop changed while the assignment was being reviewed. No assignment was changed."
            return false
        }

        let didCommit: Bool
        if let legacyRepair {
            didCommit =
                profileService.repairLegacyExactSpaceBinding(
                    triggerID: legacyRepair.triggerID,
                    in: legacyRepair.profileID,
                    assigning: identity,
                    expectedOwnerProfileID:
                        proposal.existingProfileID
                )
        } else {
            didCommit = profileService.assignSpace(
                identity,
                to: proposal.targetProfileID
            )
        }
        guard didCommit else {
            assignmentFailureMessage =
                profileService.lastPersistenceError
                ?? (
                    legacyRepair == nil
                    ? "The assignment could not be saved."
                    : "The assignment and legacy binding could not be changed atomically."
                )
            return false
        }
        assignmentFailureMessage = nil
        return true
    }

    func spaceDisplayName(
        for snapshot: ActiveSpaceSnapshot
    ) -> String {
        if let identity = snapshot.identity,
           let presentation = spacePresentations.first(where: {
               $0.identity == identity
           }) {
            if presentation.displayName == "All displays" {
                return "Desktop \(presentation.ordinal)"
            }
            return "\(presentation.displayName) — Desktop \(presentation.ordinal)"
        }
        if let ordinal = snapshot.displayOrdinal {
            if let displayIdentifier = snapshot.displayIdentifier,
               !displayIdentifier.isEmpty,
               NSScreen.screensHaveSeparateSpaces {
                return "Display \(Self.short(displayIdentifier)) — Desktop \(ordinal)"
            }
            return "Desktop \(ordinal)"
        }
        return "current Desktop"
    }

    func spaceDisplayName(
        for identity: MissionControlSpaceIdentity
    ) -> String {
        if let current = settledSpaceSnapshot,
           current.assignableIdentity == identity {
            return "\(spaceDisplayName(for: current)) — current"
        }
        if let presentation = spacePresentations.first(where: {
            $0.identity == identity
        }) {
            if presentation.displayName == "All displays" {
                return "Desktop \(presentation.ordinal)"
            }
            return "\(presentation.displayName) — Desktop \(presentation.ordinal)"
        }
        if let scope = identity.rootDisplayScope {
            if scope
                == MissionControlSpaceIdentity.sharedDisplayScope {
                return "Desktop 1 — not currently present"
            }
            return "Desktop 1 on display \(Self.short(scope)) — not currently present"
        }
        return "Saved Desktop \(Self.short(identity.spaceUUID)) — not currently present"
    }

    /// Bundle identifiers for normal-layer windows visible in Docky's target
    /// Space. With separate Spaces enabled, windows on other displays are
    /// excluded so they cannot activate a profile for the wrong display.
    private static func appsOnActiveSpace(
        targetScreen: NSScreen?
    ) -> Set<String>? {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let windows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let targetDisplayBounds: CGRect?
        if NSScreen.screensHaveSeparateSpaces {
            guard let targetScreen,
                  let number = targetScreen.deviceDescription[
                      NSDeviceDescriptionKey("NSScreenNumber")
                  ] as? NSNumber
            else {
                // Missing target evidence must not silently widen the query to
                // every display.
                return nil
            }
            targetDisplayBounds = CGDisplayBounds(
                CGDirectDisplayID(number.uint32Value)
            )
        } else {
            targetDisplayBounds = nil
        }

        var result: Set<String> = []
        for window in windows {
            if let targetDisplayBounds {
                guard let boundsDictionary =
                        window[kCGWindowBounds as String]
                            as? [String: Any],
                      let windowBounds = CGRect(
                          dictionaryRepresentation:
                              boundsDictionary as CFDictionary
                      ),
                      windowBounds.intersects(targetDisplayBounds)
                else {
                    continue
                }
            }

            guard let pid =
                    window[kCGWindowOwnerPID as String] as? Int32,
                  let app = NSRunningApplication(
                      processIdentifier: pid
                  ),
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier
            else {
                continue
            }
            if let layer =
                window[kCGWindowLayer as String] as? Int,
               layer != 0 {
                continue
            }
            result.insert(bundleID)
        }
        return result
    }

    private func observeFrontmostApp(runEpoch epoch: UInt64) {
        NSWorkspace.shared.notificationCenter
            .publisher(
                for: NSWorkspace.didActivateApplicationNotification
            )
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentRun(epoch)
                    else {
                        return
                    }
                    // The notification payload is only a wake-up signal.
                    // Callback order is not an evidence boundary; live app
                    // and Space state are read together after reconciliation.
                    self.handleAutomationSignal(
                        reason: "frontmostApplication",
                        purpose: .frontmostApplication
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func observeSpaceLifecycle(runEpoch epoch: UInt64) {
        NSWorkspace.shared.notificationCenter
            .publisher(
                for: NSWorkspace.activeSpaceDidChangeNotification
            )
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentRun(epoch)
                    else {
                        return
                    }
                    self.fastArrivalState.beginArrival()
                    self
                        .activateDurablyAssignedSpaceImmediately(
                            reason:
                                "activeSpaceNotification",
                            purpose: .topology
                        )
                    self.invalidateSpace(
                        reason: "activeSpaceNotification",
                        purpose: .topology,
                        lifecycleSignal: true,
                        scheduleReconciliation: true
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func observeDockTargetChanges(runEpoch epoch: UInt64) {
        NotificationCenter.default
            .publisher(for: NSWindow.didChangeScreenNotification)
            .compactMap { $0.object as? MainWindow }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentRun(epoch)
                    else {
                        return
                    }
                    self.fastArrivalState.beginArrival()
                    self
                        .activateDurablyAssignedSpaceImmediately(
                            reason:
                                "dockWindowScreenChanged",
                            purpose: .topology
                        )
                    self.invalidateSpace(
                        reason: "dockWindowScreenChanged",
                        purpose: .topology,
                        lifecycleSignal: true,
                        scheduleReconciliation: true
                    )
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(
                for:
                    NSApplication
                    .didChangeScreenParametersNotification
            )
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentRun(epoch)
                    else {
                        return
                    }
                    self.fastArrivalState.beginArrival()
                    self
                        .activateDurablyAssignedSpaceImmediately(
                            reason:
                                "screenParametersChanged",
                            purpose: .topology
                        )
                    self.invalidateSpace(
                        reason: "screenParametersChanged",
                        purpose: .topology,
                        lifecycleSignal: true,
                        scheduleReconciliation: true
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func observeProfileState(runEpoch epoch: UInt64) {
        NotificationCenter.default
            .publisher(for: .profileActivationDidChange)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          self.isCurrentRun(epoch),
                          let change =
                            notification.object
                                as? ProfileActivationChange
                    else {
                        return
                    }
                    switch change.source {
                    case .manual:
                        // A one-shot snapshot can be the origin of a
                        // transition whose callback has not arrived yet.
                        // Bind only after a post-click coherent commit.
                        self.manualOverride.recordUnbound(
                            profileID: change.newProfileID
                        )
                        self.invalidateSpace(
                            reason: "manualProfileSelection",
                            purpose: .manualBinding,
                            lifecycleSignal: false,
                            scheduleReconciliation: true
                        )
                    case .deleteFallback, .rollback:
                        self.manualOverride.clear()
                    case .trigger, .launchReapply:
                        break
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func handleAutomationSignal(
        reason: String,
        purpose: ProfileTriggerSamplingPurpose
    ) {
        guard isRunning else { return }
        guard let effectivePurpose =
                automationSignalDeferral.receive(
                    purpose,
                    verificationInProgress:
                        freshReconciliationGate.isInProgress
                )
        else {
            DiagnosticsTrace.shared.record(
                .spaces,
                "profileAutomationSignalDeferred",
                fields: [
                    "reason": reason,
                ]
            )
            return
        }
        invalidateSpace(
            reason: reason,
            purpose: effectivePurpose,
            lifecycleSignal: false,
            scheduleReconciliation: true
        )
    }

    /// Reapplies an already-durable exact Space owner from its persistent
    /// SkyLight name. Discovery, generic rules, assignment, and settled-state
    /// publication still use the ordinary reconciler.
    ///
    /// Reading live topology here (instead of trusting callback payload or
    /// order) makes delayed duplicate notifications harmless. The arrival is
    /// consumed only after a successful activation, so the early
    /// reconciliation samples can retry a transiently incomplete name without
    /// waiting for the half-second settled-state gate.
    @discardableResult
    private func activateDurablyAssignedSpaceImmediately(
        reason: String,
        purpose: ProfileTriggerSamplingPurpose,
        snapshot suppliedSnapshot: ActiveSpaceSnapshot? = nil
    ) -> Bool {
        guard isRunning,
              ProfileFastSpaceActivationAttemptPolicy.allowsAttempt(
                  purpose: purpose,
                  verificationInProgress:
                      freshReconciliationGate.isInProgress
              )
        else {
            return false
        }

        let snapshot =
            suppliedSnapshot
            ?? fastActiveSpaceSnapshot(
                for: Self.targetScreen()
            )
        let hasUnconsumedArrival =
            fastArrivalState.observe(snapshot)
        guard hasUnconsumedArrival else {
            return false
        }
        if let manualProfileID =
                manualOverride.fastReactivationProfileID(
                    on: snapshot
                ),
           profileService.profiles.contains(where: {
               $0.id == manualProfileID
           }) {
            let diagnostics = DiagnosticsTrace.shared
            diagnostics.record(
                .spaces,
                "manualSpaceFastReactivation",
                fields: [
                    "reason": reason,
                    "spaceID": snapshot.spaceID,
                    "spaceIdentityToken":
                        diagnostics.token(
                            snapshot.identity?.storageKey
                        ),
                    "profileToken":
                        diagnostics.token(manualProfileID),
                ]
            )
            let activated = profileService.setActiveProfile(
                id: manualProfileID,
                source: .trigger
            )
            if activated {
                fastArrivalState.markActivationSucceeded(
                    for: snapshot
                )
            }
            return activated
        }
        let durableAssignment =
            profileService.durableSpaceAssignmentState(
                for: snapshot.assignableIdentity
            )
        let profileID =
            ProfileAssignedSpaceFastActivationPolicy.profileID(
                snapshot: snapshot,
                purpose: purpose,
                targetChanged: hasUnconsumedArrival,
                durableAssignment: durableAssignment,
                availableProfileIDs:
                    Set(profileService.profiles.map(\.id)),
                verificationInProgress:
                    freshReconciliationGate.isInProgress,
                manualOverrideAllowsTransition:
                    manualOverride.allowsFastTransition(
                        to: snapshot
                    )
            )
        guard let profileID else { return false }

        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(
            .spaces,
            "assignedSpaceFastActivation",
            fields: [
                "reason": reason,
                "spaceID": snapshot.spaceID,
                "spaceIdentityToken":
                    diagnostics.token(
                        snapshot.identity?.storageKey
                    ),
                "profileToken":
                    diagnostics.token(profileID),
                "activeProfileToken":
                    diagnostics.token(
                        profileService.activeProfileID
                    ),
                "durableRevision":
                    durableAssignment.durableRevision,
                "currentRevision":
                    durableAssignment.currentRevision,
            ]
        )
        let activated = profileService.setActiveProfile(
            id: profileID,
            source: .trigger
        )
        if activated {
            fastArrivalState.markActivationSucceeded(
                for: snapshot
            )
        }
        return activated
    }

    private func finishFreshReconciliation(
        _ token: ProfileFreshReconciliationGate.Token
    ) {
        let ownedLease =
            freshReconciliationGate.isActive(token)
        freshReconciliationGate.finish(token)
        guard ownedLease else {
            return
        }

        if let deferredPurpose =
            automationSignalDeferral.verificationDidFinish() {
            pendingSamplingEpoch.record(deferredPurpose)
        }

        // Fresh verification cancels the ordinary reconciliation task while
        // it owns the sampler. Resume any topology/manual/automation intent
        // retained underneath the token-owned overlay. Cancellation or a
        // timeout that left the sampler unsettled is itself topology work.
        // A verification may also be the first observer of a changed target
        // when macOS omitted the lifecycle callback; that committed crossing
        // must evaluate exact ownership instead of waiting for another event.
        let resumePurpose =
            pendingSamplingEpoch.purpose
                ?? (
                    pendingSamplingEpoch.crossedTarget
                        || spaceTransitionPending
                    ? .topology
                    : nil
                )
        guard let resumePurpose else { return }
        invalidateSpace(
            reason: "freshVerification.resumePending",
            purpose: resumePurpose,
            lifecycleSignal: false,
            scheduleReconciliation: true
        )
    }

    private func invalidateSpace(
        reason: String,
        purpose: ProfileTriggerSamplingPurpose,
        lifecycleSignal: Bool,
        scheduleReconciliation: Bool,
        recordPendingPurpose: Bool = true
    ) {
        guard isRunning else { return }

        if recordPendingPurpose {
            pendingSamplingEpoch.record(purpose)
        }
        if lifecycleSignal {
            lifecycleSignalSerial &+= 1
        }
        if !spaceTransitionPending {
            transitionSerial &+= 1
            transitionOriginSnapshot = lastCommittedSnapshot
        }

        spaceReconciler.invalidate()
        spaceTransitionPending = true
        settledSpaceSnapshot = nil
        currentSpaceApps = []

        DiagnosticsTrace.shared.record(
            .spaces,
            "spaceTransitionBegan",
            fields: [
                "reason": reason,
                "transitionSerial": transitionSerial,
                "activeProfileToken":
                    DiagnosticsTrace.shared.token(
                        profileService.activeProfileID
                    ),
            ]
        )

        if scheduleReconciliation {
            scheduleTransitionReconciliation(
                reason: reason,
                purpose: purpose
            )
        } else {
            spaceReconciliationTask?.cancel()
            spaceReconciliationTask = nil
            reconciliationGeneration &+= 1
        }
    }

    /// Samples rapidly only after a lifecycle signal. The normal watchdog is
    /// deliberately low-rate; both paths feed the same monotonic reconciler.
    private func scheduleTransitionReconciliation(
        reason: String,
        purpose: ProfileTriggerSamplingPurpose
    ) {
        spaceReconciliationTask?.cancel()
        reconciliationGeneration &+= 1
        let generation = reconciliationGeneration
        let epoch = runEpoch

        spaceReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delaysNanoseconds: [UInt64] = [
                0,
                16_000_000,
                34_000_000,
                50_000_000,
                60_000_000,
                100_000_000,
                160_000_000,
                180_000_000,
                200_000_000,
                250_000_000,
                350_000_000,
                500_000_000,
            ]

            for delay in delaysNanoseconds {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      self.isCurrentRun(epoch),
                      generation
                        == self.reconciliationGeneration
                else {
                    return
                }
                if self.sampleSpace(
                    reason: "\(reason).reconcile",
                    purpose: purpose
                ) {
                    break
                }
            }
            if self.isCurrentRun(epoch),
               generation == self.reconciliationGeneration {
                self.spaceReconciliationTask = nil
            }
        }
    }

    private func scheduleSpaceWatchdog(runEpoch epoch: UInt64) {
        let timer = Timer(timeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentRun(epoch),
                      !self.freshReconciliationGate.isInProgress
                else {
                    return
                }
                let settled = self.sampleSpace(
                    reason: "spaceWatchdog",
                    purpose: .topology
                )
                if !settled,
                   self.spaceReconciliationTask == nil {
                    self.scheduleTransitionReconciliation(
                        reason: "spaceWatchdog",
                        purpose: .topology
                    )
                }
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        spaceWatchdogTimer = timer
    }

    /// Returns true when the Space state is settled.
    @discardableResult
    private func sampleSpace(
        reason: String,
        purpose: ProfileTriggerSamplingPurpose,
        verificationToken:
            ProfileFreshReconciliationGate.Token? = nil
    ) -> Bool {
        guard isRunning else { return false }
        let isOwnedAssignmentVerification: Bool
        if purpose == .assignmentVerification {
            guard let verificationToken,
                  freshReconciliationGate.isActive(
                      verificationToken
                  )
            else {
                return false
            }
            isOwnedAssignmentVerification = true
        } else {
            guard verificationToken == nil else {
                return false
            }
            isOwnedAssignmentVerification = false
        }

        // Resolve the target once for this observation. Re-resolving a
        // pointer-selected display after reading the Space can combine display
        // A's snapshot with display B's windows.
        let observationTargetScreen = Self.targetScreen()
        _ = activateDurablyAssignedSpaceImmediately(
            reason: "\(reason).earlySample",
            purpose: purpose,
            snapshot:
                fastActiveSpaceSnapshot(
                    for: observationTargetScreen
                )
        )
        let snapshot = activeSpaceSnapshot(for: observationTargetScreen)
        let wasPending = spaceTransitionPending
        let priorCommittedSnapshot = lastCommittedSnapshot
        let outcome = spaceReconciler.observe(
            snapshot,
            atUptime: ProcessInfo.processInfo.systemUptime
        )

        switch outcome {
        case .pending:
            if !wasPending {
                transitionSerial &+= 1
                lifecycleSignalSerial &+= 1
                transitionOriginSnapshot = priorCommittedSnapshot
                DiagnosticsTrace.shared.record(
                    .spaces,
                    "spaceTransitionBegan",
                    fields: [
                        "reason":
                            "\(reason).observationChanged",
                        "observedSpaceID": snapshot.spaceID,
                        "transitionSerial": transitionSerial,
                    ]
                )
            }
            spaceTransitionPending = true
            settledSpaceSnapshot = nil
            currentSpaceApps = []
            return false

        case .unchanged:
            guard let settled = spaceReconciler.settledSnapshot else {
                return false
            }
            spaceTransitionPending = false
            settledSpaceSnapshot = settled
            lastCommittedSnapshot = settled
            fastArrivalState.synchronize(settled)
            return true

        case .committed(let settled):
            let effectivePurpose =
                isOwnedAssignmentVerification
                ? ProfileTriggerSamplingPurpose
                    .assignmentVerification
                : pendingSamplingEpoch.effectivePurpose(
                    fallback: purpose
                )
            let targetChanged = transitionOriginSnapshot.map {
                !Self.sameTargetSpace($0, settled)
            } ?? true
            pendingSamplingEpoch.noteCommittedTargetChange(
                targetChanged
            )
            let effectiveTargetChanged =
                pendingSamplingEpoch.crossedTarget
            manualOverride.reconcileCommittedTarget(settled)

            if targetChanged {
                genericRulesAllowedOnCurrentUnassignedSpace = false
                lastCommittedEvidence = nil
            }
            residencyState.reconcileCommittedTarget(
                settled,
                targetChanged: targetChanged,
                liveAssignedProfileID:
                    profileService.profileIDAssigned(
                        to: settled.assignableIdentity
                    )
            )

            spaceTransitionPending = false
            settledSpaceSnapshot = settled
            lastCommittedSnapshot = settled
            fastArrivalState.synchronize(settled)
            transitionOriginSnapshot = nil
            spacePresentations =
                missionControlSpacePresentations()

            let diagnostics = DiagnosticsTrace.shared
            diagnostics.record(
                .spaces,
                "spaceTransitionCommitted",
                fields: [
                    "reason": reason,
                    "spaceID": settled.spaceID,
                    "spaceIdentityToken":
                        diagnostics.token(
                            settled.identity?.storageKey
                        ),
                    "assignable":
                        settled.assignableIdentity != nil,
                    "spaceType":
                        settled.rawType.map(String.init)
                        ?? "unknown",
                    "displayOrdinal":
                        settled.displayOrdinal.map(String.init)
                        ?? "unknown",
                    "targetChanged": targetChanged,
                    "manualOverrideActive":
                        manualOverride.profileID != nil,
                    "activeProfileToken":
                        diagnostics.token(
                            profileService.activeProfileID
                        ),
                ]
            )

            // Assignment authorization and post-click manual binding are
            // topology observations only. They must never run automation.
            guard effectivePurpose.shouldEvaluateAutomation else {
                if !isOwnedAssignmentVerification,
                   let resumePurpose =
                    pendingSamplingEpoch.consumeObservation(
                        effectivePurpose
                    ) {
                    invalidateSpace(
                        reason: "\(reason).resumePending",
                        purpose: resumePurpose,
                        lifecycleSignal: false,
                        scheduleReconciliation: true
                    )
                }
                return true
            }

            // Exact ownership depends only on the committed durable identity
            // and assignment table. Window/frontmost-app evidence is required
            // solely for generic app/time rules and must not delay or starve
            // an assigned Space.
            if case .assigned =
                residencyState.evaluationState(
                    for: settled
                ) {
                pendingSamplingEpoch.consumeAutomation()
                evaluate(reason: reason)
                return true
            }

            let previousEvidence = lastCommittedEvidence
            guard let evidence = Self.triggerEvidence(
                committedSnapshot: settled,
                targetScreen: observationTargetScreen
            ) else {
                invalidateSpace(
                    reason: "\(reason).evidenceChanged",
                    purpose: .topology,
                    lifecycleSignal: true,
                    scheduleReconciliation: true
                )
                return false
            }

            genericRulesAllowedOnCurrentUnassignedSpace =
                ProfileTriggerSpaceEvidencePolicy
                .genericRulesAllowed(
                    currentlyAllowed:
                        genericRulesAllowedOnCurrentUnassignedSpace,
                    purpose: effectivePurpose,
                    targetChanged: effectiveTargetChanged,
                    previousEvidence: previousEvidence,
                    newEvidence: evidence
                )
            currentFrontmostBundleID =
                evidence.frontmostBundleID
            currentSpaceApps = evidence.spaceApps
            lastCommittedEvidence = evidence
            pendingSamplingEpoch.consumeAutomation()

            evaluate(reason: reason)
            return true
        }
    }

    /// Collects one coherent app-evidence bundle for the exact screen used by
    /// the committed Space sample. The live Space and frontmost app are read
    /// again after the window query; any mismatch discards the entire bundle.
    private static func triggerEvidence(
        committedSnapshot: ActiveSpaceSnapshot,
        targetScreen: NSScreen?
    ) -> ProfileTriggerSpaceEvidence? {
        let frontmostBefore =
            NSWorkspace.shared.frontmostApplication?
                .bundleIdentifier
        guard let apps = appsOnActiveSpace(
            targetScreen: targetScreen
        ) else {
            return nil
        }
        let frontmostAfter =
            NSWorkspace.shared.frontmostApplication?
                .bundleIdentifier
        let postQuerySnapshot =
            activeSpaceSnapshot(for: targetScreen)
        return ProfileTriggerSpaceEvidencePolicy.validated(
            committedSnapshot: committedSnapshot,
            postQuerySnapshot: postQuerySnapshot,
            frontmostBefore: frontmostBefore,
            frontmostAfter: frontmostAfter,
            spaceApps: apps
        )
    }

    private func freshlyReconciledSnapshot(
        reason: String
    ) async -> ActiveSpaceSnapshot? {
        guard isRunning else {
            assignmentFailureMessage =
                "Space automation is not running."
            return nil
        }
        guard let verificationToken =
                freshReconciliationGate.begin(
                    runEpoch: runEpoch
                )
        else {
            assignmentFailureMessage =
                "Another Desktop verification is already in progress. No assignment was changed."
            return nil
        }
        defer {
            finishFreshReconciliation(
                verificationToken
            )
        }

        let epoch = verificationToken.runEpoch
        let signalSerial = lifecycleSignalSerial
        invalidateSpace(
            reason: reason,
            purpose: .assignmentVerification,
            lifecycleSignal: false,
            scheduleReconciliation: false,
            recordPendingPurpose: false
        )
        let generation = reconciliationGeneration
        let delaysNanoseconds: [UInt64] = [
            0,
            170_000_000,
            180_000_000,
            200_000_000,
            260_000_000,
            360_000_000,
            520_000_000,
        ]

        for delay in delaysNanoseconds {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled,
                  isCurrentRun(epoch),
                  generation == reconciliationGeneration,
                  signalSerial == lifecycleSignalSerial,
                  freshReconciliationGate.isActive(
                      verificationToken
                  )
            else {
                if isCurrentRun(epoch),
                   freshReconciliationGate.isActive(
                       verificationToken
                   ) {
                    assignmentFailureMessage =
                        "The Desktop changed while it was being observed. No assignment was changed."
                }
                return nil
            }
            if sampleSpace(
                reason: "\(reason).fresh",
                purpose: .assignmentVerification,
                verificationToken: verificationToken
            ),
               let settledSpaceSnapshot {
                return settledSpaceSnapshot
            }
        }

        if isCurrentRun(epoch),
           freshReconciliationGate.isActive(
               verificationToken
           ) {
            assignmentFailureMessage =
                "The current Desktop did not settle to one reliable identity. No assignment was changed."
        }
        return nil
    }

    private static func targetScreen() -> NSScreen? {
        switch DockyPreferences.shared.windowDisplayTarget {
        case .primaryDisplay:
            return NSScreen.screens.first ?? NSScreen.main
        case .displayContainingPointer:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first {
                $0.frame.contains(mouseLocation)
            }
                ?? NSApp.windows.lazy
                    .compactMap { $0 as? MainWindow }
                    .first?.screen
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }
    }

    private func scheduleMinuteTick(runEpoch epoch: UInt64) {
        let calendar = Calendar.current
        let now = Date()
        let nextMinute = calendar.nextDate(
            after: now,
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60)
        let firstFire = nextMinute.timeIntervalSinceNow
        minuteTimer = Timer.scheduledTimer(
            withTimeInterval: max(firstFire, 1),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentRun(epoch)
                else {
                    return
                }
                self.tickMinute(runEpoch: epoch)
            }
        }
    }

    private func tickMinute(runEpoch epoch: UInt64) {
        guard isCurrentRun(epoch) else { return }
        handleAutomationSignal(
            reason: "minuteBoundary",
            purpose: .minute
        )
        minuteTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentRun(epoch)
                else {
                    return
                }
                self.handleAutomationSignal(
                    reason: "minuteTimer",
                    purpose: .minute
                )
            }
        }
    }

    private func evaluate(reason: String) {
        let diagnostics = DiagnosticsTrace.shared
        guard isRunning, !spaceTransitionPending else {
            diagnostics.record(
                .profiles,
                "profileTriggerEvaluated",
                fields: [
                    "reason": reason,
                    "decision": "spaceTransitionPending",
                    "activeProfileToken":
                        diagnostics.token(
                            profileService.activeProfileID
                        ),
                ]
            )
            return
        }

        guard let match = bestMatch() else {
            diagnostics.record(
                .profiles,
                "profileTriggerEvaluated",
                fields: [
                    "reason": reason,
                    "decision": "noMatch",
                    "spaceID":
                        settledSpaceSnapshot?.spaceID ?? 0,
                    "spaceIdentityResolved":
                        settledSpaceSnapshot?.identity != nil,
                    "activeProfileToken":
                        diagnostics.token(
                            profileService.activeProfileID
                        ),
                ]
            )
            return
        }

        let matched = match.profile
        guard matched.id != profileService.activeProfileID else {
            diagnostics.record(
                .profiles,
                "profileTriggerEvaluated",
                fields: [
                    "reason": reason,
                    "decision": "alreadyActive",
                    "specificity": match.specificity,
                    "matchedProfileToken":
                        diagnostics.token(matched.id),
                ]
            )
            return
        }

        if let manualProfileID = manualOverride.profileID,
           manualProfileID
            == profileService.activeProfileID {
            diagnostics.record(
                .profiles,
                "profileTriggerEvaluated",
                fields: [
                    "reason": reason,
                    "decision":
                        "manualOverrideSuppressedSwitch",
                    "specificity": match.specificity,
                    "matchedProfileToken":
                        diagnostics.token(matched.id),
                ]
            )
            return
        }

        diagnostics.record(
            .profiles,
            "profileTriggerEvaluated",
            fields: [
                "reason": reason,
                "decision": "switch",
                "specificity": match.specificity,
                "spaceID":
                    settledSpaceSnapshot?.spaceID ?? 0,
                "matchedProfileToken":
                    diagnostics.token(matched.id),
            ]
        )
        _ = profileService.setActiveProfile(
            id: matched.id,
            source: .trigger
        )
    }

    private func bestMatch() -> (
        profile: DockProfile,
        specificity: Int
    )? {
        guard let settledSpaceSnapshot else { return nil }

        let assignmentState =
            residencyState.evaluationState(
                for: settledSpaceSnapshot
            )

        let evaluationProfiles = profileService.profiles.map {
            ProfileTriggerEvaluationProfile(
                id: $0.id,
                dateCreated: $0.dateCreated,
                triggers: $0.triggers
            )
        }
        guard let resolution = ProfileTriggerResolver.resolve(
            profiles: evaluationProfiles,
            context: ProfileTriggerEvaluationContext(
                now: Date(),
                frontmostBundleID: currentFrontmostBundleID,
                spaceApps: currentSpaceApps,
                spaceAssignmentState: assignmentState,
                allowsGenericRulesOnUnassignedRegular:
                    genericRulesAllowedOnCurrentUnassignedSpace
            )
        ),
              let profile = profileService.profiles.first(where: {
                  $0.id == resolution.profileID
              })
        else {
            return nil
        }
        return (profile, resolution.specificity)
    }

    private func isCurrentRun(_ epoch: UInt64) -> Bool {
        isRunning && runEpoch == epoch
    }

    private static func sameTargetSpace(
        _ lhs: ActiveSpaceSnapshot,
        _ rhs: ActiveSpaceSnapshot
    ) -> Bool {
        if let leftIdentity = lhs.identity,
           let rightIdentity = rhs.identity {
            return leftIdentity == rightIdentity
                && lhs.rawType == rhs.rawType
                && DisplaySpaceSnapshotResolver
                    .normalizeDisplayIdentifier(
                        lhs.displayIdentifier ?? ""
                    )
                    == DisplaySpaceSnapshotResolver
                    .normalizeDisplayIdentifier(
                        rhs.displayIdentifier ?? ""
                    )
        }
        return lhs.spaceID == rhs.spaceID
            && lhs.rawType == rhs.rawType
            && DisplaySpaceSnapshotResolver
                .normalizeDisplayIdentifier(
                    lhs.displayIdentifier ?? ""
                )
                == DisplaySpaceSnapshotResolver
                .normalizeDisplayIdentifier(
                    rhs.displayIdentifier ?? ""
                )
    }

    private static func short(_ value: String) -> String {
        String(value.prefix(8)).uppercased()
    }
}
