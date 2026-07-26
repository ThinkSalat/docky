//
//  WindowRegistry.swift
//  Docky
//
//  MainActor facade for the window registry. All cross-process Accessibility
//  work is delegated to AXWindowWorker's dedicated CFRunLoop thread; this
//  object owns only immutable Sendable snapshots and AppKit-facing state.
//

import AppKit
import Combine
import ScreenCaptureKit

private let minimumTrackedWindowSize = CGSize(width: 100, height: 100)

private let filteredBundleIdentifiers: Set<String> = [
    "com.apple.notificationcenterui",
    "com.apple.WindowManager",
    "com.apple.dock",
]

/// Stable process-local identity allocated by `AXWindowWorker`. It contains no
/// `AXUIElement`; the corresponding remote handle never leaves the worker.
nonisolated struct WindowID: Hashable, Sendable {
    let rawValue: UInt64
    let stableString: String
}

/// Immutable value snapshot of a remote application window.
nonisolated struct AppWindow: Identifiable, Hashable, Sendable {
    let id: WindowID
    let lifecycle: AXApplicationLifecycleStamp
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let appDisplayName: String
    let windowTitle: String
    let isMinimized: Bool
    let windowNumber: Int?
    let cgWindowID: CGWindowID?
    let frame: CGRect?

    var windowIdentifier: String { id.stableString }
    var screenBounds: CGRect? { frame }

    static func == (lhs: AppWindow, rhs: AppWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.lifecycle == rhs.lifecycle
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.processIdentifier == rhs.processIdentifier
            && lhs.appDisplayName == rhs.appDisplayName
            && lhs.windowTitle == rhs.windowTitle
            && lhs.isMinimized == rhs.isMinimized
            && lhs.windowNumber == rhs.windowNumber
            && lhs.cgWindowID == rhs.cgWindowID
            && lhs.frame == rhs.frame
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()

    @Published private(set) var windows: [AppWindow] = []
    let previewInvalidations = PassthroughSubject<String, Never>()

    private let axWorker = AXWindowWorker()
    private var workerSession: UInt64 = 0
    private var snapshotGenerations =
        AXRequestGenerationTracker<AXWindowSnapshotScope>()
    private var applicationLifecycles = AXApplicationLifecycleTracker()
    private var bundleIdentifierByPID: [pid_t: String] = [:]
    private var lastObservedSnapshotGenerationByPID:
        [AXApplicationLifecycleStamp: AXRequestGeneration] = [:]
    private var lastWorkerEventSequence: UInt64 = 0
    private var lastFocusedWindowIDByPID: [pid_t: WindowID] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var permissionsCancellable: AnyCancellable?
    private var observationsActive = false
    private var screenCaptureReconciliationTask: Task<Void, Never>?
    private var resizePostCheckGeneration: [WindowID: UUID] = [:]

    var minimized: [AppWindow] {
        windows.filter(\.isMinimized)
    }

    var visible: [AppWindow] {
        windows.filter { window in
            guard !window.isMinimized else { return false }
            return isCapturable(window)
        }
    }

    private init() {
        axWorker.setEventSink { [weak self] envelope in
            // The serial worker submits to the main queue in FIFO order. The
            // envelope sequence also prevents a late delivery from replacing
            // newer state if this transport changes later.
            DispatchQueue.main.async { [weak self] in
                self?.consume(envelope)
            }
        }

        permissionsCancellable = PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .granted {
                    startObservingIfNeeded()
                } else {
                    stopObserving()
                }
            }

        if PermissionsService.shared.accessibility == .granted {
            startObservingIfNeeded()
        }
    }

    deinit {
        screenCaptureReconciliationTask?.cancel()
    }

    // MARK: - Lookup

    func windows(forBundleIdentifier bundleIdentifier: String) -> [AppWindow] {
        windows.filter { $0.bundleIdentifier == bundleIdentifier }
    }

    func windowsByRecency(
        forBundleIdentifier bundleIdentifier: String
    ) -> [AppWindow] {
        windows(forBundleIdentifier: bundleIdentifier)
    }

    func switchable(includeMinimized: Bool) -> [AppWindow] {
        windows.filter { window in
            if window.isMinimized {
                return includeMinimized && window.cgWindowID != nil
            }
            return isCapturable(window)
        }
    }

    func isCapturable(_ window: AppWindow) -> Bool {
        guard window.cgWindowID != nil,
              let size = window.frame?.size else {
            return false
        }
        return size.width >= minimumTrackedWindowSize.width
            && size.height >= minimumTrackedWindowSize.height
    }

    /// Compatibility lookup for synchronous callers. It deliberately returns
    /// the current immutable snapshot and schedules a fresh worker read;
    /// unlike the old implementation it never performs AX IPC inline.
    func liveWindows(for pid: pid_t) -> [AppWindow] {
        requestProcessSnapshot(pid)
        return windows.filter { $0.processIdentifier == pid }
    }

    // MARK: - Async window operations

    @discardableResult
    func focus(_ window: AppWindow) async -> Bool {
        guard accessibilityIsGranted(
            alertActionTitle: "focus app windows"
        ),
        applicationLifecycles.isCurrent(window.lifecycle) else {
            return false
        }
        let outcome = await axWorker.perform(.focus, on: window)
        recordActionOutcome(
            action: "focus",
            window: window,
            outcome: outcome
        )
        guard !Task.isCancelled,
              applicationLifecycles.isCurrent(window.lifecycle) else {
            return false
        }
        applyActivationDirective(
            outcome.activationDirective,
            processIdentifier: window.processIdentifier
        )
        return outcome.succeeded
    }

    @discardableResult
    func minimize(_ window: AppWindow) async -> Bool {
        guard accessibilityIsGranted(
            alertActionTitle: "minimize app windows"
        ),
        applicationLifecycles.isCurrent(window.lifecycle) else {
            return false
        }
        let outcome = await axWorker.perform(.minimize, on: window)
        recordActionOutcome(
            action: "minimize",
            window: window,
            outcome: outcome
        )
        guard AXActionExecutionPolicy.shouldProceed(
            isCancelled: Task.isCancelled,
            lifecycleIsCurrent:
                applicationLifecycles.isCurrent(window.lifecycle)
        ) else {
            return false
        }
        return outcome.succeeded
    }

    @discardableResult
    func close(_ window: AppWindow) async -> Bool {
        guard accessibilityIsGranted(
            alertActionTitle: "close app windows"
        ),
        applicationLifecycles.isCurrent(window.lifecycle) else {
            return false
        }
        let outcome = await axWorker.perform(.close, on: window)
        recordActionOutcome(
            action: "close",
            window: window,
            outcome: outcome
        )
        guard AXActionExecutionPolicy.shouldProceed(
            isCancelled: Task.isCancelled,
            lifecycleIsCurrent:
                applicationLifecycles.isCurrent(window.lifecycle)
        ) else {
            return false
        }
        return outcome.succeeded
    }

    @discardableResult
    func zoom(_ window: AppWindow) async -> Bool {
        guard accessibilityIsGranted(
            alertActionTitle: "zoom app windows"
        ),
        applicationLifecycles.isCurrent(window.lifecycle) else {
            return false
        }
        let outcome = await axWorker.perform(.zoom, on: window)
        recordActionOutcome(
            action: "zoom",
            window: window,
            outcome: outcome
        )
        guard AXActionExecutionPolicy.shouldProceed(
            isCancelled: Task.isCancelled,
            lifecycleIsCurrent:
                applicationLifecycles.isCurrent(window.lifecycle)
        ) else {
            return false
        }
        return outcome.succeeded
    }

    @discardableResult
    func resize(_ window: AppWindow, to frame: CGRect) async -> Bool {
        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(.windows, "axResizeRequested", fields: [
            "windowToken": diagnostics.token(window.windowIdentifier),
            "appToken": diagnostics.token(window.bundleIdentifier),
            "targetFrame": NSStringFromRect(frame),
            "accessibility": String(
                describing: PermissionsService.shared.accessibility
            ),
        ])

        guard PermissionsService.shared.accessibility == .granted,
              applicationLifecycles.isCurrent(window.lifecycle) else {
            diagnostics.record(.windows, "axResizeResult", fields: [
                "windowToken": diagnostics.token(window.windowIdentifier),
                "result": "accessibilityNotGranted",
                "succeeded": false,
            ])
            return false
        }

        let outcome = await axWorker.perform(.resize(frame), on: window)
        var fields: [String: Any] = [
            "windowToken": diagnostics.token(window.windowIdentifier),
            "result": outcome.result,
            "succeeded": outcome.succeeded,
        ]
        if let positionError = outcome.positionError {
            fields["positionAXError"] = positionError
        }
        if let sizeError = outcome.sizeError {
            fields["sizeAXError"] = sizeError
        }
        diagnostics.record(.windows, "axResizeResult", fields: fields)
        guard AXActionExecutionPolicy.shouldProceed(
            isCancelled: Task.isCancelled,
            lifecycleIsCurrent:
                applicationLifecycles.isCurrent(window.lifecycle)
        ) else {
            return false
        }
        scheduleResizePostCheck(
            window: window,
            targetFrame: frame,
            setterSucceeded: outcome.succeeded
        )
        return outcome.succeeded
    }

    private func scheduleResizePostCheck(
        window: AppWindow,
        targetFrame: CGRect,
        setterSucceeded: Bool
    ) {
        let generation = UUID()
        resizePostCheckGeneration[window.id] = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  resizePostCheckGeneration[window.id] == generation else {
                return
            }
            let observedFrame = await axWorker.frame(for: window)
            guard resizePostCheckGeneration[window.id] == generation else {
                return
            }
            resizePostCheckGeneration.removeValue(forKey: window.id)

            let matchesTarget = observedFrame.map {
                abs($0.origin.x - targetFrame.origin.x) <= 2
                    && abs($0.origin.y - targetFrame.origin.y) <= 2
                    && abs($0.size.width - targetFrame.size.width) <= 2
                    && abs($0.size.height - targetFrame.size.height) <= 2
            } ?? false
            let diagnostics = DiagnosticsTrace.shared
            diagnostics.record(.windows, "axResizePostCheck", fields: [
                "windowToken": diagnostics.token(window.windowIdentifier),
                "targetFrame": NSStringFromRect(targetFrame),
                "observedFrame": observedFrame.map(NSStringFromRect)
                    ?? "unavailable",
                "matchesTarget": matchesTarget,
                "setterSucceeded": setterSucceeded,
            ])
        }
    }

    private func accessibilityIsGranted(
        alertActionTitle: String
    ) -> Bool {
        guard PermissionsService.shared.accessibility == .granted else {
            PermissionsService.shared.presentPermissionAlert(
                for: .accessibility,
                actionTitle: alertActionTitle
            )
            return false
        }
        return true
    }

    private func recordActionOutcome(
        action: String,
        window: AppWindow,
        outcome: AXWindowActionResult
    ) {
        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(.windows, "axWindowActionResult", fields: [
            "action": action,
            "windowToken": diagnostics.token(window.windowIdentifier),
            "appToken": diagnostics.token(window.bundleIdentifier),
            "result": outcome.result,
            "succeeded": outcome.succeeded,
        ])
    }

    private func applyActivationDirective(
        _ directive: AXApplicationActivationDirective,
        processIdentifier: pid_t
    ) {
        guard directive != .none,
              let application = NSRunningApplication(
                  processIdentifier: processIdentifier
              ) else {
            return
        }
        switch directive {
        case .none:
            break
        case .unhideIfHidden:
            if application.isHidden {
                application.unhide()
            }
        case .unhideAndActivate:
            application.unhide()
            _ = application.activate()
        }
    }

    // MARK: - Observation lifecycle

    private func startObservingIfNeeded() {
        guard !observationsActive else { return }
        observationsActive = true
        applicationLifecycles = AXApplicationLifecycleTracker()
        bundleIdentifierByPID.removeAll()
        workerSession &+= 1
        if workerSession == 0 {
            workerSession = 1
        }

        subscribeToWorkspaceLifecycle()
        let applications = currentRegularApplicationDescriptors()
        let generation = snapshotGenerations.issue(for: .all)
        axWorker.startObserving(
            session: workerSession,
            applications: applications,
            generation: generation
        )
    }

    private func stopObserving() {
        guard observationsActive else { return }
        observationsActive = false
        workerSession &+= 1
        if workerSession == 0 {
            workerSession = 1
        }
        snapshotGenerations.invalidateAll()
        screenCaptureReconciliationTask?.cancel()
        screenCaptureReconciliationTask = nil

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        axWorker.stopObserving(session: workerSession)
        applicationLifecycles = AXApplicationLifecycleTracker()
        bundleIdentifierByPID.removeAll()
        lastFocusedWindowIDByPID.removeAll()
        lastObservedSnapshotGenerationByPID.removeAll()
        resizePostCheckGeneration.removeAll()
        if !windows.isEmpty {
            windows = []
        }
    }

    private func subscribeToWorkspaceLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleAppLaunched(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleAppTerminated(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didHideApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let application = Self.application(
                        from: notification
                    ) else {
                        return
                    }
                    self?.handleAppHidden(application)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didUnhideApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let application = Self.application(
                        from: notification
                    ) else {
                        return
                    }
                    self?.handleAppUnhidden(application)
                }
            },
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.requestFullSnapshot()
                }
            },
        ]
    }

    private static func processIdentifier(
        from notification: Notification
    ) -> pid_t? {
        application(from: notification)?.processIdentifier
    }

    private static func application(
        from notification: Notification
    ) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
    }

    private func handleAppLaunched(_ notification: Notification) {
        guard let application =
            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            shouldTrack(application) else {
            return
        }
        beginLifecycle(for: application)
        snapshotGenerations.invalidate(.all)
        snapshotGenerations.invalidate(
            .process(application.processIdentifier)
        )
        requestFullSnapshot()
        DispatchQueue.main.async { [weak self] in
            self?.requestProcessSnapshot(application.processIdentifier)
        }
    }

    private func handleAppTerminated(_ notification: Notification) {
        guard let pid = Self.processIdentifier(from: notification) else {
            return
        }
        applicationLifecycles.endLifecycle(for: pid)
        bundleIdentifierByPID.removeValue(forKey: pid)
        snapshotGenerations.invalidate(.all)
        snapshotGenerations.invalidate(.process(pid))
        axWorker.removeApplication(
            session: workerSession,
            processIdentifier: pid
        )
        removeWindows(for: pid)
        requestFullSnapshot()
    }

    private func handleAppHidden(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        applicationLifecycles.endLifecycle(for: pid)
        bundleIdentifierByPID.removeValue(forKey: pid)
        snapshotGenerations.invalidate(.all)
        snapshotGenerations.invalidate(.process(pid))
        axWorker.removeApplication(
            session: workerSession,
            processIdentifier: pid
        )
        removeWindows(for: pid)
        requestFullSnapshot()
    }

    private func handleAppUnhidden(_ application: NSRunningApplication) {
        guard shouldTrack(application) else { return }
        beginLifecycle(for: application)
        snapshotGenerations.invalidate(.all)
        snapshotGenerations.invalidate(
            .process(application.processIdentifier)
        )
        requestFullSnapshot()
        requestProcessSnapshot(application.processIdentifier)
    }

    private func requestFullSnapshot() {
        guard observationsActive else { return }
        let generation = snapshotGenerations.issue(for: .all)
        axWorker.requestSnapshot(
            session: workerSession,
            scope: .all,
            applications: currentRegularApplicationDescriptors(),
            generation: generation
        )
    }

    private func requestProcessSnapshot(_ pid: pid_t) {
        guard observationsActive, pid > 0 else { return }
        guard let application = NSRunningApplication(
            processIdentifier: pid
        ),
        shouldTrack(application) else {
            applicationLifecycles.endLifecycle(for: pid)
            bundleIdentifierByPID.removeValue(forKey: pid)
            snapshotGenerations.invalidate(.all)
            snapshotGenerations.invalidate(.process(pid))
            axWorker.removeApplication(
                session: workerSession,
                processIdentifier: pid
            )
            removeWindows(for: pid)
            requestFullSnapshot()
            return
        }

        let generation = snapshotGenerations.issue(for: .process(pid))
        axWorker.requestSnapshot(
            session: workerSession,
            scope: .process(pid),
            applications: [descriptor(for: application)],
            generation: generation
        )
    }

    private func currentRegularApplicationDescriptors()
        -> [AXApplicationDescriptor] {
        NSWorkspace.shared.runningApplications
            .filter(shouldTrack)
            .map(descriptor)
    }

    private func descriptor(
        for application: NSRunningApplication
    ) -> AXApplicationDescriptor {
        let pid = application.processIdentifier
        let bundleIdentifier =
            application.bundleIdentifier ?? "pid:\(pid)"
        let lifecycle: AXApplicationLifecycleStamp
        if bundleIdentifierByPID[pid] != bundleIdentifier {
            lifecycle = beginLifecycle(for: application)
        } else {
            lifecycle = applicationLifecycles.currentOrBeginLifecycle(
                for: pid
            )
        }
        return AXApplicationDescriptor(
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier,
            lifecycle: lifecycle
        )
    }

    @discardableResult
    private func beginLifecycle(
        for application: NSRunningApplication
    ) -> AXApplicationLifecycleStamp {
        let pid = application.processIdentifier
        bundleIdentifierByPID[pid] =
            application.bundleIdentifier ?? "pid:\(pid)"
        lastObservedSnapshotGenerationByPID = lastObservedSnapshotGenerationByPID
            .filter { $0.key.processIdentifier != pid }
        return applicationLifecycles.beginLifecycle(for: pid)
    }

    private func shouldTrack(_ application: NSRunningApplication) -> Bool {
        guard application.activationPolicy == .regular,
              !application.isHidden else {
            return false
        }
        if let bundleIdentifier = application.bundleIdentifier {
            if filteredBundleIdentifiers.contains(bundleIdentifier) {
                return false
            }
            if bundleIdentifier == Bundle.main.bundleIdentifier {
                return false
            }
        }
        return application.processIdentifier > 0
    }

    // MARK: - Worker event reduction

    private func consume(_ envelope: AXWindowWorkerEventEnvelope) {
        guard envelope.sequence > lastWorkerEventSequence else { return }
        lastWorkerEventSequence = envelope.sequence

        switch envelope.event {
        case let .requestedSnapshot(
            session,
            scope,
            generation,
            batches
        ):
            guard observationsActive,
                  session == workerSession,
                  snapshotGenerations.isCurrent(
                      generation,
                      for: scope
                  ) else {
                return
            }
            guard batches.allSatisfy({
                applicationLifecycles.isCurrent($0.lifecycle)
            }) else {
                return
            }
            switch scope {
            case .all:
                applyOrdered(batches.flatMap(\.value))
                scheduleScreenCaptureReconciliation()
            case let .process(pid):
                guard let batch = batches.first(where: {
                    $0.lifecycle.processIdentifier == pid
                }) else {
                    return
                }
                replaceWindows(forPID: pid, with: batch.value)
            }

        case let .processSnapshot(
            session,
            generation,
            lifecycle,
            snapshot,
            invalidatedPreviewIdentifier
        ):
            let pid = lifecycle.processIdentifier
            guard observationsActive,
                  session == workerSession,
                  applicationLifecycles.isCurrent(lifecycle) else {
                return
            }
            if let previous =
                lastObservedSnapshotGenerationByPID[lifecycle],
               generation <= previous {
                return
            }
            lastObservedSnapshotGenerationByPID[lifecycle] = generation
            if let invalidatedPreviewIdentifier {
                previewInvalidations.send(invalidatedPreviewIdentifier)
            }
            replaceWindows(forPID: pid, with: snapshot)

        case let .focusedWindowChanged(session, lifecycle, windowID):
            let pid = lifecycle.processIdentifier
            guard observationsActive,
                  session == workerSession,
                  applicationLifecycles.isCurrent(lifecycle) else {
                return
            }
            invalidateOutgoingFocusedPreview(
                pid: pid,
                newFocusedID: windowID
            )
            lastFocusedWindowIDByPID[pid] = windowID
            bumpWindowToTop(windowID: windowID, pid: pid)

        case let .processHidden(session, lifecycle):
            let pid = lifecycle.processIdentifier
            guard session == workerSession,
                  applicationLifecycles.isCurrent(lifecycle) else {
                return
            }
            removeWindows(for: pid)

        case let .windowDestroyed(session, lifecycle, windowID):
            let pid = lifecycle.processIdentifier
            guard session == workerSession,
                  applicationLifecycles.isCurrent(lifecycle) else {
                return
            }
            if let windowID,
               let index = windows.firstIndex(where: {
                   $0.id == windowID
               }) {
                windows.remove(at: index)
            } else {
                requestProcessSnapshot(pid)
            }
        }
    }

    private func bumpWindowToTop(windowID: WindowID, pid: pid_t) {
        guard let index = windows.firstIndex(where: {
            $0.id == windowID
        }) else {
            requestProcessSnapshot(pid)
            return
        }
        guard index != 0 else { return }
        let window = windows.remove(at: index)
        windows.insert(window, at: 0)
    }

    private func replaceWindows(
        forPID pid: pid_t,
        with updatedWindows: [AppWindow]
    ) {
        var next = windows
        let insertIndex =
            next.firstIndex(where: { $0.processIdentifier == pid })
            ?? next.count
        next.removeAll { $0.processIdentifier == pid }
        next.insert(
            contentsOf: updatedWindows,
            at: min(insertIndex, next.count)
        )
        applyOrdered(next)
        scheduleScreenCaptureReconciliation()
    }

    private func removeWindows(for pid: pid_t) {
        lastFocusedWindowIDByPID.removeValue(forKey: pid)
        guard windows.contains(where: {
            $0.processIdentifier == pid
        }) else {
            return
        }
        windows.removeAll { $0.processIdentifier == pid }
    }

    private func invalidateOutgoingFocusedPreview(
        pid: pid_t,
        newFocusedID: WindowID
    ) {
        guard let previousID = lastFocusedWindowIDByPID[pid],
              previousID != newFocusedID,
              let outgoing = windows.first(where: {
                  $0.id == previousID
              }) else {
            return
        }
        previewInvalidations.send(outgoing.windowIdentifier)
    }

    private func applyOrdered(_ snapshot: [AppWindow]) {
        let snapshot = AXSnapshotValueReducer.deduplicated(snapshot)
        var remaining = Set(snapshot.map(\.id))
        var orderedExisting: [AppWindow] = []
        for window in windows where remaining.contains(window.id) {
            if let updated = snapshot.first(where: {
                $0.id == window.id
            }) {
                orderedExisting.append(updated)
            } else {
                orderedExisting.append(window)
            }
            remaining.remove(window.id)
        }
        let newcomers = snapshot.filter { remaining.contains($0.id) }
        let next = orderedExisting + newcomers
        if next != windows {
            windows = next
        }
    }

    // MARK: - ScreenCaptureKit reconciliation

    private func scheduleScreenCaptureReconciliation() {
        guard PermissionsService.shared.screenCapture == .granted else {
            return
        }
        screenCaptureReconciliationTask?.cancel()
        screenCaptureReconciliationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            await reconcileWithScreenCapture()
        }
    }

    private func reconcileWithScreenCapture() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        var scWindowsByPID: [pid_t: Int] = [:]
        for window in content.windows {
            guard let application = window.owningApplication else {
                continue
            }
            scWindowsByPID[pid_t(application.processID), default: 0] += 1
        }

        var registryOnScreenByPID: [pid_t: Int] = [:]
        for window in windows where !window.isMinimized {
            registryOnScreenByPID[
                window.processIdentifier,
                default: 0
            ] += 1
        }

        for (pid, scCount) in scWindowsByPID {
            guard scCount > registryOnScreenByPID[pid, default: 0] else {
                continue
            }
            requestProcessSnapshot(pid)
        }
    }
}
