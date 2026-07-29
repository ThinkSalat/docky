//
//  DockEditModeService.swift
//  Docky
//

import Combine
import Foundation
import CoreGraphics
import AppKit

enum DockEditPaletteItem: Equatable, Identifiable {
    case launchpad
    case startMenu
    case spacer
    case flexibleSpacer
    case divider
    case widget(ownerBundleIdentifier: String, kind: WidgetKind)
    case smartStack

    var id: String {
        switch self {
        case .launchpad:
            "launchpad"
        case .startMenu:
            "start-menu"
        case .spacer:
            "spacer"
        case .flexibleSpacer:
            "flexible-spacer"
        case .divider:
            "divider"
        case .widget(let ownerBundleIdentifier, let kind):
            "widget:\(ownerBundleIdentifier):\(kind.rawValue)"
        case .smartStack:
            "smart-stack"
        }
    }
}

struct DockEditPaletteDrag: Equatable {
    let item: DockEditPaletteItem
    let widgetSpan: TileSpan?
    let location: CGPoint
    let pasteboardToken: String
    let expectedProfileID: String
    let expectedRevision: UInt64
    let expectedSpaceGeneration: UInt64
}

enum DockEditDropSection: Equatable {
    case pinned
    case trailing
}

struct DockEditDropDestination: Equatable {
    let section: DockEditDropSection
    let index: Int
}

final class DockEditModeService: ObservableObject {
    static let shared = DockEditModeService()

    @Published private(set) var isActive = false
    @Published private(set) var paletteDrag: DockEditPaletteDrag?
    @Published var paletteDropDestination: DockEditDropDestination?
    private var paletteMouseReleasePoll:
        DispatchSourceTimer?

    private init() {}

    func enter() {
        isActive = true
    }

    func exit() {
        isActive = false
        endPaletteDrag()
    }

    func toggle() {
        isActive ? exit() : enter()
    }

    @discardableResult
    func updatePaletteDrag(
        item: DockEditPaletteItem,
        location: CGPoint,
        widgetSpan: TileSpan? = nil
    ) -> String? {
        guard allowsPaletteDrag(for: item) else {
            endPaletteDrag()
            return nil
        }
        isActive = true
        let drag: DockEditPaletteDrag
        if let existing = paletteDrag,
           existing.item == item,
           existing.widgetSpan == widgetSpan {
            drag = DockEditPaletteDrag(
                item: existing.item,
                widgetSpan: existing.widgetSpan,
                location: location,
                pasteboardToken:
                    existing.pasteboardToken,
                expectedProfileID:
                    existing.expectedProfileID,
                expectedRevision:
                    existing.expectedRevision,
                expectedSpaceGeneration:
                    existing.expectedSpaceGeneration
            )
        } else {
            drag = makePaletteDrag(
                item: item,
                widgetSpan: widgetSpan,
                location: location
            )
        }
        paletteDrag = drag
        armPaletteMouseReleaseCleanup(
            matching: drag.pasteboardToken
        )
        return drag.pasteboardToken
    }

    @discardableResult
    func beginPaletteDrag(
        item: DockEditPaletteItem,
        widgetSpan: TileSpan? = nil
    ) -> String? {
        guard allowsPaletteDrag(for: item) else {
            endPaletteDrag()
            return nil
        }
        isActive = true
        let drag = makePaletteDrag(
            item: item,
            widgetSpan: widgetSpan,
            location: .zero
        )
        paletteDrag = drag
        armPaletteMouseReleaseCleanup(
            matching: drag.pasteboardToken
        )
        return drag.pasteboardToken
    }

    func endPaletteDrag(matching pasteboardToken: String? = nil) {
        if let pasteboardToken,
           paletteDrag?.pasteboardToken != pasteboardToken {
            return
        }
        paletteDrag = nil
        paletteDropDestination = nil
        paletteMouseReleasePoll?.cancel()
        paletteMouseReleasePoll = nil
    }

    func hasCurrentPalettePayload(_ payload: String?) -> Bool {
        guard let payload,
              !payload.isEmpty,
              let paletteDrag,
              paletteDrag.pasteboardToken == payload else {
            return false
        }
        let profileService = ProfileService.shared
        return paletteDrag.expectedProfileID
                == profileService.activeProfileID
            && paletteDrag.expectedRevision
                == profileService.stateRevision
            && paletteDrag.expectedSpaceGeneration
                == DockSpaceInteractionEpoch.shared.generation
    }

    private func makePaletteDrag(
        item: DockEditPaletteItem,
        widgetSpan: TileSpan?,
        location: CGPoint
    ) -> DockEditPaletteDrag {
        let profileService = ProfileService.shared
        return DockEditPaletteDrag(
            item: item,
            widgetSpan: widgetSpan,
            location: location,
            pasteboardToken:
                "gt.quintero.Docky.palette.\(UUID().uuidString)",
            expectedProfileID:
                profileService.activeProfileID,
            expectedRevision:
                profileService.stateRevision,
            expectedSpaceGeneration:
                DockSpaceInteractionEpoch.shared.generation
        )
    }

    private func armPaletteMouseReleaseCleanup(
        matching pasteboardToken: String
    ) {
        paletteMouseReleasePoll?.cancel()
        let timer =
            DispatchSource.makeTimerSource(
                queue: .main
            )
        var sawPressed =
            (NSEvent.pressedMouseButtons & 1) != 0
        timer.schedule(
            deadline: .now() + 0.1,
            repeating: 0.1
        )
        timer.setEventHandler { [weak self] in
            let pressed =
                (NSEvent.pressedMouseButtons & 1) != 0
            if pressed {
                sawPressed = true
            } else if sawPressed {
                self?.endPaletteDrag(
                    matching: pasteboardToken
                )
            }
        }
        timer.resume()
        paletteMouseReleasePoll = timer
    }

    private func allowsPaletteDrag(
        for item: DockEditPaletteItem
    ) -> Bool {
        guard item == .startMenu else {
            return true
        }
        return StartMenuEnablementPolicy.allowsPaletteInsertion(
            isEnabled:
                DockyPreferences.shared.enablesStartMenuOverlay
        )
    }
}
