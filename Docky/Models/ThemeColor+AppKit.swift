//
//  ThemeColor+AppKit.swift
//  Docky
//
//  AppKit rendering bridge kept separate from the data-only theme schema.
//

import AppKit

extension ThemeColor {
    /// Snapshot RGB representation. Returns the named color's current
    /// RGB sample when only `name` is set, so anything that has to persist a
    /// value can capture a moment in time.
    var dockColor: DockColor? {
        guard let resolvedColor = nsColor else { return nil }
        return DockColor(nsColor: resolvedColor)
    }

    /// Named colors are resolved on every read so theme fields such as
    /// `accent` follow the user's current system tint.
    var nsColor: NSColor? {
        if let name, let resolved = Self.resolveNamedColor(name) {
            return resolved
        }
        if let r, let g, let b {
            return NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
        }
        return nil
    }

    static func resolveNamedColor(_ name: String) -> NSColor? {
        switch name.lowercased() {
        case "accent", "tint", "controlaccent": return .controlAccentColor
        case "label": return .labelColor
        case "secondarylabel": return .secondaryLabelColor
        case "tertiarylabel": return .tertiaryLabelColor
        case "quaternarylabel": return .quaternaryLabelColor
        case "systemblue": return .systemBlue
        case "systemred": return .systemRed
        case "systemgreen": return .systemGreen
        case "systemyellow": return .systemYellow
        case "systemorange": return .systemOrange
        case "systempurple": return .systemPurple
        case "systempink": return .systemPink
        case "systemteal": return .systemTeal
        case "systemindigo": return .systemIndigo
        case "systemmint":
            if #available(macOS 12.0, *) { return .systemMint }
            return .systemTeal
        case "systembrown": return .systemBrown
        case "systemgray": return .systemGray
        case "white": return .white
        case "black": return .black
        case "clear": return .clear
        default: return nil
        }
    }
}
