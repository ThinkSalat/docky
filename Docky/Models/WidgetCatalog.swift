//
//  WidgetCatalog.swift
//  Docky
//

import Foundation

nonisolated enum WidgetOwnerBundleIdentifiers {
    nonisolated static let calendar = "com.apple.iCal"
    nonisolated static let reminders = "com.apple.reminders"
    nonisolated static let batteries = "gt.quintero.Docky.batteries"
    nonisolated static let systemStatus = "gt.quintero.Docky.system-status"
    nonisolated static let weather = "gt.quintero.Docky.weather"
    nonisolated static let genericNowPlaying =
        "gt.quintero.Docky.now-playing"
    nonisolated static let search = "gt.quintero.Docky.search"
    nonisolated static let photoFrame = "gt.quintero.Docky.photo-frame"
}

nonisolated struct WidgetRegistration:
    Equatable,
    Identifiable,
    Sendable {
    let kind: WidgetKind
    let ownerBundleIdentifier: String
    let defaultSpan: TileSpan
    let includesInPalette: Bool
    let includesInSmartStack: Bool

    nonisolated init(
        kind: WidgetKind,
        ownerBundleIdentifier: String,
        defaultSpan: TileSpan,
        includesInPalette: Bool,
        includesInSmartStack: Bool
    ) {
        self.kind = kind
        self.ownerBundleIdentifier = ownerBundleIdentifier
        self.defaultSpan = defaultSpan
        self.includesInPalette = includesInPalette
        self.includesInSmartStack = includesInSmartStack
    }

    nonisolated var id: String {
        "\(ownerBundleIdentifier):\(kind.rawValue)"
    }

    @MainActor
    func makeTile(span: TileSpan? = nil) -> WidgetTile {
        WidgetTile(
            identifier: id,
            title: kind.title,
            kind: kind,
            ownerBundleIdentifier: ownerBundleIdentifier,
            span: span ?? defaultSpan
        )
    }
}

nonisolated enum WidgetCatalog {
    nonisolated static let calendar = WidgetRegistration(
        kind: .calendar,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.calendar,
        defaultSpan: .three,
        includesInPalette: true,
        includesInSmartStack: true
    )

    nonisolated static let reminders = WidgetRegistration(
        kind: .reminders,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.reminders,
        defaultSpan: .three,
        includesInPalette: true,
        includesInSmartStack: true
    )

    nonisolated static let calendarDate = WidgetRegistration(
        kind: .calendarDate,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.calendar,
        defaultSpan: .one,
        includesInPalette: false,
        includesInSmartStack: false
    )

    nonisolated static let batteries = WidgetRegistration(
        kind: .batteries,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.batteries,
        defaultSpan: .three,
        includesInPalette: true,
        includesInSmartStack: true
    )

    nonisolated static let systemStatus = WidgetRegistration(
        kind: .systemStatus,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.systemStatus,
        defaultSpan: .three,
        includesInPalette: true,
        includesInSmartStack: true
    )

    nonisolated static let weather = WidgetRegistration(
        kind: .weather,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.weather,
        defaultSpan: .three,
        includesInPalette: true,
        includesInSmartStack: true
    )

    nonisolated static let genericNowPlaying = WidgetRegistration(
        kind: .nowPlaying,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.genericNowPlaying,
        defaultSpan: .three,
        includesInPalette: true,
        includesInSmartStack: false
    )

    nonisolated static let search = WidgetRegistration(
        kind: .search,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.search,
        defaultSpan: .two,
        // Theme-only widget: kept out of the dock editor palette so
        // it can't be dragged in manually. Themes can still inject it
        // via `layout.insertions` when widget injection lands.
        includesInPalette: false,
        includesInSmartStack: false
    )

    nonisolated static let photoFrame = WidgetRegistration(
        kind: .photoFrame,
        ownerBundleIdentifier: WidgetOwnerBundleIdentifiers.photoFrame,
        defaultSpan: .two,
        includesInPalette: true,
        includesInSmartStack: false
    )

    nonisolated static let builtInRegistrations: [WidgetRegistration] = [
        calendar,
        calendarDate,
        reminders,
        batteries,
        systemStatus,
        weather,
        genericNowPlaying,
        search,
        photoFrame,
    ]

    /// Only built-in registrations are executable. Legacy external-widget
    /// records remain in profiles but are never added to the palette.
    nonisolated static var staticRegistrations: [WidgetRegistration] {
        builtInRegistrations
    }

    nonisolated static var paletteRegistrations: [WidgetRegistration] {
        staticRegistrations.filter(\.includesInPalette)
    }

    nonisolated static var smartStackRegistrations: [WidgetRegistration] {
        staticRegistrations.filter(\.includesInSmartStack)
    }

    /// Owner bundle identifiers that are *visible* in a freshly-inserted
    /// smart stack by default. Anything in `smartStackRegistrations`
    /// outside this set is hidden until the user toggles it on.
    /// Now-Playing widgets are discovered dynamically and aren't part
    /// of `smartStackRegistrations`, so they appear automatically as
    /// soon as a supported media app starts playing.
    nonisolated static let
        defaultVisibleSmartStackOwnerBundleIdentifiers: Set<String> = [
        WidgetOwnerBundleIdentifiers.calendar,
        WidgetOwnerBundleIdentifiers.weather,
    ]

    /// Materialized "hidden" list — the inverse of
    /// `defaultVisibleSmartStackOwnerBundleIdentifiers` — formatted as
    /// the `hiddenWidgetOwnerBundleIdentifiers` argument the
    /// persistence layer expects when creating a new smart stack item.
    nonisolated static let
        defaultHiddenSmartStackOwnerBundleIdentifiers: [String] =
        smartStackRegistrations
            .map(\.ownerBundleIdentifier)
            .filter { !defaultVisibleSmartStackOwnerBundleIdentifiers.contains($0) }
}
