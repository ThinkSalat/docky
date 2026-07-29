//
//  StartMenuEnablementPolicy.swift
//  Docky
//
//  Pure lifecycle decisions for the Start Menu feature gate.
//

import Foundation

nonisolated enum StartMenuEnablementPolicy {
    enum HotKeyAction: Equatable {
        case none
        case register
        case unregister
    }

    enum PresentationCommand: Equatable {
        case present
        case toggle
    }

    enum PresentationAction: Equatable {
        case none
        case present
        case dismiss
    }

    struct EnablementEffects: Equatable {
        let hotKeyAction: HotKeyAction
        let presentationAction: PresentationAction
    }

    static func effects(
        currentEnabled: Bool,
        isHotKeyRegistered: Bool,
        isPresented: Bool,
        requestedEnabled: Bool
    ) -> EnablementEffects {
        if requestedEnabled {
            return EnablementEffects(
                hotKeyAction: isHotKeyRegistered ? .none : .register,
                presentationAction: .none
            )
        }

        return EnablementEffects(
            hotKeyAction: isHotKeyRegistered ? .unregister : .none,
            presentationAction:
                currentEnabled || isPresented ? .dismiss : .none
        )
    }

    static func presentationAction(
        for command: PresentationCommand,
        isEnabled: Bool,
        isPresented: Bool
    ) -> PresentationAction {
        guard isEnabled else { return .none }

        switch command {
        case .present:
            return isPresented ? .none : .present
        case .toggle:
            return isPresented ? .dismiss : .present
        }
    }

    /// Disabled means the feature cannot be introduced through the editor
    /// either. This second gate also rejects a stale palette drag that began
    /// before the setting changed.
    static func allowsPaletteInsertion(isEnabled: Bool) -> Bool {
        isEnabled
    }
}
