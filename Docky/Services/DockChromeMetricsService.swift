//
//  DockChromeMetricsService.swift
//  Docky
//
//  Live, magnification-aware totals used to size the dock chrome.
//  `TileContainerView` writes these as a byproduct of the walk it already
//  does for the anchor offset; `MainWindowView` reads them. Kept on its
//  own service so the writer (tile view) is NOT an observer — otherwise
//  every write would re-render the tile view it just measured.
//

import Combine
import CoreGraphics
import Foundation

struct DockChromeAxisGrowth: Equatable {
    var primary: CGFloat = 0
    var handoff: CGFloat = 0
}

final class DockChromeMetricsService: ObservableObject {
    static let shared = DockChromeMetricsService()

    /// Along-axis growth is tracked per visual surface. A single aggregate
    /// would make one capsule expand when the pointer magnifies a tile in
    /// the other capsule, visually bridging the detached Handoff dock.
    @Published private(set) var axisGrowth =
        DockChromeAxisGrowth()

    private init() {}

    func setAxisGrowth(
        primary: CGFloat,
        handoff: CGFloat
    ) {
        let next = DockChromeAxisGrowth(
            primary: primary,
            handoff: handoff
        )
        guard abs(axisGrowth.primary - next.primary) > 0.0001
            || abs(axisGrowth.handoff - next.handoff)
                > 0.0001 else {
            return
        }
        axisGrowth = next
    }
}
