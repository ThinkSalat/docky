//
//  ThemeManifestPolicy.swift
//  Docky
//
//  Semantic validation for data-only theme manifests.
//

import Foundation

nonisolated enum ThemeManifestValidationError:
    Error,
    Equatable,
    LocalizedError {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case invalidIdentifier
    case missingName
    case stringTooLong(field: String, maximumBytes: Int)
    case tooManyLayoutInsertions(maximum: Int)
    case unsupportedValue(field: String)
    case invalidNumber(field: String)
    case invalidAssetPath(field: String)
    case incompleteColor(field: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "Theme schema \(found) is unsupported by schema \(supported)."
        case .invalidIdentifier:
            return "The theme identifier is invalid."
        case .missingName:
            return "The theme name is empty."
        case .stringTooLong(let field, let maximumBytes):
            return "The theme's \(field) exceeds \(maximumBytes) bytes."
        case .tooManyLayoutInsertions(let maximum):
            return "The theme contains more than \(maximum) layout insertions."
        case .unsupportedValue(let field):
            return "The theme contains an unsupported \(field) value."
        case .invalidNumber(let field):
            return "The theme contains an invalid \(field) number."
        case .invalidAssetPath(let field):
            return "The theme contains an invalid \(field) asset path."
        case .incompleteColor(let field):
            return "The theme's \(field) color must provide all RGB components."
        }
    }
}

