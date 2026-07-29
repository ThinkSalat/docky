//
//  LaunchpadHotKeyService.swift
//  Docky
//

import AppKit
import Carbon

struct GlobalHotKeyBackend {
    let register:
        (
            _ keyCode: UInt32,
            _ modifiers: UInt32,
            _ identifier: EventHotKeyID
        ) -> (status: OSStatus, reference: EventHotKeyRef?)
    let unregister: (_ reference: EventHotKeyRef) -> OSStatus

    static let live = GlobalHotKeyBackend(
        register: { keyCode, modifiers, identifier in
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            return (status, reference)
        },
        unregister: { reference in
            UnregisterEventHotKey(reference)
        }
    )
}

final class LaunchpadHotKeyService {
    static let shared = LaunchpadHotKeyService()

    private let backend: GlobalHotKeyBackend
    private var hotKeyRef: EventHotKeyRef?
    private var orphanedHotKeyRefs: [EventHotKeyRef] = []
    private var registeredShortcut: KeyboardShortcut?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hotKeyHandlerInstallationError: String?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x444B594C), id: 1)

    init(backend: GlobalHotKeyBackend = .live) {
        self.backend = backend
        installHotKeyHandlerIfNeeded()
        let initialResult = replaceHotKey(
            with: DockyPreferences.shared.launchpadShortcut
        )
        DockyPreferences.shared
            .recordLaunchpadHotKeyRegistrationResult(initialResult)
    }

    deinit {
        unregisterHotKey()

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let service = Unmanaged<LaunchpadHotKeyService>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr, hotKeyID.signature == service.hotKeyID.signature else {
                return OSStatus(eventNotHandledErr)
            }

            Task { @MainActor in
                guard DockyPreferences.shared.enablesLaunchpadOverlay else {
                    return
                }
                LaunchpadOverlayService.shared.toggle()
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        guard status == noErr, hotKeyHandlerRef != nil else {
            hotKeyHandlerRef = nil
            hotKeyHandlerInstallationError =
                "Launchpad could not install its global shortcut event "
                + "handler (OSStatus \(status))."
            return
        }
        hotKeyHandlerInstallationError = nil
    }

    @discardableResult
    func replaceHotKey(
        with shortcut: KeyboardShortcut
    ) -> GlobalHotKeyRegistrationResult {
        reconcileHotKey(
            isEnabled:
                DockyPreferences.shared.enablesLaunchpadOverlay,
            shortcut: shortcut
        )
    }

    @discardableResult
    func setEnabled(
        _ isEnabled: Bool,
        shortcut: KeyboardShortcut
    ) -> GlobalHotKeyRegistrationResult {
        reconcileHotKey(
            isEnabled: isEnabled,
            shortcut: shortcut
        )
    }

    private func reconcileHotKey(
        isEnabled: Bool,
        shortcut: KeyboardShortcut
    ) -> GlobalHotKeyRegistrationResult {
        if hotKeyHandlerRef == nil {
            installHotKeyHandlerIfNeeded()
        }
        if let hotKeyHandlerInstallationError {
            return .failed(hotKeyHandlerInstallationError)
        }

        if let recoveryError = healTrackedRegistrationIfNeeded() {
            return .failed(recoveryError)
        }

        if let cleanupError = retryOrphanCleanup() {
            return .failed(cleanupError)
        }

        guard isEnabled, shortcut.isValid else {
            if let cleanupError = unregisterHotKey() {
                let rollbackDetail: String
                if let rollbackError =
                    healTrackedRegistrationIfNeeded()
                {
                    rollbackDetail =
                        " Restoring the previously confirmed shortcut "
                        + "also failed: \(rollbackError)"
                } else {
                    rollbackDetail =
                        " The previously confirmed shortcut was restored."
                }
                return .failed(cleanupError + rollbackDetail)
            }
            return .inactive
        }

        if registeredShortcut == shortcut, hotKeyRef != nil {
            return .registered
        }

        let candidate = backend.register(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            hotKeyID
        )
        guard candidate.status == noErr,
              let candidateRef = candidate.reference else {
            return .failed(
                hotKeyFailureMessage(
                    feature: "Launchpad",
                    status: candidate.status
                )
            )
        }

        if let previousRef = hotKeyRef {
            let previousUnregisterStatus =
                backend.unregister(previousRef)
            guard previousUnregisterStatus == noErr else {
                let candidateCleanupStatus =
                    backend.unregister(candidateRef)
                var cleanupDetail = ""
                if candidateCleanupStatus != noErr {
                    orphanedHotKeyRefs.append(candidateRef)
                    cleanupDetail =
                        " Cleanup of the candidate also failed "
                        + "(OSStatus \(candidateCleanupStatus)); Docky "
                        + "retained its reference and will retry."
                }
                return .failed(
                    "Launchpad registered the candidate shortcut but "
                        + "could not remove the previous shortcut "
                        + "(OSStatus \(previousUnregisterStatus)). The "
                        + "saved shortcut was not changed."
                        + cleanupDetail
                )
            }
        }

        hotKeyRef = candidateRef
        registeredShortcut = shortcut
        return .registered
    }

    @discardableResult
    private func unregisterHotKey() -> String? {
        var failures: [String] = []
        if let hotKeyRef {
            let status = backend.unregister(hotKeyRef)
            if status == noErr {
                self.hotKeyRef = nil
            } else {
                failures.append("active shortcut OSStatus \(status)")
            }
        }

        if let cleanupError = retryOrphanCleanup() {
            failures.append(cleanupError)
        }

        guard failures.isEmpty else {
            return "Launchpad could not unregister every tracked global "
                + "shortcut (\(failures.joined(separator: "; "))). "
                + "References and confirmed shortcut metadata were retained "
                + "for retry."
        }

        registeredShortcut = nil
        return nil
    }

    private func healTrackedRegistrationIfNeeded() -> String? {
        guard let registeredShortcut else {
            guard hotKeyRef == nil else {
                return "Launchpad retained a registration without enough "
                    + "shortcut metadata to repair it safely."
            }
            return nil
        }

        guard hotKeyRef == nil else {
            return nil
        }
        guard registeredShortcut.isValid else {
            return "Launchpad cannot repair the previously saved shortcut "
                + "because it is no longer valid."
        }

        let restored = backend.register(
            UInt32(registeredShortcut.keyCode),
            registeredShortcut.carbonModifierFlags,
            hotKeyID
        )
        guard restored.status == noErr,
              let restoredRef = restored.reference else {
            return "Launchpad could not restore the previous shortcut "
                + "(OSStatus \(restored.status)). Its confirmed shortcut "
                + "metadata was retained for retry."
        }

        hotKeyRef = restoredRef
        return nil
    }

    private func retryOrphanCleanup() -> String? {
        guard !orphanedHotKeyRefs.isEmpty else {
            return nil
        }

        var retained: [EventHotKeyRef] = []
        var statuses: [OSStatus] = []
        for reference in orphanedHotKeyRefs {
            let status = backend.unregister(reference)
            if status != noErr {
                retained.append(reference)
                statuses.append(status)
            }
        }
        orphanedHotKeyRefs = retained

        guard !statuses.isEmpty else {
            return nil
        }
        return "Launchpad could not clean up candidate global shortcuts "
            + "(OSStatus \(statuses.map(String.init).joined(separator: ", ")))."
    }

    private func hotKeyFailureMessage(
        feature: String,
        status: OSStatus
    ) -> String {
        "\(feature) could not register that global shortcut "
            + "(OSStatus \(status)). Another app or system shortcut may "
            + "already be using it. The previous shortcut was kept."
    }
}
