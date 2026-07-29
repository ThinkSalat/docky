//
//  StartMenuService.swift
//  Docky
//
//  Prototype: a "Start menu" panel attached to the dock via
//  `addChildWindow`. Toggled with ⌃⌥S.
//

import AppKit
import Carbon
import Combine

final class StartMenuService: ObservableObject {
    static let shared = StartMenuService()

    @Published private(set) var isPresented = false
    /// Whether the "all apps" side panel is open alongside the main menu.
    /// Reset to false on dismiss so re-summoning the menu always starts
    /// in the collapsed state.
    @Published var showsAllApps = false

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var isEnabled = false
    /// 'STMN' as four ASCII bytes — disambiguates this hotkey from
    /// LaunchpadHotKeyService's 'DKYL'.
    private let hotKeyID = EventHotKeyID(signature: OSType(0x53544D4E), id: 1)

    private init() {
        setEnabled(DockyPreferences.shared.enablesStartMenuOverlay)
    }

    deinit {
        unregisterHotKey()
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    /// Reconciles the runtime with the authoritative preference.
    ///
    /// This method is intentionally idempotent: initialization and a
    /// preference assignment may both request the same enabled state without
    /// installing the Carbon hotkey more than once.
    func setEnabled(_ enabled: Bool) {
        let effects = StartMenuEnablementPolicy.effects(
            currentEnabled: isEnabled,
            isHotKeyRegistered: hotKeyRef != nil,
            isPresented: isPresented,
            requestedEnabled: enabled
        )
        isEnabled = enabled

        switch effects.hotKeyAction {
        case .none:
            break
        case .register:
            registerHotKeyIfNeeded()
        case .unregister:
            unregisterHotKey()
        }

        if effects.presentationAction == .dismiss {
            dismiss()
        }
    }

    func toggle() {
        applyPresentationCommand(.toggle)
    }

    func present() {
        applyPresentationCommand(.present)
    }

    func dismiss() {
        isPresented = false
        showsAllApps = false
    }

    private func applyPresentationCommand(
        _ command: StartMenuEnablementPolicy.PresentationCommand
    ) {
        let preferenceEnabled =
            DockyPreferences.shared.enablesStartMenuOverlay
        if preferenceEnabled != isEnabled {
            setEnabled(preferenceEnabled)
        }

        switch StartMenuEnablementPolicy.presentationAction(
            for: command,
            isEnabled: preferenceEnabled && isEnabled,
            isPresented: isPresented
        ) {
        case .none:
            break
        case .present:
            isPresented = true
        case .dismiss:
            dismiss()
        }
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let service = Unmanaged<StartMenuService>.fromOpaque(userData).takeUnretainedValue()
            var firedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &firedID
            )

            guard status == noErr,
                  firedID.signature == service.hotKeyID.signature,
                  firedID.id == service.hotKeyID.id else {
                return OSStatus(eventNotHandledErr)
            }

            Task { @MainActor in
                guard DockyPreferences.shared.enablesStartMenuOverlay else {
                    service.setEnabled(false)
                    return
                }
                service.toggle()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
    }

    private func registerHotKeyIfNeeded() {
        guard isEnabled,
              DockyPreferences.shared.enablesStartMenuOverlay,
              hotKeyRef == nil else {
            return
        }

        installHotKeyHandlerIfNeeded()

        // ⌃⌥S — picked because it's unlikely to collide with system
        // shortcuts and isn't already bound by Docky preferences.
        let keyCode = UInt32(kVK_ANSI_S)
        let modifiers = UInt32(controlKey | optionKey)
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard status == noErr else { return }
        hotKeyRef = registeredHotKey
    }

    private func unregisterHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }
}
