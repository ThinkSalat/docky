//
//  AXWindowWorker.swift
//  Docky
//
//  Serialized Accessibility client isolated from the main actor. Every
//  AXUIElement, AXObserver, attribute read, setter, and action lives on this
//  object's dedicated CFRunLoop thread. The UI receives immutable Sendable
//  snapshots and never waits synchronously for another process to answer.
//

import ApplicationServices
import CoreGraphics
import Foundation

nonisolated struct AXApplicationDescriptor: Hashable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let displayName: String
    let lifecycle: AXApplicationLifecycleStamp
}

nonisolated enum AXWindowSnapshotScope: Hashable, Sendable {
    case all
    case process(pid_t)
}

nonisolated enum AXWindowWorkerEvent: Sendable {
    case requestedSnapshot(
        session: UInt64,
        scope: AXWindowSnapshotScope,
        generation: AXRequestGeneration,
        batches: [AXApplicationLifecycleValue<[AppWindow]>]
    )
    case processSnapshot(
        session: UInt64,
        generation: AXRequestGeneration,
        lifecycle: AXApplicationLifecycleStamp,
        windows: [AppWindow],
        invalidatedPreviewIdentifier: String?
    )
    case focusedWindowChanged(
        session: UInt64,
        lifecycle: AXApplicationLifecycleStamp,
        windowID: WindowID
    )
    case processHidden(
        session: UInt64,
        lifecycle: AXApplicationLifecycleStamp
    )
    case windowDestroyed(
        session: UInt64,
        lifecycle: AXApplicationLifecycleStamp,
        windowID: WindowID?
    )
}

nonisolated struct AXWindowWorkerEventEnvelope: Sendable {
    let sequence: UInt64
    let event: AXWindowWorkerEvent
}

nonisolated enum AXWindowAction: Sendable {
    case focus
    case minimize
    case close
    case zoom
    case resize(CGRect)
}

nonisolated enum AXApplicationActivationDirective: Equatable, Sendable {
    case none
    case unhideIfHidden
    case unhideAndActivate
}

nonisolated struct AXWindowActionResult: Sendable {
    let succeeded: Bool
    let result: String
    let activationDirective: AXApplicationActivationDirective
    let positionError: Int32?
    let sizeError: Int32?

    static func failure(_ result: String) -> AXWindowActionResult {
        AXWindowActionResult(
            succeeded: false,
            result: result,
            activationDirective: .none,
            positionError: nil,
            sizeError: nil
        )
    }
}

private nonisolated struct AXSnapshotPayload: Sendable {
    let session: UInt64
    let delivery: AXSnapshotDelivery
    let applicationLifecycles: [AXApplicationLifecycleStamp]
}

private nonisolated enum AXSnapshotDelivery: Sendable {
    case requested(generation: AXRequestGeneration)
    case observed(
        lifecycle: AXApplicationLifecycleStamp,
        invalidatedPreviewIdentifier: String?
    )
}

private nonisolated final class AXActionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

