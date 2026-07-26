//
//  PermissionsService.swift
//  Docky
//
//  Tracks feature-specific macOS capabilities. None of these capabilities
//  blocks launch: callers request access at the action that needs it and
//  otherwise degrade to the subset of Docky that is available.
//
//  Folder access is intentionally not represented here. macOS has no
//  supported API for querying Full Disk Access, and a probe of an unrelated
//  protected directory does not describe whether a particular pinned folder
//  is readable. FolderAccessService reports that state from the actual folder.
//

import AppKit
import ApplicationServices
import Combine
import CoreLocation

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

enum GrantMethod {
    case automation
    case accessibility
    case screenCapture
    case location
}

enum Permission: String, CaseIterable, Identifiable {
    case finderAutomation
    case accessibility
    case systemEventsAutomation
    case screenCapture
    case location
    case calendar
    case reminders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .finderAutomation: return "Automation (Finder)"
        case .accessibility: return "Accessibility"
        case .systemEventsAutomation: return "Automation (System Events)"
        case .screenCapture: return "Screen Recording"
        case .location: return "Location"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        }
    }

    var explanation: String {
        switch self {
        case .finderAutomation:
            return "Docky uses Finder automation for reveal-in-Finder, open-folder, and Trash actions. Docky requests this only when you use one of those actions or explicitly enable it here."
        case .accessibility:
            return "Accessibility access lets Docky click menu bar items for curated menuClick actions, inspect app windows for Dock-like reopen behavior and window menus, and restore minimized windows beside the Trash. These actions are slower and more fragile than built-in actions, so Docky requests this only when needed."
        case .systemEventsAutomation:
            return "Docky uses System Events automation for curated menuClick actions. Requesting it here lets Docky click supported app menus without waiting for the first action to trigger a macOS prompt. Menu-click actions still require Accessibility too."
        case .screenCapture:
            return "Grant Screen Recording so Docky can show thumbnail previews for minimized windows. Docky only captures the minimized window itself for its dock tile, and nothing leaves your Mac. macOS may require quitting and reopening Docky after you allow this."
        case .location:
            return "Grant location access so Docky can show local weather in the Weather widget. Your location is used on-device to fetch the forecast and is not stored by Docky."
        case .calendar:
            return "Grant Calendar access so the Calendar widget can show your upcoming events. Events are read on-device and never leave your Mac."
        case .reminders:
            return "Grant Reminders access so the Reminders widget can show your open tasks. Reminders are read on-device and never leave your Mac."
        }
    }

    var systemSettingsURL: URL? {
        switch self {
        case .finderAutomation:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .systemEventsAutomation:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenCapture:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .location:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        case .calendar:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .reminders:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        }
    }

}

final class PermissionsService: ObservableObject {
    static let shared = PermissionsService()

    @Published private(set) var finderAutomation: PermissionStatus = .notDetermined
    @Published private(set) var finderAutomationGrantMethod: GrantMethod?

    @Published private(set) var accessibility: PermissionStatus = .notDetermined
    @Published private(set) var accessibilityGrantMethod: GrantMethod?

    @Published private(set) var systemEventsAutomation: PermissionStatus = .notDetermined
    @Published private(set) var systemEventsAutomationGrantMethod: GrantMethod?

    @Published private(set) var screenCapture: PermissionStatus = .notDetermined
    @Published private(set) var screenCaptureGrantMethod: GrantMethod?

    @Published private(set) var location: PermissionStatus = .notDetermined
    @Published private(set) var locationGrantMethod: GrantMethod?

    @Published private(set) var calendar: PermissionStatus = .notDetermined
    @Published private(set) var reminders: PermissionStatus = .notDetermined

    private let finderAutomationStatusKey = "docky.finderAutomationStatus"
    private let systemEventsAutomationStatusKey = "docky.systemEventsAutomationStatus"
    private var lastDiagnosticsPermissionSummary: [String: String]?

    private init() {
        refresh()
    }

    // MARK: - Status

    func status(for permission: Permission) -> PermissionStatus {
        switch permission {
        case .finderAutomation: return finderAutomation
        case .accessibility: return accessibility
        case .systemEventsAutomation: return systemEventsAutomation
        case .screenCapture: return screenCapture
        case .location: return location
        case .calendar: return calendar
        case .reminders: return reminders
        }
    }

    func refresh() {
        refreshFinderAutomation()
        refreshAccessibility()
        refreshSystemEventsAutomation()
        refreshScreenCapture()
        refreshLocation()
        refreshCalendar()
        refreshReminders()
        let diagnosticsSummary = [
            "finderAutomation": String(describing: finderAutomation),
            "accessibility": String(describing: accessibility),
            "systemEventsAutomation": String(describing: systemEventsAutomation),
            "screenCapture": String(describing: screenCapture),
            "location": String(describing: location),
            "calendar": String(describing: calendar),
            "reminders": String(describing: reminders),
        ]
        if diagnosticsSummary != lastDiagnosticsPermissionSummary {
            lastDiagnosticsPermissionSummary = diagnosticsSummary
            DiagnosticsTrace.shared.record(
                .lifecycle,
                "permissionsChanged",
                fields: diagnosticsSummary
            )
        }
    }