nonisolated enum ThemeManifestPolicy {
    static let supportedSchemaVersion = 1
    static let maximumLayoutInsertions = 128

    private static let structuralInsertionKinds: Set<String> = [
        "spacer",
        "flexibleSpacer",
        "divider",
    ]
    private static let widgetInsertionKinds: Set<String> = [
        "calendar",
        "calendarDate",
        "reminders",
        "batteries",
        "systemStatus",
        "nowPlaying",
        "weather",
        "search",
        "photoFrame",
    ]
    private static let namedColors: Set<String> = [
        "accent",
        "tint",
        "controlaccent",
        "label",
        "secondarylabel",
        "tertiarylabel",
        "quaternarylabel",
        "systemblue",
        "systemred",
        "systemgreen",
        "systemyellow",
        "systemorange",
        "systempurple",
        "systempink",
        "systemteal",
        "systemindigo",
        "systemmint",
        "systembrown",
        "systemgray",
        "white",
        "black",
        "clear",
    ]

    static func validate(_ manifest: ThemeManifest) throws {
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw ThemeManifestValidationError.unsupportedSchemaVersion(
                found: manifest.schemaVersion,
                supported: supportedSchemaVersion
            )
        }
        guard ThemeArchivePolicy.isValidThemeID(manifest.id) else {
            throw ThemeManifestValidationError.invalidIdentifier
        }
        guard !manifest.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ThemeManifestValidationError.missingName
        }
        try validateString(manifest.name, field: "name", maximumBytes: 256)
        try validateString(
            manifest.author,
            field: "author",
            maximumBytes: 256
        )
        try validateString(
            manifest.version,
            field: "version",
            maximumBytes: 128
        )
        try validateString(
            manifest.description,
            field: "description",
            maximumBytes: 8_192
        )

        try validateBehavior(manifest.behavior)
        try validateLayout(manifest.layout)
        try validateAppearance(manifest.appearance)
    }

    private static func validateBehavior(
        _ behavior: ThemeBehavior?
    ) throws {
        guard let behavior else { return }
        try validateEnum(
            behavior.windowAxisSizing,
            allowed: ["fitContent", "fullAxis"],
            field: "windowAxisSizing"
        )
        try validateNumber(
            behavior.tileSize,
            in: 8...512,
            field: "tileSize"
        )
        try validateNumber(
            behavior.largeSize,
            in: 8...1_024,
            field: "largeSize"
        )
        if let tileSize = behavior.tileSize,
           let largeSize = behavior.largeSize,
           largeSize < tileSize {
            throw ThemeManifestValidationError.invalidNumber(
                field: "largeSize"
            )
        }
    }

    private static func validateLayout(_ layout: ThemeLayout?) throws {
        guard let insertions = layout?.insertions else { return }
        guard insertions.count <= maximumLayoutInsertions else {
            throw ThemeManifestValidationError.tooManyLayoutInsertions(
                maximum: maximumLayoutInsertions
            )
        }

        let allowedKinds =
            structuralInsertionKinds.union(widgetInsertionKinds)
        for insertion in insertions {
            guard allowedKinds.contains(insertion.kind) else {
                throw ThemeManifestValidationError.unsupportedValue(
                    field: "layout.kind"
                )
            }
            guard insertion.after == nil || insertion.before == nil else {
                throw ThemeManifestValidationError.unsupportedValue(
                    field: "layout.anchor"
                )
            }
            try validateString(
                insertion.after,
                field: "layout.after",
                maximumBytes: 1_024,
                allowEmpty: false
            )
            try validateString(
                insertion.before,
                field: "layout.before",
                maximumBytes: 1_024,
                allowEmpty: false
            )
            if structuralInsertionKinds.contains(insertion.kind) {
                guard insertion.span == nil else {
                    throw ThemeManifestValidationError.unsupportedValue(
                        field: "layout.span"
                    )
                }
            } else if let span = insertion.span,
                      !(1...4).contains(span) {
                throw ThemeManifestValidationError.unsupportedValue(
                    field: "layout.span"
                )
            }
        }
    }

    private static func validateAppearance(
        _ appearance: ThemeAppearance
    ) throws {
        if let tile = appearance.tile {
            try validateEnum(
                tile.clipShape,
                allowed: ["rounded", "circle"],
                field: "tile.clipShape"
            )
            try validateNumber(
                tile.verticalPadding,
                in: 0...256,
                field: "tile.verticalPadding"
            )
            try validateNumber(
                tile.spacing,
                in: 0...256,
                field: "tile.spacing"
            )
            try validateNumber(
                tile.iconPadding,
                in: 0...256,
                field: "tile.iconPadding"
            )
            try validateHover(tile.hover)
            try validateActive(tile.active)
        }

        if let window = appearance.window {
            try validateWindow(window)
        }
        if let indicators = appearance.indicators {
            try validateIndicators(indicators)
        }
        if let shadow = appearance.iconShadow {
            try validateColor(shadow.color, field: "iconShadow.color")
            try validateNumber(
                shadow.radius,
                in: 0...512,
                field: "iconShadow.radius"
            )
            try validateNumber(
                shadow.opacity,
                in: 0...1,
                field: "iconShadow.opacity"
            )
        }
        if let widgets = appearance.widgets {
            for (field, span) in [
                ("widgets.oneX", widgets.oneX),
                ("widgets.twoX", widgets.twoX),
                ("widgets.threeX", widgets.threeX),
                ("widgets.fourX", widgets.fourX),
            ] {
                try validateWidgetSpan(span, field: field)
            }
        }
    }

    private static func validateHover(_ hover: ThemeTileHover?) throws {
        guard let hover else { return }
        try validateNumber(
            hover.opacity,
            in: 0...1,
            field: "tile.hover.opacity"
        )
        try validateNumber(
            hover.scale,
            in: 0.1...8,
            field: "tile.hover.scale"
        )
        try validateColor(
            hover.backgroundColor,
            field: "tile.hover.backgroundColor"
        )
        try validateAssetPath(
            hover.backgroundImage,
            field: "tile.hover.backgroundImage"
        )
        try validateNumber(
            hover.backgroundOpacity,
            in: 0...1,
            field: "tile.hover.backgroundOpacity"
        )
        try validateNumber(
            hover.backgroundCornerRadius,
            in: 0...1_024,
            field: "tile.hover.backgroundCornerRadius"
        )
    }

    private static func validateActive(_ active: ThemeTileActive?) throws {
        guard let active else { return }
        try validateColor(
            active.backgroundColor,
            field: "tile.active.backgroundColor"
        )
        try validateAssetPath(
            active.backgroundImage,
            field: "tile.active.backgroundImage"
        )
        try validateNumber(
            active.backgroundOpacity,
            in: 0...1,
            field: "tile.active.backgroundOpacity"
        )
        try validateNumber(
            active.backgroundCornerRadius,
            in: 0...1_024,
            field: "tile.active.backgroundCornerRadius"
        )
    }

    private static func validateWindow(_ window: ThemeWindow) throws {
        try validateEnum(
            window.clipShape,
            allowed: ["rounded", "circle"],
            field: "window.clipShape"
        )
        try validateNumber(
            window.cornerRadius,
            in: 0...1_024,
            field: "window.cornerRadius"
        )
        if let corners = window.cornerRadii {
            for (field, value) in [
                ("window.cornerRadii.topLeading", corners.topLeading),
                ("window.cornerRadii.topTrailing", corners.topTrailing),
                ("window.cornerRadii.bottomLeading", corners.bottomLeading),
                ("window.cornerRadii.bottomTrailing", corners.bottomTrailing),
            ] {
                try validateNumber(value, in: 0...1_024, field: field)
            }
        }
        if let insets = window.contentInsets {
            for (field, value) in [
                ("window.contentInsets.top", insets.top),
                ("window.contentInsets.leading", insets.leading),
                ("window.contentInsets.bottom", insets.bottom),
                ("window.contentInsets.trailing", insets.trailing),
            ] {
                try validateNumber(value, in: 0...1_024, field: field)
            }
        }
        try validateAssetPath(
            window.backgroundImage,
            field: "window.backgroundImage"
        )
        try validateEnum(
            window.backgroundImageMode,
            allowed: ["fill", "sprite"],
            field: "window.backgroundImageMode"
        )
        try validateColor(window.tintColor, field: "window.tintColor")
        try validateNumber(
            window.tintOpacity,
            in: 0...1,
            field: "window.tintOpacity"
        )
        try validateColor(window.borderColor, field: "window.borderColor")
        try validateNumber(
            window.borderWidth,
            in: 0...128,
            field: "window.borderWidth"
        )
    }

    private static func validateIndicators(
        _ indicators: ThemeIndicators
    ) throws {
        try validateEnum(
            indicators.shape,
            allowed: ["none", "dot", "pill", "underline", "image"],
            field: "indicators.shape"
        )
        try validateAssetPath(
            indicators.image,
            field: "indicators.image"
        )
        try validateColor(indicators.color, field: "indicators.color")
        try validateNumber(
            indicators.offset,
            in: -4_096...4_096,
            field: "indicators.offset"
        )
        try validateNumber(
            indicators.scale,
            in: 0...16,
            field: "indicators.scale"
        )

        guard let divider = indicators.divider else { return }
        try validateAssetPath(divider.left, field: "divider.left")
        try validateAssetPath(divider.right, field: "divider.right")
        try validateAssetPath(divider.center, field: "divider.center")
        try validateNumber(
            divider.paddingFraction,
            in: 0...1,
            field: "divider.paddingFraction"
        )
        try validateNumber(
            divider.offset,
            in: -4_096...4_096,
            field: "divider.offset"
        )
        try validateNumber(
            divider.imageScale,
            in: 0...16,
            field: "divider.imageScale"
        )
        try validateNumber(
            divider.opacity,
            in: 0...1,
            field: "divider.opacity"
        )
        try validateColor(divider.color, field: "divider.color")
    }

    private static func validateWidgetSpan(
        _ span: ThemeWidgetSpan?,
        field: String
    ) throws {
        guard let span else { return }
        try validateNumber(
            span.contentPadding,
            in: 0...1_024,
            field: "\(field).contentPadding"
        )
        try validateNumber(
            span.cornerRadius,
            in: 0...1_024,
            field: "\(field).cornerRadius"
        )
    }

    private static func validateColor(
        _ color: ThemeColor?,
        field: String
    ) throws {
        guard let color else { return }
        let components = [color.r, color.g, color.b]
        let presentCount = components.compactMap { $0 }.count
        guard presentCount == 0 || presentCount == 3 else {
            throw ThemeManifestValidationError.incompleteColor(field: field)
        }
        for component in components.compactMap({ $0 }) {
            guard component.isFinite, (0...1).contains(component) else {
                throw ThemeManifestValidationError.invalidNumber(
                    field: field
                )
            }
        }
        if let name = color.name {
            try validateString(
                name,
                field: "\(field).name",
                maximumBytes: 64,
                allowEmpty: false
            )
            guard namedColors.contains(name.lowercased()) else {
                throw ThemeManifestValidationError.unsupportedValue(
                    field: "\(field).name"
                )
            }
        }
        guard presentCount == 3 || color.name != nil else {
            throw ThemeManifestValidationError.incompleteColor(field: field)
        }
    }

    private static func validateAssetPath(
        _ path: String?,
        field: String
    ) throws {
        guard let path else { return }
        guard path.utf8.count <= 4_096,
              ThemeArchivePolicy.normalizedAssetPath(path) != nil else {
            throw ThemeManifestValidationError.invalidAssetPath(field: field)
        }
    }

    private static func validateEnum(
        _ value: String?,
        allowed: Set<String>,
        field: String
    ) throws {
        guard let value else { return }
        guard allowed.contains(value) else {
            throw ThemeManifestValidationError.unsupportedValue(field: field)
        }
    }

    private static func validateNumber(
        _ value: CGFloat?,
        in range: ClosedRange<Double>,
        field: String
    ) throws {
        guard let value else { return }
        let number = Double(value)
        guard number.isFinite, range.contains(number) else {
            throw ThemeManifestValidationError.invalidNumber(field: field)
        }
    }

    private static func validateString(
        _ value: String?,
        field: String,
        maximumBytes: Int,
        allowEmpty: Bool = true
    ) throws {
        guard let value else { return }
        guard allowEmpty || !value.isEmpty else {
            throw ThemeManifestValidationError.unsupportedValue(field: field)
        }
        guard value.utf8.count <= maximumBytes else {
            throw ThemeManifestValidationError.stringTooLong(
                field: field,
                maximumBytes: maximumBytes
            )
        }
    }
}
