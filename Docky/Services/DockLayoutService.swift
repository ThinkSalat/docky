//
//  DockLayoutService.swift
//  Docky
//

import Combine
import CoreGraphics
import Foundation

enum DockDividerPositionClass {
    case left
    case center
    case right
}

struct DockChromeSurfaceLayout: Equatable {
    var primarySize: CGSize = .zero
    var handoffSize: CGSize = .zero
    var interDockGap: CGFloat = 0
    /// Along-axis displacement of the primary capsule's center from the
    /// panel center. Normally zero; becomes negative only when the
    /// accessory must use trailing screen space or full-axis mode reserves
    /// room for it.
    var primaryCenterOffset: CGFloat = 0
    var constrainsPrimaryAxis = false

    var hasHandoff: Bool {
        handoffSize.width > 0 && handoffSize.height > 0
    }

    func combinedSize(isVertical: Bool) -> CGSize {
        guard hasHandoff else { return primarySize }
        if isVertical {
            return CGSize(
                width: max(primarySize.width, handoffSize.width),
                height:
                    primarySize.height
                    + interDockGap
                    + handoffSize.height
            )
        }
        return CGSize(
            width:
                primarySize.width
                + interDockGap
                + handoffSize.width,
            height: max(primarySize.height, handoffSize.height)
        )
    }
}

final class DockLayoutService: ObservableObject {
    static let shared = DockLayoutService()

    @Published private(set) var contentScale: CGFloat = 1
    @Published private(set) var compactsWidgetsForOverflow = false
    @Published private(set) var chromeSurfaces =
        DockChromeSurfaceLayout()
    @Published private(set) var tileCanvasFrame: CGRect = .zero

    private init() {}

    func setContentScale(_ scale: CGFloat) {
        let clampedScale = min(max(scale, 0), 1)
        guard abs(contentScale - clampedScale) > 0.0001 else { return }
        contentScale = clampedScale
    }

    func setCompactsWidgetsForOverflow(_ compactsWidgetsForOverflow: Bool) {
        guard self.compactsWidgetsForOverflow != compactsWidgetsForOverflow else { return }
        self.compactsWidgetsForOverflow = compactsWidgetsForOverflow
    }

    func setChromeSurfaces(
        _ chromeSurfaces: DockChromeSurfaceLayout
    ) {
        guard !approximatelyEqual(
            self.chromeSurfaces,
            chromeSurfaces
        ) else {
            return
        }
        self.chromeSurfaces = chromeSurfaces
    }

    func setTileCanvasFrame(_ frame: CGRect) {
        guard abs(tileCanvasFrame.minX - frame.minX) > 0.0001
            || abs(tileCanvasFrame.minY - frame.minY) > 0.0001
            || abs(tileCanvasFrame.width - frame.width) > 0.0001
            || abs(tileCanvasFrame.height - frame.height) > 0.0001 else {
            return
        }
        tileCanvasFrame = frame
    }

    func scaled(_ value: CGFloat) -> CGFloat {
        value * contentScale
    }

    private func approximatelyEqual(
        _ lhs: DockChromeSurfaceLayout,
        _ rhs: DockChromeSurfaceLayout
    ) -> Bool {
        approximatelyEqual(lhs.primarySize, rhs.primarySize)
            && approximatelyEqual(lhs.handoffSize, rhs.handoffSize)
            && abs(lhs.interDockGap - rhs.interDockGap) <= 0.0001
            && abs(
                lhs.primaryCenterOffset
                    - rhs.primaryCenterOffset
            ) <= 0.0001
            && lhs.constrainsPrimaryAxis
                == rhs.constrainsPrimaryAxis
    }

    private func approximatelyEqual(
        _ lhs: CGSize,
        _ rhs: CGSize
    ) -> Bool {
        abs(lhs.width - rhs.width) <= 0.0001
            && abs(lhs.height - rhs.height) <= 0.0001
    }
}
