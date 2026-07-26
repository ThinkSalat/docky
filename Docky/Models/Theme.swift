//
//  Theme.swift
//  Docky
//
//  Codable representation of a `.dockytheme` bundle's `theme.json`
//  manifest. Every appearance field is optional so that partial
//  themes overlay cleanly: a field that is `nil` falls through to
//  the user's own preference (or the app default), per the layered
//  read path in `DockyPreferences`.
//
//  Image fields are *relative* paths into the bundle's `assets/`
//  directory. Absolute resolution happens at read time against
//  `ThemeManager.activeBundleURL` so a theme stays portable when
//  copied between machines.
//
//  Optional bundle-root files (not referenced by the manifest):
//    - `cover_image.png` (or `.jpg`/`.jpeg`): displayed by the Themes
//      settings pane as a rich preview. Convention over manifest
//      configuration, drop a file in with that name and it's picked
//      up automatically by `InstalledTheme.coverImageURL`.
//
//  Optional files inside `assets/` (also convention-only):
//    - `<bundle-id>.png` (or `.jpg`/`.jpeg`): per-app icon override.
//      When the theme is active, `effectiveAppIconOverrideURL` on
//      `DockyPreferences` falls back to this asset for any app whose
//      bundle identifier matches the filename, so a file named
//      `com.apple.Safari.png` automatically replaces Safari's icon
//      while the theme is in use.
//

import Foundation

/// Top-level manifest stored at `<bundle>/theme.json`.
nonisolated struct ThemeManifest: Codable, Equatable, Sendable {
    /// Bumped when the manifest format changes in a non-additive way.
    /// New optional fields don't require a bump, readers ignore
    /// unknown keys via `Codable`'s default behavior.
    let schemaVersion: Int

    /// Reverse-DNS id, doubles as the on-disk install folder name.
    /// Validated to match `[A-Za-z0-9._-]+` on import.
    let id: String

    let name: String
    let author: String?
    let version: String?
    let description: String?

    let appearance: ThemeAppearance

    /// Optional behavior overrides (sizing modes, default tile size, etc).
    /// Same layered-read semantics as `appearance`: a `nil` field falls
    /// through to the user's preference, and any user-overridden key
    /// stays on the user's value even while the theme is active.
    var behavior: ThemeBehavior?

    /// Layout-level injections, extra structural tiles a theme drops
    /// into the assembled dock. Lets a theme add a flexible spacer
    /// after the trailing divider so pinned apps pin-left while the
    /// trailing section flushes right (Windows feel), without the
    /// user having to wire it up manually.
    var layout: ThemeLayout?
}

nonisolated struct ThemeLayout: Codable, Equatable, Sendable {
    var insertions: [ThemeLayoutInsertion]?
}

nonisolated struct ThemeLayoutInsertion: Codable, Equatable, Sendable {
    /// Tile content to inject. Structural primitives: `"spacer"`,
    /// `"flexibleSpacer"`, `"divider"`. Widget kinds also accepted ,
    /// any raw value of `WidgetKind` (e.g. `"search"`, `"calendar"`,
    /// `"weather"`). Unknown values are silently skipped.
    var kind: String

    /// Place the new tile immediately after the tile whose id matches.
    /// `anchor` resolves first by exact tile id (e.g.
    /// `"divider:trailing"`, `"divider:running"`,
    /// `"pinned:com.apple.finder"`) and then by app bundle identifier
    /// (e.g. `"com.apple.Safari"`). At most one of `after` / `before`
    /// may be set; if both are set, `after` wins.
    var after: String?

    /// Place the new tile immediately before the matching tile.
    var before: String?

    /// Span for widget insertions. `1`, `2`, or `3`. Ignored for
    /// structural insertions (spacer / flexibleSpacer / divider).
    /// When unset, the widget's `WidgetCatalog` defaultSpan is used.
    var span: Int?
}

