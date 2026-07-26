//
//  WidgetSettingsPanelController.swift
//  Docky
//

import AppKit
import SwiftUI

/// Borderless panel that can still become key so its text fields work.
private final class KeyableSettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WidgetSettingsPanelController: NSObject {
    static let shared = WidgetSettingsPanelController()

    private static let contentWidth: CGFloat = 320
    private static let maxContentHeight: CGFloat = 440
    private static let edgeGap: CGFloat = 8

    private var panel: KeyableSettingsPanel?
    private var currentTileID: String?
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var mainWindowInteractionLease: MainWindowInteractionLease?
    private var presentationGeneration = PresentationGeneration()

    private override init() { super.init() }

    /// `sourceFrame` is the tile's frame in MainWindow coordinates (SwiftUI `.global`).
    func present(widget: WidgetTile, tileID: String, sourceFrame: CGRect) {
        if currentTileID == tileID {
            dismiss()
            return
        }
        dismiss()
        let presentation = presentationGeneration.advance()

        let rootView = WidgetSettingsView(tileID: tileID, widget: widget) { [weak self] in
            self?.dismiss(ifCurrent: presentation)
        }
        .frame(width: Self.contentWidth)
        .fixedSize(horizontal: false, vertical: true)

        let hostingView = NSHostingView(rootView: AnyView(rootView))
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let contentHeight = min(max(fitting.height, 44), Self.maxContentHeight)
        let windowSize = CGSize(width: Self.contentWidth, height: contentHeight)

        let panel = KeyableSettingsPanel(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .mainMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        panel.delegate = self

        let origin = frameOrigin(for: windowSize, sourceFrame: sourceFrame)
        panel.setFrame(CGRect(origin: origin, size: windowSize), display: true)

        self.panel = panel
        self.currentTileID = tileID
        beginDockVisibilityHoldIfNeeded()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        installEventMonitors(for: presentation)
    }

    func dismiss() {
        _ = presentationGeneration.advance()
        removeEventMonitors()
        endDockVisibilityHoldIfNeeded()
        currentTileID = nil
        if let panel {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
    }

    private func dismiss(ifCurrent presentation: PresentationGeneration.Token) {
        guard presentationGeneration.isCurrent(presentation) else { return }
        dismiss()
    }

    private func installEventMonitors(
        for presentation: PresentationGeneration.Token
    ) {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss(ifCurrent: presentation)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.presentationGeneration.isCurrent(presentation) else {
                return event
            }

            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.dismiss(ifCurrent: presentation)
                    return nil
                }
                return event
            }

            if event.window !== self.panel {
                self.dismiss(ifCurrent: presentation)
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        globalClickMonitor = nil
        localEventMonitor = nil
    }

    private func beginDockVisibilityHoldIfNeeded() {
        guard mainWindowInteractionLease?.isActive != true,
              let mainWindow = NSApp.windows.compactMap({ $0 as? MainWindow }).first else {
            return
        }
        mainWindowInteractionLease = mainWindow.acquireInteractionLease()
    }

    private func endDockVisibilityHoldIfNeeded() {
        mainWindowInteractionLease = nil
    }

    private func frameOrigin(for size: CGSize, sourceFrame originalSourceFrame: CGRect) -> CGPoint {
        let sourceFrame = convertToScreen(originalSourceFrame)
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(sourceFrame) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return CGPoint(x: sourceFrame.midX - size.width / 2, y: sourceFrame.maxY)
        }

        switch dockEdge {
        case .maxY:
            let proposedY = sourceFrame.maxY + Self.edgeGap
            let y = proposedY + size.height <= visibleFrame.maxY
                ? proposedY
                : max(visibleFrame.minY, sourceFrame.minY - size.height - Self.edgeGap)
            let x = clamp(sourceFrame.midX - size.width / 2, lower: visibleFrame.minX, upper: visibleFrame.maxX - size.width)
            return CGPoint(x: x, y: y)
        case .minY:
            let proposedY = sourceFrame.minY - size.height - Self.edgeGap
            let y = proposedY >= visibleFrame.minY ? proposedY : sourceFrame.maxY + Self.edgeGap
            let x = clamp(sourceFrame.midX - size.width / 2, lower: visibleFrame.minX, upper: visibleFrame.maxX - size.width)
            return CGPoint(x: x, y: y)
        case .maxX:
            let proposedX = sourceFrame.maxX + Self.edgeGap
            let x = proposedX + size.width <= visibleFrame.maxX
                ? proposedX
                : max(visibleFrame.minX, sourceFrame.minX - size.width - Self.edgeGap)
            let y = clamp(sourceFrame.midY - size.height / 2, lower: visibleFrame.minY, upper: visibleFrame.maxY - size.height)
            return CGPoint(x: x, y: y)
        case .minX:
            let proposedX = sourceFrame.minX - size.width - Self.edgeGap
            let x = proposedX >= visibleFrame.minX ? proposedX : sourceFrame.maxX + Self.edgeGap
            let y = clamp(sourceFrame.midY - size.height / 2, lower: visibleFrame.minY, upper: visibleFrame.maxY - size.height)
            return CGPoint(x: x, y: y)
        @unknown default:
            return CGPoint(x: sourceFrame.midX - size.width / 2, y: sourceFrame.maxY)
        }
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private func convertToScreen(_ frame: CGRect) -> CGRect {
        guard let dockFrame = NSApp.windows.compactMap({ $0 as? MainWindow }).first?.frame else {
            return frame
        }
        return CGRect(
            x: dockFrame.minX + frame.minX,
            y: dockFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private var dockEdge: NSRectEdge {
        let prefs = DockyPreferences.shared
        let settings = DockSettingsService.shared
        switch prefs.windowPosition.resolved(systemOrientation: settings.orientation) {
        case .top: return .minY
        case .bottom: return .maxY
        case .left: return .maxX
        case .right: return .minX
        }
    }
}

extension WidgetSettingsPanelController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard let resigningPanel = notification.object as? NSWindow,
              resigningPanel === panel else {
            return
        }
        dismiss()
    }
}
