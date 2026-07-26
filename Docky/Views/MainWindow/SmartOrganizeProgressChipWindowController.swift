//
//  SmartOrganizeProgressChipWindowController.swift
//  Docky
//

import AppKit
import Combine
import SwiftUI

final class SmartOrganizeProgressChipWindowController: NSWindowController {
    private weak var mainWindow: MainWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var mainWindowInteractionLease: MainWindowInteractionLease?
    private let animationDuration: TimeInterval = 0.16
    private let chipGap: CGFloat = 10
    private let preferences = DockyPreferences.shared
    private let dockSettings = DockSettingsService.shared
    private let hostingController = NSHostingController(rootView: SmartOrganizeProgressChipView())

    init(mainWindow: MainWindow) {
        self.mainWindow = mainWindow

        let chipWindow = SmartOrganizeProgressChipWindow()
        chipWindow.contentViewController = hostingController

        super.init(window: chipWindow)

        prepareWindow()
        observeProgressPresentation()
        observeMainWindow()
        observeSpaceBehavior()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func prepareWindow() {
        guard let window else { return }
        window.collectionBehavior = preferences.windowSpaceBehavior.collectionBehavior(includesFullScreenAuxiliary: true)
        configureHiddenWindowState()
        updateFrame()
        window.orderFront(nil)
    }

    private func observeProgressPresentation() {
        SmartOrganizeProgressService.shared.$isPresented
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPresented in
                guard let self else { return }
                if isPresented {
                    self.presentChip()
                } else {
                    self.dismissChip()
                }
            }
            .store(in: &cancellables)

        SmartOrganizeProgressService.shared.$message
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFrame()
            }
            .store(in: &cancellables)
    }

    private func observeMainWindow() {
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: mainWindow)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: mainWindow))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: mainWindow))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFrame()
            }
            .store(in: &cancellables)
    }

    private func observeSpaceBehavior() {
        observeChanges { [weak self] in
            let behavior = DockyPreferences.shared.windowSpaceBehavior
            self?.window?.collectionBehavior = behavior.collectionBehavior(includesFullScreenAuxiliary: true)
        }
        .store(in: &cancellables)
    }

    private func presentChip() {
        guard let window else { return }
        updateFrame()
        beginMainWindowInteraction()
        window.orderFront(nil)
        animateWindowAlpha(to: 1)
    }

    private func dismissChip() {
        animateWindowAlpha(to: 0) { [weak self] in
            self?.endMainWindowInteraction()
        }
    }

    private func updateFrame() {
        guard let window, let mainWindow else { return }
        hostingController.view.layoutSubtreeIfNeeded()
        let contentSize = hostingController.view.fittingSize
        let frameSize = NSSize(width: max(contentSize.width, 220), height: max(contentSize.height, 34))
        let screenVisibleFrame = mainWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard !screenVisibleFrame.isEmpty else { return }
        let position = preferences.windowPosition.resolved(systemOrientation: dockSettings.orientation)

        let origin: CGPoint
        switch position {
        case .top:
            origin = CGPoint(
                x: mainWindow.frame.midX - frameSize.width / 2,
                y: mainWindow.frame.minY - frameSize.height - chipGap
            )
        case .left:
            origin = CGPoint(
                x: mainWindow.frame.maxX + chipGap,
                y: mainWindow.frame.midY - frameSize.height / 2
            )
        case .right:
            origin = CGPoint(
                x: mainWindow.frame.minX - frameSize.width - chipGap,
                y: mainWindow.frame.midY - frameSize.height / 2
            )
        case .bottom:
            origin = CGPoint(
                x: mainWindow.frame.midX - frameSize.width / 2,
                y: mainWindow.frame.maxY + chipGap
            )
        }

        let clampedOrigin = CGPoint(
            x: min(max(origin.x, screenVisibleFrame.minX + 8), screenVisibleFrame.maxX - frameSize.width - 8),
            y: min(max(origin.y, screenVisibleFrame.minY + 8), screenVisibleFrame.maxY - frameSize.height - 8)
        )

        window.setFrame(CGRect(origin: clampedOrigin, size: frameSize).integral, display: true)
    }

    private func configureHiddenWindowState() {
        guard let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    private func animateWindowAlpha(to alphaValue: CGFloat, completion: (() -> Void)? = nil) {
        guard let window else {
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alphaValue
        } completionHandler: {
            completion?()
        }
    }

    private func beginMainWindowInteraction() {
        guard mainWindowInteractionLease?.isActive != true else { return }
        mainWindowInteractionLease = mainWindow?.acquireInteractionLease()
    }

    private func endMainWindowInteraction() {
        mainWindowInteractionLease = nil
    }
}

private final class SmartOrganizeProgressChipWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SmartOrganizeProgressChipView: View {
    @ObservedObject private var progress = SmartOrganizeProgressService.shared

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif

        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(progress.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.16))
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .fixedSize()
    }
}