nonisolated struct ThemeBehavior: Codable, Equatable, Sendable {
    /// Raw value of `DockWindowAxisSizing` ("fitContent" or "fullAxis").
    var windowAxisSizing: String?
    /// Resting tile (icon) size in points.
    var tileSize: CGFloat?
    /// Magnified icon size in points; ignored when `< tileSize`.
    var largeSize: CGFloat?
    /// Whether magnification is on by default for this theme.
    var magnification: Bool?
    /// Whether to render the vertical divider that separates pinned
    /// apps from the running/recent zone. Themes that want a flat
    /// continuous taskbar (Windows look) set this to `false`.
    var showsActivePinnedSeparator: Bool?
}

nonisolated struct ThemeAppearance: Codable, Equatable, Sendable {
    var disablesGlassLook: Bool?
    var tile: ThemeTile?
    var window: ThemeWindow?
    var indicators: ThemeIndicators?
    /// Optional drop shadow applied behind every icon-bearing tile
    /// (apps, app folders, trash, launchpad, etc.). When `color` is
    /// nil no shadow renders regardless of the other fields.
    var iconShadow: ThemeShadow?
    /// Per-span widget-tile chrome overrides: each rendering size
    /// (1x / 2x / 3x) can opt into its own content padding and
    /// corner radius, or inherit the existing
    /// `tileChromeInset`/`tileClipShape` defaults when unset.
    var widgets: ThemeWidgets?
}

nonisolated struct ThemeWidgets: Codable, Equatable, Sendable {
    var oneX: ThemeWidgetSpan?
    var twoX: ThemeWidgetSpan?
    var threeX: ThemeWidgetSpan?
    var fourX: ThemeWidgetSpan?
}

nonisolated struct ThemeWidgetSpan: Codable, Equatable, Sendable {
    /// Inner padding between the tile bounds and the widget content.
    /// `0` makes the widget bleed all the way to the tile edge.
    var contentPadding: CGFloat?
    /// Override for the widget tile's corner radius. `0` produces a
    /// sharp-cornered chrome that fills the tile box completely.
    var cornerRadius: CGFloat?
    /// Theme-only escape hatch (no Settings UI): when `true`, this
    /// span's widget tiles ignore the theme's tile-level
    /// `iconPadding` so the widget can truly fill its tile box.
    /// Useful when a theme adds icon padding for chunky app tiles
    /// but wants 2x/3x widgets edge-to-edge.
    var ignoresAddedPaddings: Bool?
}

nonisolated struct ThemeTile: Codable, Equatable, Sendable {
    /// Raw value of `DockClipShape` (e.g. "rounded", "circle").
    var clipShape: String?
    var verticalPadding: CGFloat?
    var spacing: CGFloat?
    /// Extra padding applied inside each tile around the icon, so the
    /// icon renders smaller than its tile slot. Useful when a theme
    /// wants chunky tile boxes (Win10 taskbar feel) without shrinking
    /// the click target / layout cell.
    var iconPadding: CGFloat?
    /// How the tile reacts to mouse hover. Each field is optional so
    /// a theme can opt into just one effect (e.g. only `backgroundColor`).
    var hover: ThemeTileHover?
    /// Background drawn under every currently-running app tile.
    /// Independent of `hover`: both can be active simultaneously and
    /// the hover layer paints on top.
    var active: ThemeTileActive?
}

nonisolated struct ThemeTileActive: Codable, Equatable, Sendable {
    var backgroundColor: ThemeColor?
    var backgroundImage: String?
    var backgroundOpacity: CGFloat?
    var backgroundCornerRadius: CGFloat?
}

nonisolated struct ThemeTileHover: Codable, Equatable, Sendable {
    /// Multiplied into the tile's opacity while hovered.
    var opacity: CGFloat?
    /// Scale applied to the icon contents while hovered.
    var scale: CGFloat?
    /// Solid fill behind the tile when hovered. Ignored when
    /// `backgroundImage` resolves to an asset.
    var backgroundColor: ThemeColor?
    /// Asset-relative path to an image drawn behind the tile when hovered.
    var backgroundImage: String?
    /// Opacity multiplier applied to whichever background source
    /// (color or image) is active.
    var backgroundOpacity: CGFloat?
    /// Corner radius applied to the hover background's clipping rect.
    var backgroundCornerRadius: CGFloat?
}

