//
//  DockBadgeService.swift
//  Docky
//
//  Mirrors two pieces of transient state owned by the system Dock:
//    - notification badges for application tiles
//    - the current Continuity/Handoff application suggestion
//
//  macOS does not expose either state through a public cross-application API.
//  The Dock does expose both in its Accessibility tree, though: application
//  items carry AXStatusLabel/AXURL and the Continuity item uses the private
//  AXHandoffDockItem subrole. All remote AX calls stay on one serialized
//  worker so an unresponsive Dock cannot block Docky's main actor.
//

import AppKit
import ApplicationServices
import Combine
import CoreFoundation

/// `useractivityd` posts this Darwin notification whenever its selected best
/// Handoff application changes. It intentionally carries no payload; the
/// callback only asks our AX worker to rescan the system Dock.
nonisolated private func handoffSuggestionChangedCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            DockBadgeService.shared
                .handleHandoffSuggestionChangedSignal()
        }
    }
}

nonisolated private struct AXSystemDockSnapshot: Equatable, Sendable {
    let badgesByBundleID: [String: String]
    let handoffSuggestion: DockHandoffSuggestion?
    let foundHandoffItem: Bool
    let handoffScanErrorCode: Int?

    static let empty = AXSystemDockSnapshot(
        badgesByBundleID: [:],
        handoffSuggestion: nil,
        foundHandoffItem: false,
        handoffScanErrorCode: nil
    )
}

nonisolated private enum AXHandoffContinuationResult: Equatable, Sendable {
    case succeeded
    case unavailable
    case suggestionChanged
    case failed(errorCode: Int)
}