    // MARK: - Grant actions

    func openSystemSettings(for permission: Permission) {
        guard let url = permission.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func requestPermission(for permission: Permission) async -> Bool {
        switch permission {
        case .finderAutomation:
            return await AppleScriptService.shared.requestFinderAutomationPermission()
        case .accessibility:
            return requestAccessibilityPermission(prompt: true)
        case .systemEventsAutomation:
            return await AppleScriptService.shared.requestSystemEventsAutomationPermission()
        case .screenCapture:
            return requestScreenCapturePermission()
        case .location:
            let granted = await WeatherService.shared.requestAccess()
            refreshLocation()
            return granted
        case .calendar:
            let granted = await CalendarService.shared.requestAccess()
            refreshCalendar()
            return granted
        case .reminders:
            let granted = await RemindersService.shared.requestAccess()
            refreshReminders()
            return granted
        }
    }

    func clearAutomationStatus(for permission: Permission) {
        switch permission {
        case .finderAutomation:
            UserDefaults.standard.removeObject(forKey: finderAutomationStatusKey)
            refreshFinderAutomation()
        case .systemEventsAutomation:
            UserDefaults.standard.removeObject(forKey: systemEventsAutomationStatusKey)
            refreshSystemEventsAutomation()
        case .accessibility, .screenCapture, .location, .calendar, .reminders:
            break
        }
    }

    @discardableResult
    func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        refreshAccessibility()
        return granted
    }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refreshScreenCapture()
        return granted
    }

    func presentPermissionAlert(for permission: Permission, actionTitle: String) {
        let alert = NSAlert()
        alert.messageText = permission.title + " is required"
        alert.informativeText = "Allow Docky in Privacy & Security so it can perform \(actionTitle.lowercased())."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings(for: permission)
        }
    }

    // MARK: - Finder automation permission

    func updateFinderAutomation(status: PermissionStatus) {
        switch status {
        case .granted:
            UserDefaults.standard.set("granted", forKey: finderAutomationStatusKey)
            finderAutomationGrantMethod = .automation
        case .denied:
            UserDefaults.standard.set("denied", forKey: finderAutomationStatusKey)
            finderAutomationGrantMethod = nil
        case .notDetermined:
            UserDefaults.standard.removeObject(forKey: finderAutomationStatusKey)
            finderAutomationGrantMethod = nil
        }
        finderAutomation = status
    }

    private func refreshFinderAutomation() {
        switch UserDefaults.standard.string(forKey: finderAutomationStatusKey) {
        case "granted":
            finderAutomation = .granted
            finderAutomationGrantMethod = .automation
        case "denied":
            finderAutomation = .denied
            finderAutomationGrantMethod = nil
        default:
            finderAutomation = .notDetermined
            finderAutomationGrantMethod = nil
        }
    }

    func updateSystemEventsAutomation(status: PermissionStatus) {
        switch status {
        case .granted:
            UserDefaults.standard.set("granted", forKey: systemEventsAutomationStatusKey)
            systemEventsAutomationGrantMethod = .automation
        case .denied:
            UserDefaults.standard.set("denied", forKey: systemEventsAutomationStatusKey)
            systemEventsAutomationGrantMethod = nil
        case .notDetermined:
            UserDefaults.standard.removeObject(forKey: systemEventsAutomationStatusKey)
            systemEventsAutomationGrantMethod = nil
        }
        systemEventsAutomation = status
    }

    private func refreshSystemEventsAutomation() {
        switch UserDefaults.standard.string(forKey: systemEventsAutomationStatusKey) {
        case "granted":
            systemEventsAutomation = .granted
            systemEventsAutomationGrantMethod = .automation
        case "denied":
            systemEventsAutomation = .denied
            systemEventsAutomationGrantMethod = nil
        default:
            systemEventsAutomation = .notDetermined
            systemEventsAutomationGrantMethod = nil
        }
    }

    private func refreshAccessibility() {
        let granted = AXIsProcessTrusted()
        accessibility = granted ? .granted : .denied
        accessibilityGrantMethod = granted ? .accessibility : nil
    }

    private func refreshScreenCapture() {
        let granted = CGPreflightScreenCaptureAccess()
        screenCapture = granted ? .granted : .denied
        screenCaptureGrantMethod = granted ? .screenCapture : nil
    }

    private func refreshLocation() {
        WeatherService.shared.refreshAuthorizationStatus()

        if WeatherService.shared.hasLocationAuthorization {
            location = .granted
            locationGrantMethod = .location
            return
        }

        switch WeatherService.shared.authorizationStatus {
        case .notDetermined:
            location = .notDetermined
            locationGrantMethod = nil
        case .denied, .restricted:
            location = .denied
            locationGrantMethod = nil
        case .authorizedAlways:
            location = .granted
            locationGrantMethod = .location
        @unknown default:
            location = .denied
            locationGrantMethod = nil
        }
    }

    private func refreshCalendar() {
        CalendarService.shared.refreshAuthorizationStatus()
        calendar = CalendarService.shared.permissionStatus
    }

    private func refreshReminders() {
        RemindersService.shared.refreshAuthorizationStatus()
        reminders = RemindersService.shared.permissionStatus
    }

}