nonisolated struct ThemeWindow: Codable, Equatable, Sendable {
    /// Raw value of `DockClipShape`.
    var clipShape: String?
    var cornerRadius: CGFloat?
    /// Per-corner overrides for `cornerRadius`. Each field that is set
    /// overrides only that corner; unset fields inherit the uniform
    /// `cornerRadius` value. Useful for "flush against the screen edge"
    /// looks (taskbar-style: top corners rounded, bottom corners 0).
    var cornerRadii: ThemeCornerValues?
    /// Per-edge padding between the panel and the chrome view. When
    /// any field is set it overrides that edge's default (2pt). Set
    /// to 0 to bleed the chrome to the panel edge; force-zero is
    /// applied automatically in full-axis mode regardless.
    var contentInsets: ThemeEdgeValues?
    /// Path relative to `<bundle>/`.
    var backgroundImage: String?
    /// Raw value of `DockBackgroundImageMode` ("fill" or "sprite").
    var backgroundImageMode: String?
    var tintColor: ThemeColor?
    var tintOpacity: CGFloat?
    /// Optional outline color drawn around the chrome's clip shape.
    /// When `nil` the default glass border (or no border, when glass
    /// is disabled) is preserved.
    var borderColor: ThemeColor?
    /// Stroke width in points. Ignored when `borderColor` is nil.
    var borderWidth: CGFloat?
}

nonisolated struct ThemeEdgeValues: Codable, Equatable, Sendable {
    var top: CGFloat?
    var leading: CGFloat?
    var bottom: CGFloat?
    var trailing: CGFloat?
}

nonisolated struct ThemeCornerValues: Codable, Equatable, Sendable {
    var topLeading: CGFloat?
    var topTrailing: CGFloat?
    var bottomLeading: CGFloat?
    var bottomTrailing: CGFloat?
}

nonisolated struct ThemeIndicators: Codable, Equatable, Sendable {
    /// Raw value of `DockTileIndicatorShape`.
    var shape: String?
    /// Path relative to `<bundle>/`.
    var image: String?
    var color: ThemeColor?
    var offset: CGFloat?
    var scale: CGFloat?
    var divider: ThemeDivider?
}

nonisolated struct ThemeDivider: Codable, Equatable, Sendable {
    /// Path relative to `<bundle>/`.
    var left: String?
    /// Path relative to `<bundle>/`.
    var right: String?
    /// Path relative to `<bundle>/`. Center divider, used when an
    /// asymmetric left/right pair isn't supplied.
    var center: String?
    var mirrorLeftOnRight: Bool?
    var paddingFraction: CGFloat?
    var offset: CGFloat?
    var imageScale: CGFloat?
    var opacity: CGFloat?
    /// Flat-color fill used when no divider image is supplied. When
    /// `nil` the divider falls back to SwiftUI's `.primary` color.
    var color: ThemeColor?
}

/// Color + radius + opacity triple. Used by `ThemeAppearance.iconShadow`
/// and easy to repurpose for any other drop-shadow appearance field
/// (e.g. text shadow, window shadow) without inventing another schema.
nonisolated struct ThemeShadow: Codable, Equatable, Sendable {
    var color: ThemeColor?
    var radius: CGFloat?
    var opacity: CGFloat?
}

nonisolated struct ThemeColor: Codable, Equatable, Sendable {
    /// Component-based variants set r/g/b (0…1). Named variants set
    /// `name` and may omit components entirely. Both are optional so
    /// either form decodes without bespoke `init(from:)`.
    var r: Double?
    var g: Double?
    var b: Double?

    /// Resolved live against the running system, so a theme referencing
    /// `"accent"` re-tints when the user changes their macOS accent.
    /// Supported names (case-insensitive):
    ///   `accent` / `tint` / `controlAccent`
    ///   `label`, `secondaryLabel`, `tertiaryLabel`, `quaternaryLabel`
    ///   `systemBlue`, `systemRed`, `systemGreen`, `systemYellow`,
    ///   `systemOrange`, `systemPurple`, `systemPink`, `systemTeal`,
    ///   `systemIndigo`, `systemMint`, `systemBrown`, `systemGray`
    ///   `white`, `black`, `clear`
    var name: String?

}
