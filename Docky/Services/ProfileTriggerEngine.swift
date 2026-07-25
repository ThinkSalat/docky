//
//  ProfileTriggerEngine.swift
//  Docky
//
//  Watches the signals that profile triggers care about — frontmost app,
//  Mission Control space, and clock minute boundaries — and switches the
//  active dock profile when a higher-specificity trigger matches than
//  whatever is currently active. Phase 1 covers time, app, space. Wi-Fi
//  / Bluetooth land in phase 2.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ProfileTriggerEngine {
    static let shared = ProfileTriggerEngine()

    private let profileService = ProfileService.shared
    private var cancellables: Set<AnyCancellable> = []
    private var minuteTimer: Timer?
    private var spacePollTimer: Timer?
    private var currentFrontmostBundleID: String?
    private var currentSpaceApps: Set<String> = []
    private var currentExactSpaceID: UInt64 = 0
    /// id of the profile we activated automatically. Lets the user
    /// override us (manual pick) without us immediately reverting.
    private var lastAutoActivatedProfileID: String?

    private init() {}

    func start() {
        currentFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        currentSpaceApps = ProfileTriggerEngine.appsOnActiveSpace()
        currentExactSpaceID = ProfileTriggerEngine.activeSpaceID()
        observeFrontmostApp()
        observeActiveSpace()
        scheduleSpacePolling()
        scheduleMinuteTick()
        evaluate()
    }

    func stop() {
        cancellables.removeAll()
        minuteTimer?.invalidate()
        minuteTimer = nil
        spacePollTimer?.invalidate()
        spacePollTimer = nil
    }

    /// Bundle identifiers of every app that currently has a visible
    /// window on the active space. Fullscreen-app spaces typically
    /// return just one entry — the app whose space it is.
    static func appsOnActiveSpace() -> Set<String> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: Set<String> = []
        for window in windows {
            // Skip Docky's own windows so they don't poison matches.
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier
            else { continue }
            // Layer 0 is the normal app window layer; menu bar/dock
            // utility windows have non-zero layers we want to ignore.
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            result.insert(bundleID)
        }
        return result
    }

    private func observeFrontmostApp() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let self else { return }
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.currentFrontmostBundleID =
                    app?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                // Activating an app on the current space adds it to the
                // set — refresh so space-by-app triggers stay accurate.
                self.currentSpaceApps = ProfileTriggerEngine.appsOnActiveSpace()
                self.evaluate()
            }
            .store(in: &cancellables)
    }

    private func observeActiveSpace() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.currentSpaceApps = ProfileTriggerEngine.appsOnActiveSpace()
                self.currentExactSpaceID = ProfileTriggerEngine.activeSpaceID()
                self.evaluate()
            }
            .store(in: &cancellables)
    }

    /// Stable identifier for the Mission Control space on the focused
    /// display. A zero result means SkyLight could not resolve a space and
    /// deliberately matches no exact-space trigger.
    static func activeSpaceID() -> UInt64 {
        CGSGetActiveSpace(CGSMainConnectionID())
    }

    /// `NSWorkspace.activeSpaceDidChangeNotification` can arrive only after
    /// the multi-second Space transition animation completes. Polling this
    /// inexpensive SkyLight value lets exact-Space profiles change as soon
    /// as the system commits the destination Space. The public notification
    /// remains installed as a fallback and refreshes app-presence triggers.
    private func scheduleSpacePolling() {
        spacePollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollActiveSpace()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spacePollTimer = timer
    }

    private func pollActiveSpace() {
        let nextSpaceID = ProfileTriggerEngine.activeSpaceID()
        guard nextSpaceID != 0, nextSpaceID != currentExactSpaceID else { return }
        currentExactSpaceID = nextSpaceID
        currentSpaceApps = ProfileTriggerEngine.appsOnActiveSpace()
        evaluate()
    }

    private func scheduleMinuteTick() {
        // Fire at the next minute boundary, then every minute. Time-of-day
        // triggers only need minute precision; that avoids re-evaluating
        // the world on every second.
        let calendar = Calendar.current
        let now = Date()
        let nextMinute = calendar.nextDate(
            after: now,
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60)
        let firstFire = nextMinute.timeIntervalSinceNow
        let timer = Timer.scheduledTimer(withTimeInterval: max(firstFire, 1), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickMinute()
            }
        }
        minuteTimer = timer
    }

    private func tickMinute() {
        evaluate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        minuteTimer = timer
    }

    private func evaluate() {
        let matches = bestMatch()
        guard let matched = matches else { return }
        if matched.id == profileService.activeProfileID { return }

        // Only auto-switch if the previously-active profile was the one
        // we set automatically (or initial state). If the user manually
        // picked a profile, leave them alone until something explicitly
        // higher-priority matches.
        let userIsOnAutoProfile = lastAutoActivatedProfileID == profileService.activeProfileID
        if !userIsOnAutoProfile, lastAutoActivatedProfileID != nil {
            // User overrode us — don't fight back. We'll resume on the
            // next manual switch back to one of our auto profiles, or
            // when the engine restarts.
            return
        }

        profileService.setActiveProfile(id: matched.id)
        lastAutoActivatedProfileID = matched.id
    }

    private func bestMatch() -> DockProfile? {
        let now = Date()
        let frontmost = currentFrontmostBundleID
        let spaceApps = currentSpaceApps
        let exactSpaceID = currentExactSpaceID

        struct Match {
            let profile: DockProfile
            let specificity: Int
        }

        var best: Match?
        for profile in profileService.profiles {
            var profileBest: Int?
            for trigger in profile.triggers {
                guard ProfileTriggerEngine.trigger(
                    trigger,
                    matches: now,
                    frontmost: frontmost,
                    spaceApps: spaceApps,
                    exactSpaceID: exactSpaceID
                ) else { continue }
                if profileBest.map({ trigger.specificity > $0 }) ?? true {
                    profileBest = trigger.specificity
                }
            }
            guard let specificity = profileBest else { continue }
            if let current = best {
                if specificity > current.specificity {
                    best = Match(profile: profile, specificity: specificity)
                } else if specificity == current.specificity,
                          profile.dateCreated < current.profile.dateCreated {
                    best = Match(profile: profile, specificity: specificity)
                }
            } else {
                best = Match(profile: profile, specificity: specificity)
            }
        }
        return best?.profile
    }

    private static func trigger(
        _ trigger: ProfileTrigger,
        matches now: Date,
        frontmost: String?,
        spaceApps: Set<String>,
        exactSpaceID: UInt64
    ) -> Bool {
        switch trigger {
        case .timeOfDay(let t):
            return t.matches(date: now)
        case .frontmostApp(let t):
            return frontmost == t.bundleIdentifier
        case .space(let t):
            return spaceApps.contains(t.bundleIdentifier)
        case .exactSpace(let t):
            return exactSpaceID != 0 && exactSpaceID == t.spaceID
        }
    }
}
