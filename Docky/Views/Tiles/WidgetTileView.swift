//
//  WidgetTileView.swift
//  Docky
//

import SwiftUI

struct WidgetTileView: View {
    let tile: WidgetTile
    let cornerRadius: CGFloat
    let renderedSpan: TileSpan
    let isWithinStack: Bool
    var isExpanded: Bool = false
    var isExpandedPreviewOpen: Bool = false

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif

        switch tile.kind {
        case .calendar, .calendarDate:
            CalendarWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .reminders:
            RemindersWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .batteries:
            BatteriesWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .systemStatus:
            SystemStatusWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .nowPlaying:
            NowPlayingWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .weather:
            WeatherWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .search:
            SearchWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .photoFrame:
            PhotoFrameWidgetTileView(
                tile: tile,
                cornerRadius: cornerRadius,
                renderedSpan: renderedSpan,
                isWithinStack: isWithinStack,
                isExpanded: isExpanded,
                isExpandedPreviewOpen: isExpandedPreviewOpen
            )
        case .external:
            ExternalWidgetDisabledTileView()
            .dockyGlass(.regular, in: .rect(cornerRadius: cornerRadius))
            .dockyGlassBorder(in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// Persisted external-widget tiles remain visible but inert. This keeps profile
/// data round-trippable without ever invoking the legacy in-process plugin ABI.
private struct ExternalWidgetDisabledTileView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "lock.shield")
                .font(.title3)
            Text("External widget disabled")
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.secondary)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("External widget disabled for security")
    }
}
