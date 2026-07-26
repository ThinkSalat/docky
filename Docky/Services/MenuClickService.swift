//
//  MenuClickService.swift
//  Docky
//

import AppKit
import Foundation

final class MenuClickService {
    static let shared = MenuClickService()

    private init() {}

    @discardableResult
    func perform(action: CatalogActionDefinition, context: CatalogActionContext) async -> Bool {
        guard let targetApp = action.targetApp,
              let path = action.path,
              !path.isEmpty else {
            return false
        }

        if action.requiresFrontmost {
            WorkspaceService.shared.activateOrOpen(bundleIdentifier: targetApp)
            try? await Task.sleep(for: .milliseconds(250))
        }

        let processName = await runningApplicationName(for: targetApp)
        guard let processName else {
            presentUnavailableAlert(targetApp: targetApp, actionTitle: action.title)
            return false
        }

        if PermissionsService.shared.status(for: .accessibility) != .granted {
            PermissionsService.shared.requestAccessibilityPermission(prompt: true)
        }

        guard PermissionsService.shared.status(for: .accessibility) == .granted else {
            PermissionsService.shared.presentPermissionAlert(for: .accessibility, actionTitle: action.title)
            return false
        }

        if PermissionsService.shared.status(for: .systemEventsAutomation) != .granted {
            _ = await PermissionsService.shared.requestPermission(for: .systemEventsAutomation)
        }

        guard PermissionsService.shared.status(for: .systemEventsAutomation) == .granted else {
            PermissionsService.shared.presentPermissionAlert(for: .systemEventsAutomation, actionTitle: action.title)
            return false
        }

        return await AppleScriptService.shared.runMenuClickScript(
            targetApp: targetApp,
            processName: processName,
            path: path,
            requiresFrontmost: action.requiresFrontmost,
            holdOption: action.holdOption,
            actionTitle: action.title
        )
    }

    private func runningApplicationName(
        for bundleIdentifier: String
    ) async -> String? {
        if let running = WorkspaceService.shared.runningApps.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }), !running.localizedName.isEmpty {
            return running.localizedName
        }

        // Accessory/background processes are intentionally absent from
        // WorkspaceService's dock-facing snapshot. Preserve support for
        // their catalog actions, but query AppKit away from MainActor.
        if let processName = await Task.detached(
            priority: .userInitiated,
            operation: {
                NSRunningApplication
                    .runningApplications(
                        withBundleIdentifier: bundleIdentifier
                    )
                    .first?
                    .localizedName
            }
        ).value, !processName.isEmpty {
            return processName
        }

        guard !Task.isCancelled,
              let url = await ApplicationURLResolver.shared.applicationURL(
                for: bundleIdentifier
              ),
              !Task.isCancelled else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            FileManager.default.displayName(atPath: url.path)
        }.value
    }

    private func presentUnavailableAlert(targetApp: String, actionTitle: String) {
        let alert = NSAlert()
        alert.messageText = "Menu action unavailable"
        alert.informativeText = "Docky couldn't find a running process for \(targetApp) to perform \(actionTitle.lowercased())."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
