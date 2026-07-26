//
//  DockBadgeService.swift
//  Docky
//
//  Reads notification badges (the red number on Mail, Messages, etc.) for
//  running apps and republishes them keyed by bundle identifier so tiles can
//  draw their own badge.
//
//  Source of truth: the system Dock. Each app sets its badge on its own dock
//  tile, and only the Dock process aggregates them, there's no public API to
//  read another app's badge directly. We read the Dock's accessibility tree
//  instead: every dock item exposes `AXStatusLabel` (the badge text) and an
//  `AXURL` (the .app location) we map back to a bundle id. This works even
//  when the system Dock is auto-hidden, since the Dock process and its AX
//  tree stay alive regardless of visibility.
//

import AppKit
import ApplicationServices
import Combine

/// Dedicated serialized owner for the Dock's remote Accessibility tree. The
/// worker returns only a value dictionary; no AXUIElement leaves this queue.
nonisolated final class AXDockBadgeWorker: @unchecked Sendable {
    typealias Completion = @Sendable ([String: String]) -> Void

    private struct Request {
        let dockProcessIdentifier: pid_t
        let completion: Completion
    }

    private let queue = DispatchQueue(
        label: "gt.quintero.Docky.AXDockBadgeWorker",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var isRefreshing = false
    private var pendingRequest: Request?

    // Worker-queue-only state.
    private var bundleIDByPath: [String: String] = [:]
    private var configuredMessagingTimeout = false

    func requestRefresh(
        dockProcessIdentifier: pid_t,
        completion: @escaping Completion
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

    private func drainNextRefresh() {
        stateLock.lock()
        let request = pendingRequest
        pendingRequest = nil
        stateLock.unlock()

        guard let request else {
            finishRefresh()
            return
        }

        let badges = autoreleasepool {
            readBadges(
                dockProcessIdentifier: request.dockProcessIdentifier
            )
        }
        request.completion(badges)

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

    private func readBadges(
        dockProcessIdentifier: pid_t
    ) -> [String: String] {
        guard dockProcessIdentifier > 0 else { return [:] }
        if !configuredMessagingTimeout {
            _ = AXUIElementSetMessagingTimeout(
                AXUIElementCreateSystemWide(),
                1.0
            )
            configuredMessagingTimeout = true
        }

        let dock = AXUIElementCreateApplication(dockProcessIdentifier)
        var badges: [String: String] = [:]
        for item in dockItems(in: dock) {
            guard let badge = trimmedBadge(from: item),
                  let bundleID = bundleIdentifier(for: item) else {
                continue
            }
            badges[bundleID] = badge
        }
        return badges
    }

    private func dockItems(in dock: AXUIElement) -> [AXUIElement] {
        for child in children(of: dock)
        where role(of: child) == (kAXListRole as String) {
            return children(of: child)
        }
        return []
    }

    private func bundleIdentifier(for item: AXUIElement) -> String? {
        guard let url = copyAttribute(
            item,
            kAXURLAttribute as CFString
        ) as? URL else {
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

    private func trimmedBadge(from item: AXUIElement) -> String? {
        guard let label = copyAttribute(
            item,
            "AXStatusLabel" as CFString
        ) as? String else {
            return nil
        }
        let trimmed = label.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(
            element,
            kAXChildrenAttribute as CFString
        ) as? [AXUIElement] ?? []
    }

    private func role(of element: AXUIElement) -> String? {
        copyAttribute(
            element,
            kAXRoleAttribute as CFString
        ) as? String
    }

    private func copyAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value
    }
}

@MainActor
final class DockBadgeService: ObservableObject {
    static let shared = DockBadgeService()

    /// Badge text per bundle identifier, e.g. ["com.apple.mail": "5"].
    /// Apps with no badge are absent from the map.
    @Published private(set) var badgesByBundleID: [String: String] = [:]

    /// How often we re-read the Dock's AX tree. Badge changes (new mail,
    /// etc.) arrive at unpredictable times and the Dock itself updates
    /// asynchronously, so polling is the pragmatic approach. The read is
    /// cheap (a few AX attribute copies per dock item).
    private let pollInterval: TimeInterval = 2

    private var timer: Timer?
    private let axWorker = AXDockBadgeWorker()
    private var sessionGeneration: UInt64 = 0
    private var isRunning = false

    private init() {}

    func badge(forBundleIdentifier bundleIdentifier: String) -> String? {
        badgesByBundleID[bundleIdentifier]
    }

    func start() {
        guard timer == nil else { return }
        isRunning = true
        sessionGeneration &+= 1
        refresh()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        sessionGeneration &+= 1
    }

    // MARK: - Polling

    private func refresh() {
        guard AXIsProcessTrusted() else {
            // Invalidate any worker reply that began before trust was lost.
            sessionGeneration &+= 1
            if !badgesByBundleID.isEmpty { badgesByBundleID = [:] }
            return
        }
        guard let dockProcessIdentifier = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier else {
            return
        }

        let generation = sessionGeneration
        axWorker.requestRefresh(
            dockProcessIdentifier: dockProcessIdentifier
        ) { [weak self] badges in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      isRunning,
                      sessionGeneration == generation else {
                    return
                }
                if badges != badgesByBundleID {
                    badgesByBundleID = badges
                }
            }
        }
    }
}
