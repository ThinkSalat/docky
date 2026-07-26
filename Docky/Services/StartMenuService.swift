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
    /// 'STMN' as four ASCII bytes — disambiguates this hotkey from
    /// LaunchpadHotKeyService's 'DKYL'.
    private let hotKeyID = EventHotKeyID(signature: OSType(0x53544D4E), id: 1)

    private init() {
        installHotKeyHandlerIfNeeded()
        registerHotKey()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    func toggle() {
        isPresented ? dismiss() : present()
    }

    func present() {
        guard !isPresented else { return }
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        showsAllApps = false
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

            guard status == noErr, firedID.signature == service.hotKeyID.signature else {
                return OSStatus(eventNotHandledErr)
            }

            Task { @MainActor in service.toggle() }
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

    private func registerHotKey() {
        // ⌃⌥S — picked because it's unlikely to collide with system
        // shortcuts and isn't already bound by Docky preferences.
        let keyCode = UInt32(kVK_ANSI_S)
        let modifiers = UInt32(controlKey | optionKey)
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
