//
//  DockWindowTintLayerPolicy.swift
//  Docky
//
//  Pure policy for deciding whether window chrome needs a SwiftUI tint fill.
//  Native Liquid Glass already supplies its own material color, so an
//  additional fallback tint is only appropriate when a user or theme
//  explicitly requested tint presentation.
//

import Foundation

nonisolated enum DockWindowTintLayerPolicy: Equatable {
    case transparent
    case resolvedTint

    static func resolve(
        hasExplicitTintPresentation: Bool,
        usesNativeLiquidGlass: Bool
    ) -> Self {
        if usesNativeLiquidGlass && !hasExplicitTintPresentation {
            return .transparent
        }
        return .resolvedTint
    }
}
