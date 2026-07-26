//
//  TrashTileView.swift
//  Docky
//

import AppKit
import SwiftUI

struct TrashTileView: View {
    var isDropTarget: Bool = false
    @ObservedObject private var trash = TrashService.shared
    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        GeometryReader { proxy in
            let state: TrashIconState = trash.isEmpty ? .empty : .full
            let overrideURL = preferences.effectiveTrashIconOverrideURL(
                forState: state
            )
            CachedAsyncImageFile(
                url: overrideURL,
                placeholder: {
                    Image(nsImage: systemIcon(for: state))
                        .resizable()
                        .interpolation(.high)
                }
            ) { image in
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            }
                .aspectRatio(contentMode: .fit)
                .padding(overridePadding(in: proxy.size))
                .brightness(isDropTarget ? -0.35 : 0)
                .scaleEffect(isDropTarget ? 1.1 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDropTarget)
        }
    }

    private func overridePadding(in size: CGSize) -> CGFloat {
        let state: TrashIconState = trash.isEmpty ? .empty : .full
        guard preferences.effectiveTrashIconOverrideURL(forState: state) != nil else {
            return 0
        }
        return preferences.trashIconOverridePadding(forState: state) * min(size.width, size.height)
    }

    private func systemIcon(for state: TrashIconState) -> NSImage {
        return NSImage(named: state.systemImageName)
            ?? NSImage(named: TrashIconState.empty.systemImageName)
            ?? NSImage()
    }
}