/// Dedicated serialized owner for the Dock's remote Accessibility tree.
/// Only Sendable value snapshots leave this queue; AXUIElement instances do
/// not escape it.
nonisolated private final class AXSystemDockWorker: @unchecked Sendable {
    typealias SnapshotCompletion =
        @Sendable (AXSystemDockSnapshot) -> Void
    typealias ContinuationCompletion =
        @Sendable (AXHandoffContinuationResult) -> Void

    private struct Request {
        let dockProcessIdentifier: pid_t
        let completion: SnapshotCompletion
    }

    private struct ElementSearchResult {
        let element: AXUIElement?
        let errorCode: Int?
    }

    private static let handoffSubrole = "AXHandoffDockItem"
    private static let maximumTraversalElementCount = 256

    private let queue = DispatchQueue(
        label: "gt.quintero.Docky.AXSystemDockWorker",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var isRefreshing = false
    private var pendingRequest: Request?

    // Worker-queue-only state.
    private var bundleIDByPath: [String: String] = [:]
    private var bundleIDByApplicationTitle: [String: String] = [:]
    private var configuredMessagingTimeout = false

    func requestRefresh(
        dockProcessIdentifier: pid_t,
        completion: @escaping SnapshotCompletion
    ) {
        let request = Request(
            dockProcessIdentifier: dockProcessIdentifier,
            completion: completion
        )

        stateLock.lock()
        pendingRequest = request
        let shouldSchedule = !isRefreshing
        if shouldSchedule {
            isRefreshing = true
        }
        stateLock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in
                self?.drainNextRefresh()
            }
        }
    }

    func requestContinueHandoff(
        dockProcessIdentifier: pid_t,
        expectedBundleIdentifier: String,
        completion: @escaping ContinuationCompletion
    ) {
        queue.async { [weak self] in
            let result = autoreleasepool {
                self?.continueHandoff(
                    dockProcessIdentifier: dockProcessIdentifier,
                    expectedBundleIdentifier:
                        expectedBundleIdentifier
                ) ?? .unavailable
            }
            completion(result)
        }
    }

    private func drainNextRefresh() {
        stateLock.lock()
        let request = pendingRequest
        pendingRequest = nil
        stateLock.unlock()

        guard let request else {
            finishRefresh()
            return
        }

        let snapshot = autoreleasepool {
            readSnapshot(
                dockProcessIdentifier: request.dockProcessIdentifier
            )
        }
        request.completion(snapshot)

        stateLock.lock()
        let hasPendingRequest = pendingRequest != nil
        if !hasPendingRequest {
            isRefreshing = false
        }
        stateLock.unlock()

        if hasPendingRequest {
            // A slow Dock reply coalesces every timer tick into one fresh read.
            queue.async { [weak self] in
                self?.drainNextRefresh()
            }
        }
    }

    private func finishRefresh() {
        stateLock.lock()
        isRefreshing = false
        stateLock.unlock()
    }

    private func readSnapshot(
        dockProcessIdentifier: pid_t
    ) -> AXSystemDockSnapshot {
        guard dockProcessIdentifier > 0 else {
            return .empty
        }
        configureMessagingTimeoutIfNeeded()

        let dock = AXUIElementCreateApplication(
            dockProcessIdentifier
        )
        _ = AXUIElementSetMessagingTimeout(dock, 1.0)

        var badges: [String: String] = [:]
        for item in dockItems(in: dock) {
            guard let badge = trimmedBadge(from: item),
                  let bundleID = bundleIdentifier(forDockItem: item) else {
                continue
            }
            badges[bundleID] = badge
        }

        let handoffSearch = firstDescendant(
            in: dock,
            attribute: kAXSubroleAttribute as CFString,
            equalTo: Self.handoffSubrole
        )
        let handoffItem = handoffSearch.element
        return AXSystemDockSnapshot(
            badgesByBundleID: badges,
            handoffSuggestion: handoffItem.flatMap(
                handoffSuggestion(for:)
            ),
            foundHandoffItem: handoffItem != nil,
            handoffScanErrorCode: handoffSearch.errorCode
        )
    }

    private func continueHandoff(
        dockProcessIdentifier: pid_t,
        expectedBundleIdentifier: String
    ) -> AXHandoffContinuationResult {
        guard dockProcessIdentifier > 0 else {
            return .unavailable
        }
        configureMessagingTimeoutIfNeeded()

        let dock = AXUIElementCreateApplication(
            dockProcessIdentifier
        )
        _ = AXUIElementSetMessagingTimeout(dock, 1.0)
        let handoffSearch = firstDescendant(
            in: dock,
            attribute: kAXSubroleAttribute as CFString,
            equalTo: Self.handoffSubrole
        )
        guard let handoffItem = handoffSearch.element else {
            return .unavailable
        }
        guard bundleIdentifier(forHandoffItem: handoffItem)
                == expectedBundleIdentifier else {
            return .suggestionChanged
        }

        let error = AXUIElementPerformAction(
            handoffItem,
            kAXPressAction as CFString
        )
        guard error == .success else {
            return .failed(errorCode: Int(error.rawValue))
        }
        return .succeeded
    }

    private func configureMessagingTimeoutIfNeeded() {
        guard !configuredMessagingTimeout else {
            return
        }
        _ = AXUIElementSetMessagingTimeout(
            AXUIElementCreateSystemWide(),
            1.0
        )
        configuredMessagingTimeout = true
    }

    private func dockItems(in dock: AXUIElement) -> [AXUIElement] {
        let dockListSearch = firstDescendant(
            in: dock,
            attribute: kAXRoleAttribute as CFString,
            equalTo: kAXListRole as String
        )
        guard let dockList = dockListSearch.element else {
            return []
        }
        return children(of: dockList)
    }

    /// Searches the full bounded Dock tree instead of assuming the Handoff
    /// item is always a direct child of the first AXList. The Dock has moved
    /// transient Continuity UI between containers across macOS releases.
    private func firstDescendant(
        in root: AXUIElement,
        attribute: CFString,
        equalTo expectedValue: String
    ) -> ElementSearchResult {
        let rootChildren = childrenWithError(of: root)
        var firstErrorCode = rootChildren.errorCode
        var pending = rootChildren.children
        var index = 0

        while index < pending.count,
              index < Self.maximumTraversalElementCount {
            let element = pending[index]
            index += 1
            let attributeResult = stringAttributeWithError(
                element,
                attribute
            )
            if attributeResult.value == expectedValue {
                return ElementSearchResult(
                    element: element,
                    errorCode: nil
                )
            }
            if firstErrorCode == nil {
                firstErrorCode = attributeResult.errorCode
            }

            let remainingCapacity =
                Self.maximumTraversalElementCount - pending.count
            if remainingCapacity > 0 {
                let childResult = childrenWithError(of: element)
                if firstErrorCode == nil {
                    firstErrorCode = childResult.errorCode
                }
                pending.append(
                    contentsOf: childResult.children
                        .prefix(remainingCapacity)
                )
            }
        }
        return ElementSearchResult(
            element: nil,
            errorCode: firstErrorCode
        )
    }

    private func handoffSuggestion(
        for item: AXUIElement
    ) -> DockHandoffSuggestion? {
        guard let bundleIdentifier =
                bundleIdentifier(forHandoffItem: item) else {
            return nil
        }

        let displayName =
            nonemptyStringAttribute(
                item,
                kAXTitleAttribute as CFString
            )
            ?? applicationDisplayName(
                forBundleIdentifier: bundleIdentifier
            )
            ?? String(localized: "Handoff")
        return DockHandoffSuggestion(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
    }

    private func bundleIdentifier(
        forDockItem item: AXUIElement
    ) -> String? {
        guard let url = urlAttribute(
            item,
            kAXURLAttribute as CFString
        ) else {
            return nil
        }
        let path = url.path
        if let cached = bundleIDByPath[path] {
            return cached.isEmpty ? nil : cached
        }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        bundleIDByPath[path] = bundleID ?? ""
        return bundleID
    }

    private func bundleIdentifier(
        forHandoffItem item: AXUIElement
    ) -> String? {
        if let url = urlAttribute(
            item,
            kAXURLAttribute as CFString
        ) {
            if let bundleIdentifier =
                    Bundle(url: url)?.bundleIdentifier {
                return bundleIdentifier
            }
            if let applicationURL =
                    NSWorkspace.shared.urlForApplication(toOpen: url),
               let bundleIdentifier =
                    Bundle(url: applicationURL)?.bundleIdentifier {
                return bundleIdentifier
            }
        }

        // Continuity tiles commonly omit AXURL even though ordinary Dock
        // application items expose it. Resolve AXTitle first against running
        // applications, then Launch Services' application-name lookup so
        // suggestions for applications that are not running still work.
        guard let title = nonemptyStringAttribute(
            item,
            kAXTitleAttribute as CFString
        ) else {
            return nil
        }
        let normalizedTitle = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let cached = bundleIDByApplicationTitle[
            normalizedTitle
        ] {
            return cached
        }
        if let runningBundleIdentifier =
                NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName?.localizedCaseInsensitiveCompare(
                        title
                    ) == .orderedSame
                })?.bundleIdentifier {
            bundleIDByApplicationTitle[normalizedTitle] =
                runningBundleIdentifier
            return runningBundleIdentifier
        }
        if let applicationPath =
                NSWorkspace.shared.fullPath(forApplication: title),
           let bundleIdentifier =
                Bundle(path: applicationPath)?.bundleIdentifier {
            bundleIDByApplicationTitle[normalizedTitle] =
                bundleIdentifier
            return bundleIdentifier
        }
        return nil
    }

    private func applicationDisplayName(
        forBundleIdentifier bundleIdentifier: String
    ) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return nil
        }
        let displayName = FileManager.default.displayName(
            atPath: url.path
        )
        return displayName.isEmpty ? nil : displayName
    }

    private func trimmedBadge(from item: AXUIElement) -> String? {
        guard let label = stringAttribute(
            item,
            "AXStatusLabel" as CFString
        ) else {
            return nil
        }
        let trimmed = label.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private func children(
        of element: AXUIElement
    ) -> [AXUIElement] {
        childrenWithError(of: element).children
    }

    private func childrenWithError(
        of element: AXUIElement
    ) -> (children: [AXUIElement], errorCode: Int?) {
        let result = copyAttributeWithError(
            element,
            kAXChildrenAttribute as CFString
        )
        return (
            result.value as? [AXUIElement] ?? [],
            inconclusiveErrorCode(result.error)
        )
    }

    private func stringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private func stringAttributeWithError(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> (value: String?, errorCode: Int?) {
        let result = copyAttributeWithError(element, attribute)
        return (
            result.value as? String,
            inconclusiveErrorCode(result.error)
        )
    }

    private func nonemptyStringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        guard let value = stringAttribute(element, attribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func urlAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> URL? {
        let value = copyAttribute(element, attribute)
        if let url = value as? URL {
            return url
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
    }

    private func copyAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> Any? {
        let result = copyAttributeWithError(element, attribute)
        return result.error == .success ? result.value : nil
    }

    private func copyAttributeWithError(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> (value: Any?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        return (value, error)
    }

    private func inconclusiveErrorCode(
        _ error: AXError
    ) -> Int? {
        switch error {
        case .success,
             .noValue,
             .attributeUnsupported,
             .parameterizedAttributeUnsupported:
            return nil
        default:
            return Int(error.rawValue)
        }
    }
}

@MainActor
final class DockBadgeService: ObservableObject {
    static let shared = DockBadgeService()
    static let handoffTileID = "handoff:system-dock"
    private static let handoffChangedNotification =
        CFNotificationName(
            "com.apple.coreservices.useractivity.bestappsuggestionchanged"
                as CFString
        )

    /// Badge text per bundle identifier, e.g. ["com.apple.mail": "5"].
    /// Apps with no badge are absent from the map.
    @Published private(set) var badgesByBundleID: [String: String] = [:]

    /// The system Dock's current incoming Continuity application. The
    /// activity payload remains owned by macOS; clicking Docky's tile asks
    /// the system Dock to perform its own AXPress action.
    @Published private(set) var handoffSuggestion:
        DockHandoffSuggestion?

    /// Handoff is transient, so scan more frequently than badges alone
    /// require. Reads are serialized and coalesced on the worker.
    private let pollInterval: TimeInterval = 1
    private var timer: Timer?
    private var handoffRefreshBurstTask: Task<Void, Never>?
    private var observesHandoffChangeNotification = false
    private let axWorker = AXSystemDockWorker()
    private var sessionGeneration: UInt64 = 0
    private var isRunning = false
    private var handoffState = HandoffSuggestionState()
    private var lastHandoffDiagnosticKey: String?
    private var lastAccessibilityTrust: Bool?

    private init() {}

    func badge(
        forBundleIdentifier bundleIdentifier: String
    ) -> String? {
        badgesByBundleID[bundleIdentifier]
    }

    func start() {
        guard timer == nil else {
            return
        }
        isRunning = true
        sessionGeneration &+= 1
        startObservingHandoffChanges()
        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        DiagnosticsTrace.shared.record(
            .systemDock,
            "handoffMirrorStarted",
            fields: [
                "accessibilityTrusted":
                    AXIsProcessTrusted(),
                "buildConfiguration":
                    buildConfiguration,
                "isInApplicationsDirectory":
                    Bundle.main.bundleURL.path
                        .hasPrefix("/Applications/"),
                "observesBestSuggestionChanges":
                    observesHandoffChangeNotification,
            ]
        )
        refresh()
        let timer = Timer(
            timeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        handoffRefreshBurstTask?.cancel()
        handoffRefreshBurstTask = nil
        stopObservingHandoffChanges()
        sessionGeneration &+= 1
    }

    /// A useractivityd signal can precede the Dock's AX insertion by a few
    /// milliseconds, and some suggestions disappear in under one fallback
    /// poll. Scan now, then at cumulative 100/250/500 ms offsets to cover the
    /// insertion and Accessibility-publication race.
    fileprivate func handleHandoffSuggestionChangedSignal() {
        guard isRunning else {
            return
        }
        DiagnosticsTrace.shared.record(
            .systemDock,
            "handoffSuggestionChangedSignal"
        )
        refresh()

        handoffRefreshBurstTask?.cancel()
        handoffRefreshBurstTask = Task { @MainActor [weak self] in
            for delay in [
                Duration.milliseconds(100),
                .milliseconds(150),
                .milliseconds(250),
            ] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self,
                      isRunning else {
                    return
                }
                refresh()
            }
        }
    }

    /// Reacquires the system Dock's live Handoff item and forwards AXPress.
    /// We intentionally do not try to open the target application ourselves:
    /// only macOS owns the NSUserActivity payload that must be continued.
    func continueHandoff() {
        guard let expectedSuggestion = handoffSuggestion else {
            return
        }
        guard AXIsProcessTrusted() else {
            recordHandoffState("permissionUnavailable")
            _ = PermissionsService.shared
                .requestAccessibilityPermission(prompt: true)
            refresh()
            return
        }
        guard let dockProcessIdentifier =
                dockProcessIdentifier() else {
            clearHandoffSuggestion(
                diagnosticState: "dockUnavailable"
            )
            return
        }

        axWorker.requestContinueHandoff(
            dockProcessIdentifier: dockProcessIdentifier,
            expectedBundleIdentifier:
                expectedSuggestion.bundleIdentifier
        ) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, isRunning else {
                    return
                }
                switch result {
                case .succeeded:
                    _ = handoffState
                        .markContinuationSucceeded(
                            expectedBundleIdentifier:
                                expectedSuggestion
                                    .bundleIdentifier
                        )
                    publishHandoffState()
                    DiagnosticsTrace.shared.record(
                        .actions,
                        "handoffContinuationRequested",
                        fields: ["succeeded": true]
                    )
                    recordHandoffState("continued")
                case .unavailable:
                    DiagnosticsTrace.shared.record(
                        .actions,
                        "handoffContinuationRequested",
                        fields: [
                            "succeeded": false,
                            "reason": "itemUnavailable",
                        ]
                    )
                    clearExpectedHandoffSuggestion(
                        expectedBundleIdentifier:
                            expectedSuggestion.bundleIdentifier,
                        diagnosticState: "itemUnavailable"
                    )
                    refresh()
                case .suggestionChanged:
                    DiagnosticsTrace.shared.record(
                        .actions,
                        "handoffContinuationRequested",
                        fields: [
                            "succeeded": false,
                            "reason": "suggestionChanged",
                        ]
                    )
                    clearExpectedHandoffSuggestion(
                        expectedBundleIdentifier:
                            expectedSuggestion.bundleIdentifier,
                        diagnosticState: "suggestionChanged"
                    )
                    refresh()
                case .failed(let errorCode):
                    DiagnosticsTrace.shared.record(
                        .actions,
                        "handoffContinuationRequested",
                        fields: [
                            "succeeded": false,
                            "reason": "axFailure",
                            "errorCode": errorCode,
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Polling

    private func refresh() {
        let isTrusted = AXIsProcessTrusted()
        if lastAccessibilityTrust != isTrusted {
            lastAccessibilityTrust = isTrusted
            DiagnosticsTrace.shared.record(
                .systemDock,
                "dockAccessibilityTrustChanged",
                fields: ["trusted": isTrusted]
            )
        }

        guard isTrusted else {
            // Invalidate any worker reply that began before trust was lost.
            sessionGeneration &+= 1
            if !badgesByBundleID.isEmpty {
                badgesByBundleID = [:]
            }
            handoffState.apply(.permissionUnavailable)
            publishHandoffState()
            recordHandoffState("permissionUnavailable")
            return
        }
        guard let dockProcessIdentifier =
                dockProcessIdentifier() else {
            return
        }

        let generation = sessionGeneration
        axWorker.requestRefresh(
            dockProcessIdentifier: dockProcessIdentifier
        ) { [weak self] snapshot in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      isRunning,
                      sessionGeneration == generation else {
                    return
                }
                if snapshot.badgesByBundleID
                    != badgesByBundleID {
                    badgesByBundleID =
                        snapshot.badgesByBundleID
                }
                applyHandoffSnapshot(snapshot)
            }
        }
    }

    private func applyHandoffSnapshot(
        _ snapshot: AXSystemDockSnapshot
    ) {
        if let errorCode = snapshot.handoffScanErrorCode {
            // An AX transport failure is not evidence that Handoff ended.
            // Preserve the published suggestion until a conclusive scan.
            handoffState.apply(
                .inconclusive(errorCode: errorCode)
            )
            publishHandoffState()
            recordHandoffState(
                "scanUnavailable",
                errorCode: errorCode
            )
            return
        }

        if let suggestion = snapshot.handoffSuggestion {
            handoffState.apply(.available(suggestion))
            publishHandoffState()
            if handoffState.suppressedBundleIdentifier
                == suggestion.bundleIdentifier {
                recordHandoffState(
                    "continuedSuggestionSuppressed",
                    suggestion: suggestion
                )
                return
            }
            recordHandoffState(
                "available",
                suggestion: suggestion
            )
            return
        }

        let missingState = snapshot.foundHandoffItem
            ? "unresolved"
            : "absent"
        if snapshot.foundHandoffItem {
            handoffState.apply(.unresolved)
        } else {
            handoffState.apply(.absent)
        }
        publishHandoffState()
        recordHandoffState(missingState)
    }

    private func clearHandoffSuggestion(
        diagnosticState: String
    ) {
        handoffState.clear()
        publishHandoffState()
        recordHandoffState(diagnosticState)
    }

    private func clearExpectedHandoffSuggestion(
        expectedBundleIdentifier: String,
        diagnosticState: String
    ) {
        guard handoffState.clearVisibleSuggestion(
            expectedBundleIdentifier: expectedBundleIdentifier
        ) else {
            return
        }
        publishHandoffState()
        recordHandoffState(diagnosticState)
    }

    private func publishHandoffState() {
        if handoffSuggestion
            != handoffState.visibleSuggestion {
            handoffSuggestion =
                handoffState.visibleSuggestion
        }
    }

    private func recordHandoffState(
        _ state: String,
        suggestion: DockHandoffSuggestion? = nil,
        errorCode: Int? = nil
    ) {
        let bundleIdentifier =
            suggestion?.bundleIdentifier ?? ""
        let diagnosticKey =
            "\(state):\(bundleIdentifier):\(errorCode ?? 0)"
        guard diagnosticKey != lastHandoffDiagnosticKey else {
            return
        }
        lastHandoffDiagnosticKey = diagnosticKey

        var fields: [String: Any] = ["state": state]
        if !bundleIdentifier.isEmpty {
            fields["appToken"] = DiagnosticsTrace.shared
                .token(bundleIdentifier)
        }
        if let errorCode {
            fields["errorCode"] = errorCode
        }
        DiagnosticsTrace.shared.record(
            .systemDock,
            "handoffMirrorStateChanged",
            fields: fields
        )
    }

    private func startObservingHandoffChanges() {
        guard !observesHandoffChangeNotification else {
            return
        }
        let center =
            CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            handoffSuggestionChangedCallback,
            Self.handoffChangedNotification.rawValue,
            nil,
            .deliverImmediately
        )
        observesHandoffChangeNotification = true
    }

    private func stopObservingHandoffChanges() {
        guard observesHandoffChangeNotification else {
            return
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            Self.handoffChangedNotification,
            nil
        )
        observesHandoffChangeNotification = false
    }

    private func dockProcessIdentifier() -> pid_t? {
        NSRunningApplication
            .runningApplications(
                withBundleIdentifier: "com.apple.dock"
            )
            .first?
            .processIdentifier
    }
}
