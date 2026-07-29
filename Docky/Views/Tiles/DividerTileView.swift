//
//  DividerTileView.swift
//  Docky
//

import AppKit
import SwiftUI

struct DividerTileView: View {
    let tileID: String
    private let dockSettings = DockSettingsService.shared
    @ObservedObject private var layout = DockLayoutService.shared
    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        GeometryReader { proxy in
            divider(globalFrame: proxy.frame(in: .global))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: dividerOffsetVector.width, y: dividerOffsetVector.height)
                .background(.black.opacity(0.001))
                .contentShape(Path(CGRect(origin: .zero, size: proxy.size)))
                .background {
                    if !isPinnedCustomDivider {
                        ContextActionMenuPresenter { _ in
                            dividerContextActions
                        }
                    }
                }
        }
    }

    private var dividerOffsetVector: CGSize {
        let amount = preferences.effectiveDividerOffset
        if position.isVertical {
            return CGSize(width: amount, height: 0)
        } else {
            return CGSize(width: 0, height: -amount)
        }
    }

    private var dividerContextActions: [ContextAction] {
        [
            .action(preferences.autohidesWindow ? "Turn Hiding Off" : "Turn Hiding On") {
                preferences.autohidesWindow.toggle()
            },
            .action(
                dockSettings.effectiveMagnification
                    ? "Turn Magnification Off"
                    : "Turn Magnification On"
            ) {
                dockSettings.setMagnification(
                    !dockSettings.effectiveMagnification
                )
            },
            .submenu(String(localized: "Position on Screen"), children: positionActions),
            .divider,
//            .action("Smart Organize Pinned Items") {
//                TileStore.shared.smartOrganizePinnedItems()
//            },
            .divider,
            .action(String(localized: "Edit Dock...")) {
                DockEditModeService.shared.enter()
            },
            .divider,
            .submenu(String(localized: "Troubleshoot"), children: troubleshootActions),
            .action(String(localized: "Send Feedback...")) {
                SettingsNavigator.shared.requestPane(id: "feedback")
            },
            .divider,
            .action(String(localized: "About Docky")) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            },
            .action(String(localized: "Settings...")) {
                (NSApp.delegate as? AppDelegate)?.showSettingsWindow(nil)
            },
            .divider,
            .action(String(localized: "Quit Docky"), isDestructive: true) {
                NSApp.terminate(nil)
            }
        ]
    }

    private var positionActions: [ContextAction] {
        DockWindowPosition.allCases.map { position in
            .action(position.title, isOn: preferences.windowPosition == position) {
                preferences.windowPosition = position
            }
        }
    }

    private var troubleshootActions: [ContextAction] {
        [
            .action(String(localized: "Refresh System Dock Data")) {
                DockSettingsService.shared
                    .refreshSystemDockSnapshot()
                TileStore.shared.refresh()
            }
        ]
    }

    @ViewBuilder
    private func divider(globalFrame: CGRect) -> some View {
        let positionClass = positionClass(globalFrame: globalFrame)

        // Flat divider color falls through user → theme → `.primary`.
        let fillColor: Color = preferences.effectiveDividerColor
            .map(Color.init(nsColor:)) ?? Color.primary

        Group {
            if let resolvedImage = preferences.resolvedDividerImage(
                forPositionClass: positionClass
            ) {
                CachedAsyncImageFile(
                    url: resolvedImage.url,
                    placeholder: {
                        standardDivider(fillColor: fillColor)
                    }
                ) { nsImage in
                    customImageDivider(
                        nsImage: nsImage,
                        mirrored: resolvedImage.mirrored
                    )
                }
            } else {
                standardDivider(fillColor: fillColor)
            }
        }
        .opacity(min(max(preferences.effectiveDividerOpacity, 0), 1))
    }

    @ViewBuilder
    private func standardDivider(fillColor: Color) -> some View {
        if position.isVertical {
            Rectangle()
                .fill(fillColor)
                .frame(height: 1)
                .padding(.horizontal, lineInset)
        } else {
            Rectangle()
                .fill(fillColor)
                .frame(width: 1)
                .padding(.vertical, lineInset)
        }
    }

    @ViewBuilder
    private func customImageDivider(nsImage: NSImage, mirrored: Bool) -> some View {
        let imageScale = max(0.25, preferences.effectiveDividerImageScale)
        let image = Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(x: (mirrored ? -1 : 1) * imageScale, y: imageScale)

        if position.isVertical {
            // Lay the image out in the rotated coordinate system so
            // `aspectRatio(.fit)` sees the dimensions it will occupy *after*
            // the 90° spin. Without this, fit operates on the pre-rotation
            // box and the rotated image under-fills the slot's cross axis.
            GeometryReader { proxy in
                image
                    .frame(width: proxy.size.height, height: proxy.size.width)
                    .rotationEffect(.degrees(90))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .padding(.horizontal, lineInset)
        } else {
            image.padding(.vertical, lineInset)
        }
    }

    private func positionClass(globalFrame: CGRect) -> DockDividerPositionClass {
        let canvas = layout.tileCanvasFrame
        guard canvas.width > 0, canvas.height > 0 else { return .center }

        let relative: CGFloat
        if position.isVertical {
            relative = (globalFrame.midY - canvas.minY) / canvas.height
        } else {
            relative = (globalFrame.midX - canvas.minX) / canvas.width
        }

        switch relative {
        case ..<(1.0 / 3.0):
            return .left
        case (2.0 / 3.0)...:
            return .right
        default:
            return .center
        }
    }

    private var lineInset: CGFloat {
        let fraction = min(max(preferences.effectiveDividerPaddingFraction, 0), 0.5)
        return layout.scaled(dockSettings.effectiveTileSize) * fraction
    }

    private var position: ResolvedDockWindowPosition {
        preferences.windowPosition.resolved(systemOrientation: dockSettings.orientation)
    }

    private var isPinnedCustomDivider: Bool {
        tileID.hasPrefix("pinned:")
    }
}
