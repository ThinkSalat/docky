//
//  RecentAppsService.swift
//  Docky
//
//  Tracks bundle identifiers of apps the user has recently activated.
//  Driven by `NSWorkspace.didActivateApplicationNotification` so any
//  switch surface (Cmd+Tab, dock click, Spotlight, deep links) updates
//  the list. Persists the ordered identifier list to UserDefaults so the
//  Start menu has something to show on the very first launch in a
//  session and across app restarts.
//

import AppKit
import Combine
import Foundation

@MainActor
final class RecentAppsService: ObservableObject {
    static let shared = RecentAppsService()

    @Published private(set) var recentBundleIdentifiers: [String] = []

    private static let storageKey = "docky.recentAppBundleIdentifiers"
    private static let maxCount = 32

    private var observer: NSObjectProtocol?

    private init() {
        load()
        if recentBundleIdentifiers.isEmpty {
            seedFromRunningApps()
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            else { return }
            Task { @MainActor [weak self] in
                self?.record(bundleID)
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Surfaces an explicit recency hit. The activation notification will
    /// also fire when the launched app comes to the front, so callers
    /// don't have to call this for normal activations, but it's available
    /// for surfaces that want the list to update immediately on click
    /// (before the activation round-trip completes).
    func recordLaunch(bundleIdentifier: String) {
        record(bundleIdentifier)
    }

    private func record(_ bundleID: String) {
        // Skip Docky itself, the Finder activation churn that fires on
        // many incidental focus shifts, and anything bundleless.
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }

        var updated = recentBundleIdentifiers.filter { $0 != bundleID }
        updated.insert(bundleID, at: 0)
        if updated.count > Self.maxCount {
            updated = Array(updated.prefix(Self.maxCount))
        }
        guard updated != recentBundleIdentifiers else { return }
        recentBundleIdentifiers = updated
        UserDefaults.standard.set(updated, forKey: Self.storageKey)
    }

    private func load() {
        recentBundleIdentifiers = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
    }

    private func seedFromRunningApps() {
        let ownBundleID = Bundle.main.bundleIdentifier
        let bundleIDs = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter { $0 != ownBundleID }
        guard !bundleIDs.isEmpty else { return }
        recentBundleIdentifiers = Array(bundleIDs.prefix(Self.maxCount))
        UserDefaults.standard.set(recentBundleIdentifiers, forKey: Self.storageKey)
    }
}