/// `@unchecked Sendable` is intentional: callers only enqueue closures.
/// Mutable state below the lifecycle lock is touched exclusively by
/// `threadMain` and blocks running on that same CFRunLoop.
nonisolated final class AXWindowWorker: @unchecked Sendable {
    typealias EventSink = @Sendable (AXWindowWorkerEventEnvelope) -> Void
    private typealias Command = @Sendable () -> Void

    private struct ElementRecord {
        let id: WindowID
        var element: AXUIElement
        let processIdentifier: pid_t
        let lifecycle: AXApplicationLifecycleStamp
        var cgWindowID: CGWindowID?
    }

    private enum SnapshotWorkUnit: Sendable {
        case application(AXApplicationDescriptor)
        case window(
            application: AXApplicationDescriptor,
            handleToken: UInt64,
            isLastForApplication: Bool
        )
    }

    private struct SnapshotElementRecord {
        let scope: AXWindowSnapshotScope
        let generation: AXRequestGeneration
        let element: AXUIElement
    }

    private struct SnapshotAccumulator {
        let scope: AXWindowSnapshotScope
        let generation: AXRequestGeneration
        var windows: [AppWindow]
        var seenIDsByPID: [pid_t: Set<WindowID>]
        var preserveUnseenPIDs: Set<pid_t>
        var decodedCandidatesByPID:
            [pid_t: [DecodedWindowCandidate]]
    }

    private enum WindowElementListResult {
        case success([AXUIElement], isComplete: Bool)
        case failure(AXError)
    }

    private struct WindowAttributeSnapshot {
        let rawTitle: String?
        let role: String?
        let subrole: String?
        let isMinimized: Bool?
        let windowNumber: Int?
        let frame: CGRect?
    }

    private struct DecodedWindowCandidate {
        let element: AXUIElement
        let application: AXApplicationDescriptor
        let resolvedTitle: String
        let subrole: String?
        let isMinimized: Bool
        let evidence: AXWindowRebindEvidence
    }

    private struct AXActionAttempt {
        let result: AXWindowActionResult
        let shouldRefreshStaleElement: Bool
    }

    private struct RegisteredActionCancellation {
        let lifecycle: AXApplicationLifecycleStamp
        let cancellation: AXActionCancellation
    }

    private struct PendingObserverEvent {
        let session: UInt64
        let observer: AXObserver
        let element: AXUIElement
        let notificationName: CFString
    }

    private struct ObserverNotificationRegistrationKey:
        Hashable,
        Sendable {
        let lifecycle: AXApplicationLifecycleStamp
        let notificationName: String
    }

    private let lifecycleLock = NSLock()
    private var runLoop: CFRunLoop?
    private var workerThread: Thread?
    private var commandQueue = AXPriorityCommandQueue<Command>()
    private var commandPumpScheduled = false
    private var registeredActionCancellations:
        [UUID: RegisteredActionCancellation] = [:]

    // Worker-thread-only state.
    private var eventSink: EventSink?
    private var currentSession: UInt64 = 0
    private var observationsActive = false
    private var applicationsByPID: [pid_t: AXApplicationDescriptor] = [:]
    private var applicationObservers: [pid_t: AXObserver] = [:]
    private var observerRegistrationRetries =
        AXNotificationRegistrationRetryState<
            ObserverNotificationRegistrationKey
        >()
    private var exhaustedObserverRegistrations:
        Set<ObserverNotificationRegistrationKey> = []
    private var observerRegistrationWakeTimer: CFRunLoopTimer?
    private var observerRegistrationWakeDeadline: TimeInterval?
    private var pendingObserverEventsByToken:
        [UInt64: PendingObserverEvent] = [:]
    private var nextObserverEventToken: UInt64 = 0
    private var recordsByID: [WindowID: ElementRecord] = [:]
    private var windowsByPID: [pid_t: [AppWindow]] = [:]
    private var nextWindowToken: UInt64 = 0
    private var nextEventSequence: UInt64 = 0
    private var snapshotWorkGenerations =
        AXRequestGenerationTracker<AXWindowSnapshotScope>()
    private var snapshotScheduler =
        AXCooperativeWorkScheduler<
            AXWindowSnapshotScope,
            SnapshotWorkUnit,
            AXSnapshotPayload
        >()
    private var restartableGlobalSnapshot =
        AXRestartableRequestState<
            AXSnapshotPayload,
            AXApplicationDescriptor
        >()
    private var activeSnapshotResult: SnapshotAccumulator?
    private var snapshotElementsByToken:
        [UInt64: SnapshotElementRecord] = [:]
    private var nextSnapshotElementToken: UInt64 = 0
    private var decodeEncounteredTransientFailure = false
    private var liveElementFailureReason = "liveElementUnavailable"
    private var snapshotDrainScheduled = false

    init() {
        let thread = Thread { [weak self] in
            self?.threadMain()
        }
        thread.name = "gt.quintero.Docky.AXWindowWorker"
        thread.qualityOfService = .userInitiated
        workerThread = thread
        thread.start()
    }

    func setEventSink(_ sink: @escaping EventSink) {
        enqueue { [weak self] in
            self?.eventSink = sink
        }
    }

    func startObserving(
        session: UInt64,
        applications: [AXApplicationDescriptor],
        generation: AXRequestGeneration
    ) {
        cancelAllRegisteredActions()
        enqueue { [weak self] in
            guard let self else { return }
            currentSession = session
            observationsActive = true
            replaceApplications(with: applications)
            enqueueSnapshot(
                scope: .all,
                payload: AXSnapshotPayload(
                    session: session,
                    delivery: .requested(generation: generation),
                    applicationLifecycles: applications.map(\.lifecycle)
                ),
                applications: applications
            )
        }
    }

    func stopObserving(session: UInt64) {
        cancelAllRegisteredActions()
        enqueue { [weak self] in
            guard let self else { return }
            currentSession = session
            observationsActive = false
            snapshotScheduler.cancelAll()
            restartableGlobalSnapshot.cancel()
            activeSnapshotResult = nil
            snapshotElementsByToken.removeAll()
            snapshotDrainScheduled = false
            removeAllObservers()
            observerRegistrationRetries.cancelAll()
            exhaustedObserverRegistrations.removeAll()
            cancelObserverRegistrationWake()
            pendingObserverEventsByToken.removeAll()
            applicationsByPID.removeAll()
            recordsByID.removeAll()
            windowsByPID.removeAll()
        }
    }

    func requestSnapshot(
        session: UInt64,
        scope: AXWindowSnapshotScope,
        applications: [AXApplicationDescriptor],
        generation: AXRequestGeneration
    ) {
        cancelRegisteredActionsSuperseded(
            by: applications,
            scope: scope
        )
        enqueue { [weak self] in
            guard let self,
                  observationsActive,
                  currentSession == session else {
                return
            }

            switch scope {
            case .all:
                replaceApplications(with: applications)
            case let .process(pid):
                if let descriptor = applications.first(where: {
                    $0.processIdentifier == pid
                }) {
                    if let existing = applicationsByPID[pid],
                       existing != descriptor {
                        removeObserver(for: pid)
                        removeWorkerWindows(for: pid)
                    }
                    applicationsByPID[pid] = descriptor
                }
            }

            enqueueSnapshot(
                scope: scope,
                payload: AXSnapshotPayload(
                    session: session,
                    delivery: .requested(generation: generation),
                    applicationLifecycles: applications.map(\.lifecycle)
                ),
                applications: applications
            )
        }
    }

    func removeApplication(session: UInt64, processIdentifier: pid_t) {
        cancelRegisteredActions(processIdentifier: processIdentifier)
        enqueue { [weak self] in
            guard let self, currentSession == session else { return }
            cancelSnapshotWork(affecting: processIdentifier)
            applicationsByPID.removeValue(forKey: processIdentifier)
            removeObserver(for: processIdentifier)
            removeWorkerWindows(for: processIdentifier)
        }
    }

    func perform(
        _ action: AXWindowAction,
        on window: AppWindow
    ) async -> AXWindowActionResult {
        let cancellation = AXActionCancellation()
        let registrationID = registerActionCancellation(
            cancellation,
            lifecycle: window.lifecycle
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue { [weak self] in
                    guard let self else {
                        continuation.resume(
                            returning: .failure("workerUnavailable")
                        )
                        return
                    }
                    guard !cancellation.isCancelled else {
                        unregisterActionCancellation(registrationID)
                        continuation.resume(
                            returning: .failure("actionCancelled")
                        )
                        return
                    }
                    let result = performOnWorker(
                        action,
                        on: window,
                        cancellation: cancellation
                    )
                    unregisterActionCancellation(registrationID)
                    continuation.resume(
                        returning: result
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func frame(for window: AppWindow) async -> CGRect? {
        await withCheckedContinuation { continuation in
            // This is a delayed diagnostic verification, not direct user
            // input. Keep it behind focus/minimize/close/resize commands.
            enqueueBackground { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                var recoveryBudget = AXActionRecoveryBudget(
                    maximumSynchronousEnumerations: 0
                )
                guard let element = liveElement(
                    for: window,
                    recoveryBudget: &recoveryBudget
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: frameAttribute(of: element))
            }
        }
    }

    private func registerActionCancellation(
        _ cancellation: AXActionCancellation,
        lifecycle: AXApplicationLifecycleStamp
    ) -> UUID {
        let id = UUID()
        lifecycleLock.withLock {
            registeredActionCancellations[id] =
                RegisteredActionCancellation(
                    lifecycle: lifecycle,
                    cancellation: cancellation
                )
        }
        return id
    }

    private func unregisterActionCancellation(_ id: UUID) {
        _ = lifecycleLock.withLock {
            registeredActionCancellations.removeValue(forKey: id)
        }
    }

    private func cancelAllRegisteredActions() {
        cancelRegisteredActions { _ in true }
    }

    private func cancelRegisteredActions(processIdentifier pid: pid_t) {
        cancelRegisteredActions {
            $0.lifecycle.processIdentifier == pid
        }
    }

    private func cancelRegisteredActionsSuperseded(
        by applications: [AXApplicationDescriptor],
        scope: AXWindowSnapshotScope
    ) {
        let lifecycleByPID = Dictionary(
            uniqueKeysWithValues: applications.map {
                ($0.processIdentifier, $0.lifecycle)
            }
        )
        cancelRegisteredActions { registered in
            let pid = registered.lifecycle.processIdentifier
            switch scope {
            case .all:
                return lifecycleByPID[pid] != registered.lifecycle
            case let .process(requestedPID):
                guard pid == requestedPID else { return false }
                return lifecycleByPID[pid] != registered.lifecycle
            }
        }
    }

    private func cancelRegisteredActions(
        where shouldCancel: (RegisteredActionCancellation) -> Bool
    ) {
        let cancellations: [AXActionCancellation] =
            lifecycleLock.withLock {
                let ids = registeredActionCancellations.compactMap {
                    id, registered in
                    shouldCancel(registered) ? id : nil
                }
                return ids.compactMap {
                    registeredActionCancellations
                        .removeValue(forKey: $0)?
                        .cancellation
                }
            }
        for cancellation in cancellations {
            cancellation.cancel()
        }
    }

    // MARK: - Dedicated thread/run loop

    private func threadMain() {
        autoreleasepool {
            guard let currentRunLoop = CFRunLoopGetCurrent() else {
                return
            }
            var sourceContext = CFRunLoopSourceContext()
            let keepAliveSource = CFRunLoopSourceCreate(nil, 0, &sourceContext)
            CFRunLoopAddSource(
                currentRunLoop,
                keepAliveSource,
                CFRunLoopMode.defaultMode
            )

            // The system-wide element applies this timeout to every AX object
            // in the process. A bad target can still occupy this worker for up
            // to one second, but it can no longer stall AppKit's main run loop.
            _ = AXUIElementSetMessagingTimeout(
                AXUIElementCreateSystemWide(),
                1.0
            )

            lifecycleLock.lock()
            runLoop = currentRunLoop
            let shouldSchedule =
                !commandQueue.isEmpty && !commandPumpScheduled
            if shouldSchedule {
                commandPumpScheduled = true
            }
            lifecycleLock.unlock()

            // Init never waits for run-loop readiness. Commands accepted
            // during startup stay in commandQueue and the worker schedules
            // their first pump as soon as its run loop exists.
            if shouldSchedule {
                scheduleCommandPump(on: currentRunLoop)
            }

            CFRunLoopRun()
        }
    }

    /// User/lifecycle commands always outrank background enumeration. Because
    /// the queued run-loop block chooses from these arrays only when it starts,
    /// a click also jumps ahead of a scan drain that was scheduled earlier but
    /// has not begun executing.
    private func enqueue(_ block: @escaping Command) {
        enqueueCommand(block, priority: .user)
    }

    private func enqueueBackground(_ block: @escaping Command) {
        enqueueCommand(block, priority: .background)
    }

    private func enqueueCommand(
        _ block: @escaping Command,
        priority: AXCommandPriority
    ) {
        lifecycleLock.lock()
        let targetRunLoop = runLoop
        commandQueue.enqueue(block, priority: priority)
        let shouldSchedule = targetRunLoop != nil && !commandPumpScheduled
        if shouldSchedule {
            commandPumpScheduled = true
        }
        lifecycleLock.unlock()
        guard shouldSchedule, let targetRunLoop else { return }

        scheduleCommandPump(on: targetRunLoop)
    }

    private func scheduleCommandPump(on targetRunLoop: CFRunLoop) {
        CFRunLoopPerformBlock(
            targetRunLoop,
            CFRunLoopMode.defaultMode.rawValue,
            { [weak self] in
                self?.drainOneCommand()
            }
        )
        CFRunLoopWakeUp(targetRunLoop)
    }

    private func drainOneCommand() {
        lifecycleLock.lock()
        let command = commandQueue.dequeue()
        lifecycleLock.unlock()

        command?()

        lifecycleLock.lock()
        let hasMoreCommands = !commandQueue.isEmpty
        let targetRunLoop = runLoop
        if !hasMoreCommands {
            commandPumpScheduled = false
        }
        lifecycleLock.unlock()

        if hasMoreCommands, let targetRunLoop {
            scheduleCommandPump(on: targetRunLoop)
        }
    }

    // MARK: - Snapshot coalescing

    private func enqueueSnapshot(
        scope: AXWindowSnapshotScope,
        payload: AXSnapshotPayload,
        applications: [AXApplicationDescriptor]
    ) {
        removeSnapshotElements(scope: scope)
        if activeSnapshotResult?.scope == scope {
            activeSnapshotResult = nil
        }

        // A targeted result must run before an older partial global scan so
        // the latter cannot overwrite it. Preserve the global request's full
        // inputs, however: after the targeted scan, restart the global scan
        // from the beginning so every other application's snapshot still gets
        // refreshed and the original requester still receives a completion.
        let shouldRestartGlobal: Bool
        if case .process = scope {
            shouldRestartGlobal =
                cancelGlobalPlanPreservingRestartRequest()
        } else {
            shouldRestartGlobal = false
        }

        let generation = snapshotWorkGenerations.issue(for: scope)
        snapshotScheduler.enqueue(
            key: scope,
            generation: generation,
            payload: payload,
            units: applications.map(SnapshotWorkUnit.application)
        )

        switch scope {
        case .all:
            restartableGlobalSnapshot.begin(
                generation: generation,
                payload: payload,
                units: applications
            )
        case .process where shouldRestartGlobal:
            enqueueRestartedGlobalSnapshot()
        case .process:
            break
        }
        scheduleSnapshotDrainIfNeeded()
    }

    @discardableResult
    private func cancelGlobalPlanPreservingRestartRequest() -> Bool {
        guard restartableGlobalSnapshot.current != nil else {
            return false
        }
        snapshotScheduler.cancel(.all)
        removeSnapshotElements(scope: .all)
        if activeSnapshotResult?.scope == .all {
            activeSnapshotResult = nil
        }
        return true
    }

    private func enqueueRestartedGlobalSnapshot(
        excludingProcessIdentifiers excludedPIDs: Set<pid_t> = []
    ) {
        let restartedGeneration =
            snapshotWorkGenerations.issue(for: .all)
        let applications = currentApplications(
            from: restartableGlobalSnapshot.current
        ).filter {
            !excludedPIDs.contains($0.processIdentifier)
        }
        guard let restarted = restartableGlobalSnapshot.restart(
            generation: restartedGeneration,
            units: applications
        ) else {
            return
        }
        snapshotScheduler.enqueue(
            key: .all,
            generation: restarted.generation,
            payload: restarted.payload,
            units: restarted.units.map(SnapshotWorkUnit.application)
        )
    }

    private func currentApplications(
        from request:
            AXRestartableRequestState<
                AXSnapshotPayload,
                AXApplicationDescriptor
            >.Request?
    ) -> [AXApplicationDescriptor] {
        guard let request else { return [] }
        return request.units.compactMap { descriptor in
            guard let current =
                    applicationsByPID[descriptor.processIdentifier],
                  current.lifecycle == descriptor.lifecycle else {
                return nil
            }
            return current
        }
    }

    private func scheduleSnapshotDrainIfNeeded() {
        guard !snapshotDrainScheduled else { return }
        snapshotDrainScheduled = true
        enqueueBackground { [weak self] in
            self?.drainOneSnapshotRequest()
        }
    }

    private func drainOneSnapshotRequest() {
        snapshotDrainScheduled = false
        guard observationsActive else {
            return
        }
        guard let slice = snapshotScheduler.nextSlice() else {
            drainOneObserverRegistration()
            return
        }
        guard slice.payload.session == currentSession else {
            scheduleSnapshotDrainIfNeeded()
            return
        }

        if activeSnapshotResult?.scope != slice.key
            || activeSnapshotResult?.generation != slice.generation {
            activeSnapshotResult = SnapshotAccumulator(
                scope: slice.key,
                generation: slice.generation,
                windows: [],
                seenIDsByPID: [:],
                preserveUnseenPIDs: [],
                decodedCandidatesByPID: [:]
            )
        }

        if let unit = slice.unit {
            switch unit {
            case let .application(descriptor):
                discoverWindowElements(
                    for: descriptor,
                    slice: slice
                )
            case let .window(
                descriptor,
                handleToken,
                isLastForApplication
            ):
                decodeWindowElement(
                    for: descriptor,
                    handleToken: handleToken
                )
                if isLastForApplication {
                    finalizeProcessEnumeration(
                        processIdentifier: descriptor.processIdentifier
                    )
                }
            }
        } else if case let .process(pid) = slice.key {
            removeWorkerWindows(for: pid)
        }

        guard snapshotScheduler.isCurrent(slice),
              observationsActive,
              slice.payload.session == currentSession else {
            removeSnapshotElements(
                scope: slice.key,
                generation: slice.generation
            )
            activeSnapshotResult = nil
            scheduleSnapshotDrainIfNeeded()
            return
        }

        if snapshotScheduler.isComplete(after: slice) {
            let windows = activeSnapshotResult?.windows ?? []
            removeSnapshotElements(
                scope: slice.key,
                generation: slice.generation
            )
            activeSnapshotResult = nil
            if slice.key == .all {
                restartableGlobalSnapshot.complete(
                    generation: slice.generation
                )
            }
            switch slice.payload.delivery {
            case let .requested(generation):
                let batches = slice.payload.applicationLifecycles.map {
                    lifecycle in
                    AXApplicationLifecycleValue(
                        lifecycle: lifecycle,
                        value: windows.filter {
                            $0.lifecycle == lifecycle
                        }
                    )
                }
                emit(
                    .requestedSnapshot(
                        session: currentSession,
                        scope: slice.key,
                        generation: generation,
                        batches: batches
                    )
                )
            case let .observed(
                lifecycle,
                invalidatedPreviewIdentifier
            ):
                emit(
                    .processSnapshot(
                        session: currentSession,
                        generation: slice.generation,
                        lifecycle: lifecycle,
                        windows: windows,
                        invalidatedPreviewIdentifier:
                            invalidatedPreviewIdentifier
                    )
                )
            }
        }

        // Enqueue, rather than recurse, so user actions outrank every remaining
        // app discovery, window decode, and observer-registration unit.
        scheduleSnapshotDrainIfNeeded()
    }

    // MARK: - Observer lifecycle

    private func replaceApplications(
        with applications: [AXApplicationDescriptor]
    ) {
        let nextByPID = Dictionary(
            uniqueKeysWithValues: applications.map {
                ($0.processIdentifier, $0)
            }
        )

        for pid in Array(applicationObservers.keys)
        where nextByPID[pid] == nil {
            removeObserver(for: pid)
            removeWorkerWindows(for: pid)
        }
        for (pid, descriptor) in nextByPID {
            if let existing = applicationsByPID[pid],
               existing != descriptor {
                removeObserver(for: pid)
                removeWorkerWindows(for: pid)
            }
        }
        applicationsByPID = nextByPID
    }

    private func installObserverIfNeeded(
        for application: AXApplicationDescriptor
    ) {
        let pid = application.processIdentifier
        guard pid > 0 else { return }

        if applicationObservers[pid] != nil {
            // A bounded retry cycle that exhausted stays dormant until normal
            // snapshot work touches this process again. That permits eventual
            // recovery without turning an unresponsive app into a retry loop.
            let retryable = exhaustedObserverRegistrations.filter {
                $0.lifecycle == application.lifecycle
            }
            if !retryable.isEmpty {
                let now = ProcessInfo.processInfo.systemUptime
                for key in retryable {
                    exhaustedObserverRegistrations.remove(key)
                    observerRegistrationRetries.enqueue(key, now: now)
                }
            }
            return
        }

        var observer: AXObserver?
        let status = AXObserverCreate(pid, axWindowWorkerObserverCallback, &observer)
        guard status == .success, let observer else { return }

        applicationObservers[pid] = observer
        let now = ProcessInfo.processInfo.systemUptime
        let names: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
            kAXApplicationActivatedNotification as CFString,
            kAXApplicationHiddenNotification as CFString,
            kAXApplicationShownNotification as CFString,
        ]
        for name in names {
            observerRegistrationRetries.enqueue(
                ObserverNotificationRegistrationKey(
                    lifecycle: application.lifecycle,
                    notificationName: name as String
                ),
                now: now
            )
        }
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.commonModes
        )
    }

    /// Registers one remote notification per run-loop turn. Registration is
    /// best-effort background work: a click submitted while this call waits is
    /// ahead of the next registration and the next snapshot slice.
    private func drainOneObserverRegistration() {
        cancelObserverRegistrationWake()
        let now = ProcessInfo.processInfo.systemUptime
        guard let attempt = observerRegistrationRetries.nextReady(now: now) else {
            scheduleObserverRegistrationWorkIfNeeded(now: now)
            return
        }

        let key = attempt.key
        let pid = key.lifecycle.processIdentifier
        guard applicationsByPID[pid]?.lifecycle == key.lifecycle,
              let observer = applicationObservers[pid] else {
            observerRegistrationRetries.cancel(key)
            scheduleObserverRegistrationWorkIfNeeded(
                now: ProcessInfo.processInfo.systemUptime
            )
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AXObserverAddNotification(
            observer,
            appElement,
            key.notificationName as CFString,
            context
        )
        let resolution = observerRegistrationRetries.resolve(
            attempt,
            outcome: notificationRegistrationOutcome(for: status),
            now: ProcessInfo.processInfo.systemUptime
        )
        if case .exhausted = resolution {
            exhaustedObserverRegistrations.insert(key)
        }
        scheduleObserverRegistrationWorkIfNeeded(
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func removeObserver(for pid: pid_t) {
        observerRegistrationRetries.cancel {
            $0.lifecycle.processIdentifier == pid
        }
        exhaustedObserverRegistrations = Set(
            exhaustedObserverRegistrations.filter {
                $0.lifecycle.processIdentifier != pid
            }
        )
        guard let observer = applicationObservers.removeValue(forKey: pid) else {
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.commonModes
        )
    }

    private func removeAllObservers() {
        for pid in Array(applicationObservers.keys) {
            removeObserver(for: pid)
        }
    }

    private func notificationRegistrationOutcome(
        for status: AXError
    ) -> AXNotificationRegistrationOutcome {
        switch status {
        case .success:
            .registered
        case .notificationAlreadyRegistered:
            .alreadyRegistered
        case .cannotComplete:
            .cannotComplete
        case .notificationUnsupported:
            .unsupported
        default:
            .terminalFailure
        }
    }

    /// Schedules ready registration work immediately, or one timer for the
    /// earliest delayed retry. The timer lives on the AX worker's run loop and
    /// therefore never blocks AppKit or competes with click handling.
    private func scheduleObserverRegistrationWorkIfNeeded(
        now: TimeInterval
    ) {
        guard observationsActive,
              let deadline = observerRegistrationRetries.nextDeadline else {
            cancelObserverRegistrationWake()
            return
        }

        if deadline <= now {
            cancelObserverRegistrationWake()
            scheduleSnapshotDrainIfNeeded()
            return
        }

        if let scheduled = observerRegistrationWakeDeadline,
           scheduled <= deadline {
            return
        }
        cancelObserverRegistrationWake()

        let delay = max(deadline - now, 0.001)
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + delay,
            0,
            0,
            0
        ) { [weak self] _ in
            guard let self else { return }
            observerRegistrationWakeTimer = nil
            observerRegistrationWakeDeadline = nil
            scheduleSnapshotDrainIfNeeded()
        }
        observerRegistrationWakeTimer = timer
        observerRegistrationWakeDeadline = deadline
        CFRunLoopAddTimer(
            CFRunLoopGetCurrent(),
            timer,
            CFRunLoopMode.commonModes
        )
    }

    private func cancelObserverRegistrationWake() {
        if let timer = observerRegistrationWakeTimer {
            CFRunLoopTimerInvalidate(timer)
        }
        observerRegistrationWakeTimer = nil
        observerRegistrationWakeDeadline = nil
    }

    private func pid(for observer: AXObserver) -> pid_t? {
        applicationObservers.first(where: { $0.value === observer })?.key
    }

    fileprivate func enqueueNotification(
        observer: AXObserver,
        element: AXUIElement,
        notificationName: CFString
    ) {
        nextObserverEventToken &+= 1
        if nextObserverEventToken == 0 {
            nextObserverEventToken = 1
        }
        let token = nextObserverEventToken
        pendingObserverEventsByToken[token] = PendingObserverEvent(
            session: currentSession,
            observer: observer,
            element: element,
            notificationName: notificationName
        )
        enqueueBackground { [weak self] in
            self?.handleNotification(token: token)
        }
    }

    private func handleNotification(token: UInt64) {
        guard let pending = pendingObserverEventsByToken.removeValue(
            forKey: token
        ),
        pending.session == currentSession else {
            return
        }
        let observer = pending.observer
        let element = pending.element
        let notificationName = pending.notificationName
        guard observationsActive,
              let pid = pid(for: observer),
              let application = applicationsByPID[pid] else {
            return
        }
        let name = notificationName as String

        switch name {
        case kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            emitFocusedWindow(element: element, pid: pid)

        case kAXApplicationActivatedNotification,
             kAXApplicationShownNotification:
            emitFocusedWindowForApplication(pid: pid)

        case kAXWindowCreatedNotification,
             kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification,
             kAXWindowMovedNotification,
             kAXTitleChangedNotification:
            synchronizeProcess(pid: pid)

        case kAXWindowResizedNotification:
            let invalidatedID = existingWindowID(
                for: element,
                application: application
            )
            synchronizeProcess(
                pid: pid,
                invalidatedPreviewIdentifier: invalidatedID?.stableString
            )

        case kAXApplicationHiddenNotification:
            cancelSnapshotWork(
                affecting: pid,
                includeAffectedProcessInGlobalRestart: false
            )
            removeWorkerWindows(for: pid)
            emit(
                .processHidden(
                    session: currentSession,
                    lifecycle: application.lifecycle
                )
            )

        case kAXUIElementDestroyedNotification:
            cancelSnapshotWork(
                affecting: pid,
                includeAffectedProcessInGlobalRestart: true
            )
            let id = existingWindowID(
                for: element,
                application: application
            )
            if let id {
                recordsByID.removeValue(forKey: id)
                windowsByPID[pid]?.removeAll { $0.id == id }
            }
            emit(
                .windowDestroyed(
                    session: currentSession,
                    lifecycle: application.lifecycle,
                    windowID: id
                )
            )

        default:
            break
        }
    }

    // MARK: - Window enumeration/identity

    private func synchronizeProcess(
        pid: pid_t,
        invalidatedPreviewIdentifier: String? = nil
    ) {
        guard let application = applicationsByPID[pid] else { return }
        let applications = [application]
        enqueueSnapshot(
            scope: .process(pid),
            payload: AXSnapshotPayload(
                session: currentSession,
                delivery: .observed(
                    lifecycle: application.lifecycle,
                    invalidatedPreviewIdentifier:
                        invalidatedPreviewIdentifier
                ),
                applicationLifecycles: [application.lifecycle]
            ),
            applications: applications
        )
    }

    private func cancelSnapshotWork(
        affecting pid: pid_t,
        includeAffectedProcessInGlobalRestart: Bool = false
    ) {
        let shouldRestartGlobal =
            cancelGlobalPlanPreservingRestartRequest()
        snapshotScheduler.cancel(.process(pid))
        removeSnapshotElements(scope: .process(pid))
        if activeSnapshotResult?.scope == .process(pid) {
            activeSnapshotResult = nil
        }
        if shouldRestartGlobal {
            enqueueRestartedGlobalSnapshot(
                excludingProcessIdentifiers:
                    includeAffectedProcessInGlobalRestart ? [] : [pid]
            )
            scheduleSnapshotDrainIfNeeded()
        }
    }

    private func discoverWindowElements(
        for application: AXApplicationDescriptor,
        slice: AXCooperativeWorkSlice<
            AXWindowSnapshotScope,
            SnapshotWorkUnit,
            AXSnapshotPayload
        >
    ) {
        let pid = application.processIdentifier
        guard pid > 0 else {
            finalizeProcessEnumeration(processIdentifier: pid)
            return
        }
        installObserverIfNeeded(for: application)

        guard var accumulator = activeSnapshotResult else { return }
        accumulator.seenIDsByPID[pid] = []
        activeSnapshotResult = accumulator

        let elements: [AXUIElement]
        switch windowElements(processIdentifier: pid) {
        case let .success(discovered, isComplete):
            elements = discovered
            if !isComplete {
                preserveLastKnownSnapshot(processIdentifier: pid)
            }
        case .failure:
            preserveLastKnownSnapshot(processIdentifier: pid)
            finalizeProcessEnumeration(processIdentifier: pid)
            return
        }

        guard !elements.isEmpty else {
            finalizeProcessEnumeration(processIdentifier: pid)
            return
        }

        let units = elements.enumerated().map { index, element in
            nextSnapshotElementToken &+= 1
            if nextSnapshotElementToken == 0 {
                nextSnapshotElementToken = 1
            }
            let token = nextSnapshotElementToken
            snapshotElementsByToken[token] = SnapshotElementRecord(
                scope: slice.key,
                generation: slice.generation,
                element: element
            )
            return SnapshotWorkUnit.window(
                application: application,
                handleToken: token,
                isLastForApplication: index == elements.count - 1
            )
        }
        _ = snapshotScheduler.insertAfterCurrentSlice(
            units,
            for: slice
        )
    }

    private func decodeWindowElement(
        for application: AXApplicationDescriptor,
        handleToken: UInt64
    ) {
        guard let record = snapshotElementsByToken.removeValue(
            forKey: handleToken
        ),
        activeSnapshotResult?.scope == record.scope,
        activeSnapshotResult?.generation == record.generation else {
            return
        }
        let element = record.element
        let existingID = existingWindowID(
            for: element,
            application: application
        )
        decodeEncounteredTransientFailure = false
        guard let attributes = windowAttributeSnapshot(of: element) else {
            preserveLastKnownSnapshot(
                processIdentifier: application.processIdentifier,
                discoveredID: existingID
            )
            return
        }
        guard attributes.role == kAXWindowRole as String else {
            if decodeEncounteredTransientFailure {
                preserveLastKnownSnapshot(
                    processIdentifier: application.processIdentifier,
                    discoveredID: existingID
                )
            }
            return
        }
        let candidate = makeDecodedWindowCandidate(
            element: element,
            application: application,
            attributes: attributes
        )
        let decodeIsConclusive = !decodeEncounteredTransientFailure
        let candidateIsAccepted = decodeIsConclusive
            && passesAppDiscriminator(
                application: application,
                title: candidate.resolvedTitle,
                frame: candidate.evidence.frame,
                subrole: candidate.subrole
            )
        guard AXWindowDecodeCommitPolicy.shouldCommit(
            decodeIsConclusive: decodeIsConclusive,
            candidateIsAccepted: candidateIsAccepted
        ) else {
            if !decodeIsConclusive {
                preserveLastKnownSnapshot(
                    processIdentifier: application.processIdentifier,
                    discoveredID: existingID
                )
            }
            return
        }
        guard var accumulator = activeSnapshotResult else {
            return
        }
        accumulator.decodedCandidatesByPID[
            application.processIdentifier,
            default: []
        ].append(candidate)
        activeSnapshotResult = accumulator
    }

    private func finalizeProcessEnumeration(processIdentifier pid: pid_t) {
        commitDecodedCandidates(processIdentifier: pid)
        let seenIDs = activeSnapshotResult?.seenIDsByPID[pid] ?? []
        let previousIDs = Set(
            recordsByID.compactMap { id, record in
                record.processIdentifier == pid ? id : nil
            }
        )
        let preserveUnseen =
            activeSnapshotResult?.preserveUnseenPIDs.contains(pid) == true
        let retainedIDs = AXSnapshotIdentityReducer.retainedIDs(
            previous: previousIDs,
            discovered: seenIDs,
            preserveUnseen: preserveUnseen
        )
        let staleIDs = previousIDs.subtracting(retainedIDs)
        for id in staleIDs {
            recordsByID.removeValue(forKey: id)
        }

        if preserveUnseen {
            preserveLastKnownSnapshot(processIdentifier: pid)
        }
        windowsByPID[pid] = activeSnapshotResult?.windows.filter {
            $0.processIdentifier == pid
        } ?? []
    }

    private func preserveLastKnownSnapshot(
        processIdentifier pid: pid_t,
        discoveredID: WindowID? = nil
    ) {
        guard var accumulator = activeSnapshotResult else { return }
        accumulator.preserveUnseenPIDs.insert(pid)
        if let discoveredID {
            accumulator.seenIDsByPID[pid, default: []].insert(
                discoveredID
            )
        }
        let existingResultIDs = Set(
            accumulator.windows.map(\.id)
        )
        accumulator.windows.append(
            contentsOf: (windowsByPID[pid] ?? []).filter {
                !existingResultIDs.contains($0.id)
            }
        )
        activeSnapshotResult = accumulator
    }

    private func removeSnapshotElements(
        scope: AXWindowSnapshotScope,
        generation: AXRequestGeneration? = nil
    ) {
        let tokens: [UInt64] = snapshotElementsByToken.compactMap {
            token, record -> UInt64? in
            guard record.scope == scope else { return nil }
            if let generation, record.generation != generation {
                return nil
            }
            return token
        }
        for token in tokens {
            snapshotElementsByToken.removeValue(forKey: token)
        }
    }

    private func windowElements(
        processIdentifier pid: pid_t
    ) -> WindowElementListResult {
        let retainedWindowLimit = 256
        let appElement = AXUIElementCreateApplication(pid)
        var rawWindows: CFArray?
        let status = AXUIElementCopyAttributeValues(
                appElement,
                kAXWindowsAttribute as CFString,
                0,
                retainedWindowLimit + 1,
                &rawWindows
              )
        guard status == .success else {
            return .failure(status)
        }
        guard let elements = rawWindows as? [AXUIElement] else {
            return .failure(.failure)
        }
        let isComplete = AXBoundedEnumerationPolicy.isComplete(
            returnedCount: elements.count,
            publishedLimit: retainedWindowLimit
        )
        return .success(
            Array(elements.prefix(retainedWindowLimit)),
            isComplete: isComplete
        )
    }

    /// Fetches the complete per-window snapshot in one remote AX message.
    /// The prior implementation issued up to seven sequential messages before
    /// yielding, so one unresponsive application could occupy the action
    /// worker for several timeout intervals.
    private func windowAttributeSnapshot(
        of element: AXUIElement
    ) -> WindowAttributeSnapshot? {
        let attributes: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXMinimizedAttribute as CFString,
            "AXWindowNumber" as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
        ]
        var rawValues: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        guard status == .success, let rawValues else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        let values = rawValues as NSArray
        guard values.count == attributes.count else {
            decodeEncounteredTransientFailure = true
            return nil
        }

        let role = decodedString(
            attributeValue(in: values, at: 0, required: true)
        )
        let subrole = decodedString(
            attributeValue(in: values, at: 1, required: false)
        )
        let rawTitle = decodedString(
            attributeValue(in: values, at: 2, required: false)
        )
        let minimized = decodedBool(
            attributeValue(in: values, at: 3, required: false)
        )
        let windowNumber = decodedInt(
            attributeValue(in: values, at: 4, required: false)
        )
        let position = decodedPoint(
            attributeValue(in: values, at: 5, required: false)
        )
        let size = decodedSize(
            attributeValue(in: values, at: 6, required: false)
        )
        if (position == nil) != (size == nil) {
            decodeEncounteredTransientFailure = true
        }

        return WindowAttributeSnapshot(
            rawTitle: rawTitle,
            role: role,
            subrole: subrole,
            isMinimized: minimized,
            windowNumber: windowNumber,
            frame: position.flatMap { origin in
                size.map { CGRect(origin: origin, size: $0) }
            }
        )
    }

    private func attributeValue(
        in values: NSArray,
        at index: Int,
        required: Bool
    ) -> CFTypeRef? {
        guard index >= 0, index < values.count else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        let object = values[index] as AnyObject
        let value = object as CFTypeRef
        if CFGetTypeID(value) == CFNullGetTypeID() {
            if required {
                decodeEncounteredTransientFailure = true
            }
            return nil
        }
        if let error = embeddedAXError(in: value) {
            if AXAttributeReadPreservationPolicy.shouldPreserveLastKnown(
                statusRawValue: error.rawValue,
                required: required
            ) {
                decodeEncounteredTransientFailure = true
            }
            return nil
        }
        return value
    }

    private func embeddedAXError(in value: CFTypeRef) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .axError else { return nil }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else {
            decodeEncounteredTransientFailure = true
            return .failure
        }
        return error
    }

    private func decodedString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return value as? String
    }

    private func decodedBool(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return number.boolValue
    }

    private func decodedInt(_ value: CFTypeRef?) -> Int? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == CFNumberGetTypeID(),
              let number = value as? NSNumber else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return number.intValue
    }

    private func decodedPoint(_ value: CFTypeRef?) -> CGPoint? {
        guard let axValue = decodedAXValue(value, expectedType: .cgPoint) else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return point
    }

    private func decodedSize(_ value: CFTypeRef?) -> CGSize? {
        guard let axValue = decodedAXValue(value, expectedType: .cgSize) else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return size
    }

    private func decodedAXValue(
        _ value: CFTypeRef?,
        expectedType: AXValueType
    ) -> AXValue? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == expectedType else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return axValue
    }

    private func makeDecodedWindowCandidate(
        element: AXUIElement,
        application: AXApplicationDescriptor,
        attributes: WindowAttributeSnapshot
    ) -> DecodedWindowCandidate {
        let rawTitle = attributes.rawTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (rawTitle?.isEmpty ?? true)
            ? application.displayName
            : (rawTitle ?? application.displayName)
        let discoveredCGWindowID = cgWindowID(
            of: element,
            processIdentifier: application.processIdentifier,
            title: resolvedTitle,
            frame: attributes.frame
        )
        return DecodedWindowCandidate(
            element: element,
            application: application,
            resolvedTitle: resolvedTitle,
            subrole: attributes.subrole,
            isMinimized: attributes.isMinimized ?? false,
            evidence: AXWindowRebindEvidence(
                cgWindowID: discoveredCGWindowID,
                windowNumber: attributes.windowNumber,
                title: rawTitle,
                frame: attributes.frame
            )
        )
    }

    /// Identity and handle updates are committed only after every candidate for
    /// this process has completed decoding. Exact AX equality is assigned first;
    /// all replacement proxies are then resolved as one global, one-to-one
    /// evidence graph. Until this point `recordsByID` remains last-known-good.
    private func commitDecodedCandidates(processIdentifier pid: pid_t) {
        guard var accumulator = activeSnapshotResult else { return }
        let candidates =
            accumulator.decodedCandidatesByPID.removeValue(forKey: pid) ?? []
        guard !candidates.isEmpty else {
            activeSnapshotResult = accumulator
            return
        }

        let lifecycle = candidates[0].application.lifecycle
        guard candidates.allSatisfy({
            $0.application.processIdentifier == pid
                && $0.application.lifecycle == lifecycle
        }),
        applicationsByPID[pid]?.lifecycle == lifecycle else {
            activeSnapshotResult = accumulator
            preserveLastKnownSnapshot(processIdentifier: pid)
            return
        }

        var assignedIDByCandidate: [Int: WindowID] = [:]
        var claimedPriorIDs =
            accumulator.seenIDsByPID[pid] ?? Set<WindowID>()
        var duplicateCandidates = Set<Int>()
        var canonicalCandidates: [Int] = []

        // AX can occasionally return the same proxy more than once. Treat
        // repeated exact handles as one candidate instead of allocating a
        // second identity for the duplicate row.
        for candidateIndex in candidates.indices {
            if canonicalCandidates.contains(where: {
                CFEqual(
                    candidates[$0].element,
                    candidates[candidateIndex].element
                )
            }) {
                duplicateCandidates.insert(candidateIndex)
            } else {
                canonicalCandidates.append(candidateIndex)
            }
        }

        // Resolve exact handles without mutating their records. The claimed set
        // also contains IDs preserved by an inconclusive duplicate decode, so a
        // later candidate in this scan cannot steal that action handle.
        for candidateIndex in canonicalCandidates {
            let exactIDs = recordsByID.compactMap { id, record -> WindowID? in
                guard record.processIdentifier == pid,
                      record.lifecycle == lifecycle,
                      CFEqual(
                          record.element,
                          candidates[candidateIndex].element
                      ) else {
                    return nil
                }
                return id
            }
            guard exactIDs.count == 1, let exactID = exactIDs.first else {
                continue
            }
            if claimedPriorIDs.insert(exactID).inserted {
                assignedIDByCandidate[candidateIndex] = exactID
            } else {
                duplicateCandidates.insert(candidateIndex)
            }
        }

        let processSnapshotIsConclusive =
            !accumulator.preserveUnseenPIDs.contains(pid)
        let priorWindows: [AppWindow]
        if AXWindowDecodeCommitPolicy.allowsHeuristicRebinding(
            processSnapshotIsConclusive: processSnapshotIsConclusive
        ) {
            priorWindows = (windowsByPID[pid] ?? []).filter {
                $0.lifecycle == lifecycle
                    && recordsByID[$0.id] != nil
                    && !claimedPriorIDs.contains($0.id)
            }
        } else {
            // A failed sibling decode may be the real owner of any unmatched
            // prior identity. Preserve every such handle until a conclusive
            // process scan can resolve all candidates together.
            priorWindows = []
        }
        let unmatchedCandidates = canonicalCandidates.filter {
            assignedIDByCandidate[$0] == nil
                && !duplicateCandidates.contains($0)
        }
        let heuristicAssignments =
            AXWindowRebindMatcher.globallyUniqueAssignments(
                previous: priorWindows.map {
                    rebindEvidence(for: $0)
                },
                candidates: unmatchedCandidates.map {
                    candidates[$0].evidence
                }
            )
        for (candidateOffset, previousOffset) in heuristicAssignments {
            let candidateIndex = unmatchedCandidates[candidateOffset]
            let priorID = priorWindows[previousOffset].id
            guard claimedPriorIDs.insert(priorID).inserted else {
                duplicateCandidates.insert(candidateIndex)
                continue
            }
            assignedIDByCandidate[candidateIndex] = priorID
        }

        var seenIDs = accumulator.seenIDsByPID[pid] ?? []
        for candidateIndex in canonicalCandidates
        where !duplicateCandidates.contains(candidateIndex) {
            let candidate = candidates[candidateIndex]
            let id = assignedIDByCandidate[candidateIndex]
                ?? allocateWindowID(
                    processIdentifier: pid,
                    cgWindowID: candidate.evidence.cgWindowID
                )
            guard seenIDs.insert(id).inserted else { continue }
            let effectiveCGWindowID =
                candidate.evidence.cgWindowID ?? recordsByID[id]?.cgWindowID
            let window = AppWindow(
                id: id,
                lifecycle: lifecycle,
                bundleIdentifier: candidate.application.bundleIdentifier,
                processIdentifier: pid,
                appDisplayName: candidate.application.displayName,
                windowTitle: candidate.resolvedTitle,
                isMinimized: candidate.isMinimized,
                windowNumber: candidate.evidence.windowNumber,
                cgWindowID: effectiveCGWindowID,
                frame: candidate.evidence.frame
            )

            // This is the sole mutation point for a decoded candidate. Both the
            // immutable DTO and its AX action handle advance together.
            recordsByID[id] = ElementRecord(
                id: id,
                element: candidate.element,
                processIdentifier: pid,
                lifecycle: lifecycle,
                cgWindowID: effectiveCGWindowID
            )
            AXSnapshotValueReducer.upsert(
                window,
                into: &accumulator.windows
            )
        }
        accumulator.seenIDsByPID[pid] = seenIDs
        activeSnapshotResult = accumulator
    }

    private func allocateWindowID(
        processIdentifier: pid_t,
        cgWindowID: CGWindowID?
    ) -> WindowID {
        nextWindowToken &+= 1
        if nextWindowToken == 0 {
            nextWindowToken = 1
        }
        let id = WindowID(
            rawValue: nextWindowToken,
            stableString: AXWindowIdentityString.make(
                processIdentifier: processIdentifier,
                token: nextWindowToken,
                cgWindowID: cgWindowID
            )
        )
        return id
    }

    private func existingWindowID(
        for element: AXUIElement,
        application: AXApplicationDescriptor
    ) -> WindowID? {
        recordsByID.first(where: {
            $0.value.processIdentifier == application.processIdentifier
                && $0.value.lifecycle == application.lifecycle
                && CFEqual($0.value.element, element)
        })?.key
    }

    private func removeWorkerWindows(for pid: pid_t) {
        windowsByPID.removeValue(forKey: pid)
        let ids = recordsByID.compactMap { id, record in
            record.processIdentifier == pid ? id : nil
        }
        for id in ids {
            recordsByID.removeValue(forKey: id)
        }
    }

    // MARK: - Focus notifications

    private func emitFocusedWindow(element: AXUIElement, pid: pid_t) {
        guard let application = applicationsByPID[pid] else { return }
        guard let id = existingWindowID(
            for: element,
            application: application
        ) else {
            synchronizeProcess(pid: pid)
            return
        }
        emit(
            .focusedWindowChanged(
                session: currentSession,
                lifecycle: application.lifecycle,
                windowID: id
            )
        )
    }

    private func emitFocusedWindowForApplication(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                &value
              ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            synchronizeProcess(pid: pid)
            return
        }
        emitFocusedWindow(element: value as! AXUIElement, pid: pid)
    }

    // MARK: - Actions

    private func performOnWorker(
        _ action: AXWindowAction,
        on window: AppWindow,
        cancellation: AXActionCancellation
    ) -> AXWindowActionResult {
        if let failure = actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) {
            return failure
        }
        liveElementFailureReason = "liveElementUnavailable"
        var recoveryBudget = AXActionRecoveryBudget()
        guard let element = liveElement(
            for: window,
            recoveryBudget: &recoveryBudget
        ) else {
            return .failure(liveElementFailureReason)
        }

        // Cancellation can arrive while this command is waiting on any prior
        // worker operation. Recheck on the worker immediately before touching
        // the target application.
        if let failure = actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) {
            return failure
        }
        let firstAttempt = performActionAttempt(
            action,
            on: window,
            element: element,
            cancellation: cancellation
        )
        if let failure = actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) {
            return failure
        }
        guard firstAttempt.shouldRefreshStaleElement else {
            return firstAttempt.result
        }

        // The proxy can die after the liveness probe but before the action.
        // Refresh and retry exactly once, and only for kAXErrorInvalidUIElement,
        // whose contract proves the first action targeted no valid element.
        // Ambiguous errors such as cannotComplete are never replayed.
        if let failure = actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) {
            return failure
        }
        guard let refreshedElement = liveElement(
            for: window,
            forceRefresh: true,
            recoveryBudget: &recoveryBudget
        ) else {
            return .failure("staleActionRefreshFailed:\(liveElementFailureReason)")
        }
        if let failure = actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) {
            return failure
        }
        let retryAttempt = performActionAttempt(
            action,
            on: window,
            element: refreshedElement,
            cancellation: cancellation
        )
        if let failure = actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) {
            return failure
        }
        return retryAttempt.result
    }

    private func actionPreflightFailure(
        cancellation: AXActionCancellation,
        window: AppWindow
    ) -> AXWindowActionResult? {
        let lifecycleIsCurrent =
            applicationsByPID[window.processIdentifier]?.lifecycle
                == window.lifecycle
        guard AXActionExecutionPolicy.shouldProceed(
            isCancelled: cancellation.isCancelled,
            lifecycleIsCurrent: lifecycleIsCurrent
        ) else {
            return .failure(
                cancellation.isCancelled
                    ? "actionCancelled"
                    : "staleApplicationLifecycle"
            )
        }
        return nil
    }

    private func cancelledActionAttempt(
        cancellation: AXActionCancellation,
        window: AppWindow
    ) -> AXActionAttempt? {
        actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ).map {
            AXActionAttempt(
                result: $0,
                shouldRefreshStaleElement: false
            )
        }
    }

    private func performActionAttempt(
        _ action: AXWindowAction,
        on window: AppWindow,
        element: AXUIElement,
        cancellation: AXActionCancellation
    ) -> AXActionAttempt {
        if let failure = cancelledActionAttempt(
            cancellation: cancellation,
            window: window
        ) {
            return failure
        }
        switch action {
        case .focus:
            let restoreStatus: AXError
            if window.isMinimized {
                restoreStatus = AXUIElementSetAttributeValue(
                    element,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
            } else {
                restoreStatus = .success
            }
            let restored = restoreStatus == .success
            if isStaleElementError(restoreStatus) {
                return AXActionAttempt(
                    result: .failure("focusRestoreStaleElement"),
                    shouldRefreshStaleElement: true
                )
            }
            if let failure = cancelledActionAttempt(
                cancellation: cancellation,
                window: window
            ) {
                return failure
            }

            // Raise is also the liveness proof for the cached AX proxy. Never
            // target a DTO's WindowServer ID until its exact AX element has
            // successfully answered in this attempt.
            let raiseStatus = AXUIElementPerformAction(
                element,
                kAXRaiseAction as CFString
            )
            let raised = raiseStatus == .success
            if isStaleElementError(raiseStatus) {
                return AXActionAttempt(
                    result: .failure("focusRaiseStaleElement"),
                    shouldRefreshStaleElement: true
                )
            }
            if let failure = cancelledActionAttempt(
                cancellation: cancellation,
                window: window
            ) {
                return failure
            }

            if raised,
               let cgWindowID = window.cgWindowID,
               focusViaSLPS(
                   pid: window.processIdentifier,
                   cgWindowID: cgWindowID,
                   cancellation: cancellation,
                   window: window
               ) {
                return AXActionAttempt(
                    result: AXWindowActionResult(
                        succeeded: restored,
                        result: "focusedViaSLPS",
                        activationDirective: .unhideIfHidden,
                        positionError: nil,
                        sizeError: nil
                    ),
                    shouldRefreshStaleElement: false
                )
            }
            if let failure = cancelledActionAttempt(
                cancellation: cancellation,
                window: window
            ) {
                return failure
            }

            return AXActionAttempt(
                result: AXWindowActionResult(
                    succeeded: restored && raised,
                    result: raised ? "focusedViaAXFallback" : "axRaiseFailed",
                    activationDirective: .unhideAndActivate,
                    positionError: nil,
                    sizeError: nil
                ),
                shouldRefreshStaleElement: false
            )

        case .minimize:
            let status = AXUIElementSetAttributeValue(
                element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            )
            let succeeded = status == .success
            return AXActionAttempt(
                result: AXWindowActionResult(
                    succeeded: succeeded,
                    result: succeeded ? "minimized" : "minimizeFailed",
                    activationDirective: .none,
                    positionError: nil,
                    sizeError: nil
                ),
                shouldRefreshStaleElement: isStaleElementError(status)
            )

        case .close:
            let directStatus = AXUIElementPerformAction(
                element,
                "AXClose" as CFString
            )
            if directStatus == .success {
                return AXActionAttempt(
                    result: AXWindowActionResult(
                        succeeded: true,
                        result: "closedViaAction",
                        activationDirective: .none,
                        positionError: nil,
                        sizeError: nil
                    ),
                    shouldRefreshStaleElement: false
                )
            }
            if isStaleElementError(directStatus) {
                return AXActionAttempt(
                    result: .failure("closeStaleElement"),
                    shouldRefreshStaleElement: true
                )
            }
            if let failure = cancelledActionAttempt(
                cancellation: cancellation,
                window: window
            ) {
                return failure
            }
            guard AXCloseFallbackPolicy.shouldAttemptButton(
                directStatusRawValue: directStatus.rawValue
            ) else {
                return AXActionAttempt(
                    result: .failure(
                        "closeFailed:\(directStatus.rawValue)"
                    ),
                    shouldRefreshStaleElement: false
                )
            }
            let buttonAttempt = closeViaButton(
                element,
                cancellation: cancellation,
                window: window
            )
            return AXActionAttempt(
                result: AXWindowActionResult(
                    succeeded: buttonAttempt.succeeded,
                    result: buttonAttempt.succeeded
                        ? "closedViaButton"
                        : "closeFailed",
                    activationDirective: .none,
                    positionError: nil,
                    sizeError: nil
                ),
                shouldRefreshStaleElement:
                    buttonAttempt.shouldRefreshStaleElement
            )

        case .zoom:
            var value: CFTypeRef?
            let copyStatus = AXUIElementCopyAttributeValue(
                element,
                kAXZoomButtonAttribute as CFString,
                &value
            )
            guard copyStatus == .success,
                  let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return AXActionAttempt(
                    result: .failure("zoomButtonUnavailable"),
                    shouldRefreshStaleElement:
                        isStaleElementError(copyStatus)
                )
            }
            if let failure = cancelledActionAttempt(
                cancellation: cancellation,
                window: window
            ) {
                return failure
            }
            let pressStatus = AXUIElementPerformAction(
                value as! AXUIElement,
                kAXPressAction as CFString
            )
            let succeeded = pressStatus == .success
            return AXActionAttempt(
                result: AXWindowActionResult(
                    succeeded: succeeded,
                    result: succeeded ? "zoomed" : "zoomFailed",
                    activationDirective: .none,
                    positionError: nil,
                    sizeError: nil
                ),
                shouldRefreshStaleElement:
                    isStaleElementError(pressStatus)
            )

        case let .resize(frame):
            var origin = frame.origin
            var size = frame.size
            guard let positionValue = AXValueCreate(.cgPoint, &origin),
                  let sizeValue = AXValueCreate(.cgSize, &size) else {
                return AXActionAttempt(
                    result: .failure("couldNotCreateAXValues"),
                    shouldRefreshStaleElement: false
                )
            }
            let positionResult = AXUIElementSetAttributeValue(
                element,
                kAXPositionAttribute as CFString,
                positionValue
            )
            if let failure = cancelledActionAttempt(
                cancellation: cancellation,
                window: window
            ) {
                return failure
            }
            let sizeResult = AXUIElementSetAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                sizeValue
            )
            let succeeded =
                positionResult == .success && sizeResult == .success
            return AXActionAttempt(
                result: AXWindowActionResult(
                    succeeded: succeeded,
                    result: succeeded ? "resized" : "resizeFailed",
                    activationDirective: .none,
                    positionError: positionResult.rawValue,
                    sizeError: sizeResult.rawValue
                ),
                shouldRefreshStaleElement:
                    isStaleElementError(positionResult)
                        || isStaleElementError(sizeResult)
            )
        }
    }

    private func isStaleElementError(_ error: AXError) -> Bool {
        AXActionRetryPolicy.shouldRefreshAndRetry(
            statusRawValue: error.rawValue,
            alreadyRetried: false
        )
    }

    private func liveElement(
        for window: AppWindow,
        forceRefresh: Bool = false,
        recoveryBudget: inout AXActionRecoveryBudget
    ) -> AXUIElement? {
        guard applicationsByPID[window.processIdentifier]?.lifecycle
            == window.lifecycle else {
            liveElementFailureReason = "staleApplicationLifecycle"
            return nil
        }
        guard let record = recordsByID[window.id],
              record.lifecycle == window.lifecycle else {
            liveElementFailureReason = "liveElementRecordUnavailable"
            synchronizeProcess(pid: window.processIdentifier)
            return nil
        }
        if !forceRefresh {
            return record.element
        }

        // One application-window list request is the entire synchronous
        // recovery budget. Candidate attributes are never inspected here; a
        // non-exact replacement is resolved only by the cooperative snapshot.
        guard recoveryBudget.consumeSynchronousEnumeration() else {
            liveElementFailureReason = "actionRecoveryBudgetExhausted"
            synchronizeProcess(pid: window.processIdentifier)
            return nil
        }
        let candidates: [AXUIElement]
        switch windowElements(processIdentifier: window.processIdentifier) {
        case let .success(elements, isComplete):
            guard isComplete else {
                liveElementFailureReason =
                    "liveElementRefreshEnumerationIncomplete"
                synchronizeProcess(pid: window.processIdentifier)
                return nil
            }
            candidates = elements
        case let .failure(error):
            liveElementFailureReason =
                "liveElementRefreshFailed:\(error.rawValue)"
            synchronizeProcess(pid: window.processIdentifier)
            return nil
        }
        guard !candidates.isEmpty else {
            liveElementFailureReason = "liveElementProcessHasNoWindows"
            synchronizeProcess(pid: window.processIdentifier)
            return nil
        }

        let exactMatches = candidates.filter {
            CFEqual($0, record.element)
        }
        guard exactMatches.count == 1, let matchedElement = exactMatches.first
        else {
            liveElementFailureReason = "liveElementExactIdentityUnavailable"
            synchronizeProcess(pid: window.processIdentifier)
            return nil
        }
        recordsByID[window.id] = ElementRecord(
            id: window.id,
            element: matchedElement,
            processIdentifier: window.processIdentifier,
            lifecycle: window.lifecycle,
            cgWindowID: record.cgWindowID
        )
        synchronizeProcess(pid: window.processIdentifier)
        return matchedElement
    }

    private func rebindEvidence(
        for window: AppWindow
    ) -> AXWindowRebindEvidence {
        AXWindowRebindEvidence(
            cgWindowID: window.cgWindowID,
            windowNumber: window.windowNumber,
            title: window.windowTitle == window.appDisplayName
                ? nil
                : window.windowTitle,
            frame: window.frame
        )
    }

    private func focusViaSLPS(
        pid: pid_t,
        cgWindowID: CGWindowID,
        cancellation: AXActionCancellation,
        window: AppWindow
    ) -> Bool {
        guard actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) == nil else {
            return false
        }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return false }
        guard actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) == nil else {
            return false
        }
        let result = _SLPSSetFrontProcessWithOptions(
            &psn,
            cgWindowID,
            SLPSMode.userGenerated.rawValue
        )
        guard result == .success else { return false }
        guard actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) == nil else {
            return false
        }
        slpsMakeKeyWindow(psn: &psn, windowID: cgWindowID)
        return actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) == nil
    }

    private func closeViaButton(
        _ element: AXUIElement,
        cancellation: AXActionCancellation,
        window: AppWindow
    ) -> (succeeded: Bool, shouldRefreshStaleElement: Bool) {
        guard actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) == nil else {
            return (false, false)
        }
        var value: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(
            element,
            kAXCloseButtonAttribute as CFString,
            &value
        )
        guard copyStatus == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (false, isStaleElementError(copyStatus))
        }
        guard actionPreflightFailure(
            cancellation: cancellation,
            window: window
        ) == nil else {
            return (false, false)
        }
        let pressStatus = AXUIElementPerformAction(
            value as! AXUIElement,
            kAXPressAction as CFString
        )
        return (
            pressStatus == .success,
            isStaleElementError(pressStatus)
        )
    }

    // MARK: - App-specific filtering and AX decoding

    private func passesAppDiscriminator(
        application: AXApplicationDescriptor,
        title: String,
        frame: CGRect?,
        subrole: String?
    ) -> Bool {
        let trimmedTitle =
            title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = application.bundleIdentifier

        if bundleID == "com.valvesoftware.steam",
           trimmedTitle.isEmpty || trimmedTitle == application.displayName {
            return false
        }
        if bundleID == "org.mozilla.firefox"
            || bundleID.hasPrefix("org.mozilla."),
           let frame,
           frame.height < 300 {
            return false
        }
        if bundleID.hasPrefix("com.jetbrains."),
           let subrole,
           subrole == kAXFloatingWindowSubrole as String
            || subrole == kAXSystemFloatingWindowSubrole as String {
            return false
        }
        return true
    }

    private func stringAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success else {
            recordTransientDecodeFailure(status)
            return nil
        }
        guard let string = value as? String else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return string
    }

    private func boolAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success else {
            recordTransientDecodeFailure(status)
            return nil
        }
        guard let number = value as? NSNumber else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return number.boolValue
    }

    private func intAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> Int? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success else {
            recordTransientDecodeFailure(status)
            return nil
        }
        guard let number = value as? NSNumber else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return number.intValue
    }

    private func frameAttribute(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(
            kAXPositionAttribute as CFString,
            of: element
        ),
        let size = sizeAttribute(
            kAXSizeAttribute as CFString,
            of: element
        ) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func pointAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success else {
            recordTransientDecodeFailure(status)
            return nil
        }
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return point
    }

    private func sizeAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success else {
            recordTransientDecodeFailure(status)
            return nil
        }
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            decodeEncounteredTransientFailure = true
            return nil
        }
        return size
    }

    private func recordTransientDecodeFailure(_ error: AXError) {
        if error == .cannotComplete
            || error == .failure
            || error == .invalidUIElement
            || error == .apiDisabled {
            decodeEncounteredTransientFailure = true
        }
    }

    private func cgWindowID(
        of element: AXUIElement,
        processIdentifier: pid_t,
        title: String,
        frame: CGRect?
    ) -> CGWindowID? {
        var id: CGWindowID = 0
        let status = _AXUIElementGetWindow(element, &id)
        if status == .success, id != 0 {
            return id
        }
        let heuristicID = cgWindowIDByHeuristic(
            processIdentifier: processIdentifier,
            title: title,
            frame: frame
        )
        if heuristicID == nil {
            recordTransientDecodeFailure(status)
        }
        return heuristicID
    }

    private func cgWindowIDByHeuristic(
        processIdentifier: pid_t,
        title: String,
        frame: CGRect?
    ) -> CGWindowID? {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        let descriptions =
            CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
            ?? []
        let appEntries = descriptions.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier
        }
        guard !appEntries.isEmpty else { return nil }

        let trimmedTitle =
            title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty,
           let match = appEntries.first(where: {
               ($0[kCGWindowName as String] as? String) == trimmedTitle
           }),
           let id = match[kCGWindowNumber as String] as? CGWindowID {
            return id
        }

        if let frame {
            for entry in appEntries {
                guard let bounds = entry[kCGWindowBounds as String]
                    as? [String: Any] else {
                    continue
                }
                let cgFrame = CGRect(
                    x: (bounds["X"] as? CGFloat) ?? 0,
                    y: (bounds["Y"] as? CGFloat) ?? 0,
                    width: (bounds["Width"] as? CGFloat) ?? 0,
                    height: (bounds["Height"] as? CGFloat) ?? 0
                )
                if abs(cgFrame.origin.x - frame.origin.x) < 2,
                   abs(cgFrame.origin.y - frame.origin.y) < 2,
                   abs(cgFrame.size.width - frame.size.width) < 2,
                   abs(cgFrame.size.height - frame.size.height) < 2,
                   let id = entry[kCGWindowNumber as String] as? CGWindowID {
                    return id
                }
            }
        }

        if !trimmedTitle.isEmpty {
            let lowered = trimmedTitle.lowercased()
            for entry in appEntries {
                guard let cgTitle =
                    entry[kCGWindowName as String] as? String,
                    !cgTitle.isEmpty else {
                    continue
                }
                let loweredCG = cgTitle.lowercased()
                if loweredCG.contains(lowered)
                    || lowered.contains(loweredCG),
                   let id = entry[kCGWindowNumber as String] as? CGWindowID {
                    return id
                }
            }
        }
        return nil
    }

    private func emit(_ event: AXWindowWorkerEvent) {
        nextEventSequence &+= 1
        if nextEventSequence == 0 {
            nextEventSequence = 1
        }
        eventSink?(
            AXWindowWorkerEventEnvelope(
                sequence: nextEventSequence,
                event: event
            )
        )
    }
}

private nonisolated func axWindowWorkerObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notificationName: CFString,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let worker =
        Unmanaged<AXWindowWorker>.fromOpaque(context).takeUnretainedValue()
    worker.enqueueNotification(
        observer: observer,
        element: element,
        notificationName: notificationName
    )
}
