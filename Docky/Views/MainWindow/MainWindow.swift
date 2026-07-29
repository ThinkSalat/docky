//
//  MainWindow.swift
//  Docky
//
//  Created by Jose Quintero on 17/04/26.
//

import AppKit
import Combine
import SwiftUI

final class MainWindowContainerView: NSView {
    private let contentView = ClickThroughHostingView(rootView: MainWindowView())
    private var trackingArea: NSTrackingArea?
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        topConstraint = contentView.topAnchor.constraint(equalTo: topAnchor)
        bottomConstraint = bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        leadingConstraint = contentView.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingConstraint = trailingAnchor.constraint(equalTo: contentView.trailingAnchor)

        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint, leadingConstraint, trailingConstraint
        ])

        applyContentInsets()
        observePreferencesForInsets()
        observeTileHoverEffectsPreference()
    }

    /// Re-applies the per-edge content padding. Full-axis mode forces
    /// every edge to 0 so the chrome bleeds to the panel border; in
    /// fit-content mode each edge picks up its own theme/user override
    /// from `DockyPreferences`.
    private func applyContentInsets() {
        let prefs = DockyPreferences.shared
        let fullAxis = prefs.effectiveWindowAxisSizing == .fullAxis
        let top = fullAxis ? 0 : prefs.effectiveWindowContentInsetTop
        let leading = fullAxis ? 0 : prefs.effectiveWindowContentInsetLeading
        let bottom = fullAxis ? 0 : prefs.effectiveWindowContentInsetBottom
        let trailing = fullAxis ? 0 : prefs.effectiveWindowContentInsetTrailing
        topConstraint.constant = top
        bottomConstraint.constant = bottom
        leadingConstraint.constant = leading
        trailingConstraint.constant = trailing
    }

    /// Observation-framework wiring: every read inside the closure is
    /// tracked; the `onChange` callback fires once per change, then we
    /// re-register by recursing. Same pattern AppKit code elsewhere in
    /// the project uses to bridge from `@Observable` into NSView land.
    private func observePreferencesForInsets() {
        withObservationTracking {
            _ = DockyPreferences.shared.effectiveWindowAxisSizing
            _ = DockyPreferences.shared.effectiveWindowContentInsetTop
            _ = DockyPreferences.shared.effectiveWindowContentInsetLeading
            _ = DockyPreferences.shared.effectiveWindowContentInsetBottom
            _ = DockyPreferences.shared.effectiveWindowContentInsetTrailing
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyContentInsets()
                self.observePreferencesForInsets()
            }
        }
    }

    /// Bridges the Observation-backed hover master into AppKit's pointer
    /// tracking. Disabling clears an in-flight magnification immediately.
    /// Re-enabling resamples the current pointer, so a stationary cursor
    /// restores magnification without waiting for another mouse-moved event.
    private func observeTileHoverEffectsPreference() {
        withObservationTracking {
            _ = DockyPreferences.shared.tileHoverEffectsEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if DockyPreferences.shared.tileHoverEffectsEnabled {
                    self.resampleMagnificationPointerFromCurrentLocation()
                } else {
                    DockMagnificationService.shared.clearPointer()
                }
                self.observeTileHoverEffectsPreference()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        (window as? MainWindow)?.pointerDidEnterWindow()
        forwardMagnificationPointer(
            locationInWindow: event.locationInWindow
        )
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        forwardMagnificationPointer(
            locationInWindow: event.locationInWindow
        )
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        (window as? MainWindow)?.pointerDidExitWindow()
        DockMagnificationService.shared.clearPointer()
    }

    /// Pushes the live pointer position into the magnification service in
    /// the hosting view's top-left origin coordinate space, same as what
    /// SwiftUI sees via `GeometryProxy.frame(in: .global)`. Caller flips Y
    /// when the underlying NSHostingView isn't already flipped.
    ///
    /// We only forward when the cursor is within the chrome's cross-axis
    /// strip. The window is taller (or wider, for side docks) than the
    /// chrome to make room for magnified icons, so a window-wide tracking
    /// area would magnify tiles as soon as the pointer entered the empty
    /// headroom above the chrome, well before it ever touched a tile.
    func resampleMagnificationPointerFromCurrentLocation() {
        guard let window else {
            DockMagnificationService.shared.clearPointer()
            return
        }
        let locationInWindow = window.mouseLocationOutsideOfEventStream
        let localPoint = convert(locationInWindow, from: nil)
        guard bounds.contains(localPoint) else {
            DockMagnificationService.shared.clearPointer()
            return
        }
        forwardMagnificationPointer(locationInWindow: locationInWindow)
    }

    private func forwardMagnificationPointer(
        locationInWindow: CGPoint
    ) {
        guard TileHoverEffectsRuntimePolicy.allowsMagnification(
            isEnabled: DockyPreferences.shared.tileHoverEffectsEnabled,
            configuredEnabled:
                DockSettingsService.shared.effectiveMagnification
        ) else {
            DockMagnificationService.shared.clearPointer()
            return
        }

        let inHosting = contentView.convert(locationInWindow, from: nil)
        let topLeft: CGPoint = contentView.isFlipped
            ? inHosting
            : CGPoint(x: inHosting.x, y: contentView.bounds.height - inHosting.y)
        guard cursorIsAtChromeFringe(topLeft, hostingSize: contentView.bounds.size) else {
            DockMagnificationService.shared.clearPointer()
            return
        }
        DockMagnificationService.shared.updatePointer(at: topLeft)
    }

    /// Cross-axis bounds check against the resting chrome. We don't gate
    /// on the along-axis (proximity to dock edge in that direction is the
    /// whole point of the cosine falloff), only the cross-axis fringe.
    private func cursorIsAtChromeFringe(_ point: CGPoint, hostingSize: CGSize) -> Bool {
        let position = DockyPreferences.shared.windowPosition
            .resolved(systemOrientation: DockSettingsService.shared.orientation)
        let chromeSize =
            DockLayoutService.shared.chromeSurfaces
                .combinedSize(isVertical: position.isVertical)
        guard chromeSize.width > 0, chromeSize.height > 0 else { return true }
        switch position {
        case .bottom:
            return point.y >= hostingSize.height - chromeSize.height
        case .top:
            return point.y <= chromeSize.height
        case .left:
            return point.x <= chromeSize.width
        case .right:
            return point.x >= hostingSize.width - chromeSize.width
        }
    }
}

/// NSPanel (not NSWindow) so the `.nonactivatingPanel` style mask actually
/// takes effect, that's the only way to keep clicks on the dock from
/// activating Docky as a foreground app, which would otherwise break
/// frontmost-tracked behaviors (cycle windows on tile click, hide-on-second-click).
final class MainWindow: NSPanel {
    /// We default to `false` so tile clicks don't bring Docky to the
    /// foreground (frontmost-tracked behaviors like cycle-on-click rely
    /// on the previously-frontmost app staying key). Embedded controls
    /// that need keyboard input, currently only the Search widget's
    /// 2x/3x text field, set `allowsKeyWindow` to `true` while focused
    /// so SwiftUI can route keystrokes into them, then flip it back off
    /// on resign.
    static var allowsKeyWindow: Bool = false
    override var canBecomeKey: Bool { Self.allowsKeyWindow }
    override var canBecomeMain: Bool { false }

    override var level: NSWindow.Level { get { .mainMenu } set {} }

    private let backgroundBlurRadius = 10
    private let hiddenRevealThickness: CGFloat = 2
    private let tileMutationAnimationDuration: TimeInterval = 0.18
    private let dockSettings = DockSettingsService.shared
    private let preferences = DockyPreferences.shared
    private let layout = DockLayoutService.shared
    private let presentation =
        DockPresentationService.shared
    private let editMode = DockEditModeService.shared
    private let minimumWidth: CGFloat = 120
    private var cancellables: Set<AnyCancellable> = []
    private var hideWorkItem: DispatchWorkItem?
    private var fullscreenRecheckWorkItem: DispatchWorkItem?
    private var fullscreenRevealWorkItem: DispatchWorkItem?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var globalDragRevealMonitor: Any?
    private var localDragRevealMonitor: Any?
    private var isPointerInsideWindow = false
    private var pointerRevealAuthorized = false
    private var isDragActiveForVisibility = false
    private var activeInteractionLeaseIDs: Set<UUID> = []
    private var visibilityState: DockVisibility
    private var hasCompletedSetup = false
    private var hasResolvedInitialFrame = false
    private var lastPointerScreenFrame: CGRect?
    private var isFullscreenActiveOnTargetScreen = false
    private var isMaximizedActiveOnTargetScreen = false
    private var lastHideDecisionSignature: String?
    private var lastFrameDiagnosticSignature: String?

    private var fullscreenHidingActive: Bool {
        isFullscreenActiveOnTargetScreen && preferences.hidesDuringFullscreen
    }

    private var maximizedHidingActive: Bool {
        isMaximizedActiveOnTargetScreen && preferences.maximizedWindowBehavior == .hideDocky
    }

    private var visibilityInputs: DockVisibilityInputs {
        DockVisibilityInputs(
            autohidePreferenceEnabled: preferences.autohidesWindow,
            fullscreenHidingActive: fullscreenHidingActive,
            maximizedHidingActive: maximizedHidingActive,
            pointerInside: isPointerInsideWindow,
            pointerRevealAuthorized: pointerRevealAuthorized,
            activeInteractionLeaseIDs: activeInteractionLeaseIDs,
            editModeActive: editMode.isActive,
            dragActive: isDragActiveForVisibility
        )
    }

    private var visibilityDecision: DockVisibilityDecision {
        DockVisibilityReducer.reduce(visibilityInputs)
    }

    private var effectivelyAutohides: Bool {
        visibilityDecision.effectivelyAutohides
    }

    private var isContentOverlapActive: Bool {
        visibilityDecision.contentOverlapHidingActive
    }

    /// The frame Docky claims for content reservation, or nil when Docky is
    /// hidden / off-screen / not currently rendering. Used by services that
    /// keep other apps' windows out of Docky's way.
    var currentReservationFrame: CGRect? {
        visibilityState == .visible ? frame : nil
    }

    /// Screen-coordinate rect of the visible chrome (the dock pill itself,
    /// not the magnification headroom around it). Built from the primary
    /// chrome surface rather than crossing the SwiftUI/AppKit coordinate
    /// boundary. The detached Handoff capsule must not move overlays that
    /// are semantically anchored to the main dock.
    func chromeScreenFrame() -> CGRect? {
        let chromeSurfaces =
            DockLayoutService.shared.chromeSurfaces
        let chromeSize = chromeSurfaces.primarySize
        guard chromeSize.width > 0, chromeSize.height > 0 else { return nil }
        let position = DockyPreferences.shared.windowPosition
            .resolved(systemOrientation: DockSettingsService.shared.orientation)
        let f = frame
        let width = min(chromeSize.width, f.width)
        let height = min(chromeSize.height, f.height)
        let primaryCenterOffset =
            chromeSurfaces.primaryCenterOffset
        switch position {
        case .bottom:
            return CGRect(
                x:
                    f.midX
                    + primaryCenterOffset
                    - width / 2,
                y: f.minY,
                width: width,
                height: height
            )
        case .top:
            return CGRect(
                x:
                    f.midX
                    + primaryCenterOffset
                    - width / 2,
                y: f.maxY - height,
                width: width,
                height: height
            )
        case .left:
            return CGRect(
                x: f.minX,
                y:
                    f.midY
                    - primaryCenterOffset
                    - height / 2,
                width: width,
                height: height
            )
        case .right:
            return CGRect(
                x: f.maxX - width,
                y:
                    f.midY
                    - primaryCenterOffset
                    - height / 2,
                width: width,
                height: height
            )
        }
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        visibilityState = DockyPreferences.shared.autohidesWindow ? .hidden : .visible
        // Force `.nonactivatingPanel` regardless of what the XIB hands us so
        // tile clicks never bring Docky to the foreground. Other bits stay
        // intact (the XIB-supplied mask covers titled/resizable/etc.).
        super.init(
            contentRect: contentRect,
            styleMask: style.union(.nonactivatingPanel),
            backing: backingStoreType,
            defer: flag
        )
        performSetupIfNeeded()
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        applyCurrentFrame(animated: false)
    }

    private func performSetupIfNeeded() {
        guard !hasCompletedSetup else { return }
        hasCompletedSetup = true

        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = false
        alphaValue = 0
        // Magnification tracking lives on the content view's NSTrackingArea
        // (.mouseMoved + .activeAlways). Enabling mouseMoved on the window
        // itself ensures AppKit routes those events through the responder
        // chain even though this panel never becomes key.
        acceptsMouseMovedEvents = true
        applyCollectionBehavior()
        observeFrameInputs()
        observeScreenAndSpaceInputs()
        observeWindowPlacementInputs()
        observeVisibilityInputs()
        updatePointerScreenMonitoring()
        updateDragRevealMonitoring()
        let initialOverlap = computeContentOverlapStateOnTargetScreen()
        isFullscreenActiveOnTargetScreen = initialOverlap.isFullscreen
        isMaximizedActiveOnTargetScreen = initialOverlap.isMaximized
        recordContentOverlap(
            initialOverlap,
            reason: "launch",
            previousFullscreen: false,
            previousMaximized: false,
            previousEffectiveAutohide: preferences.autohidesWindow
        )
        visibilityState = visibilityDecision.visibility
    }

    deinit {
        fullscreenRecheckWorkItem?.cancel()
        fullscreenRevealWorkItem?.cancel()
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
        }
        if let globalDragRevealMonitor {
            NSEvent.removeMonitor(globalDragRevealMonitor)
        }
        if let localDragRevealMonitor {
            NSEvent.removeMonitor(localDragRevealMonitor)
        }
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        applyBackgroundBlur()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            DiagnosticsTrace.shared.record(.input, "mainWindowMouseEvent", fields: [
                "type": String(describing: event.type),
                "eventNumber": event.eventNumber,
                "eventWindowNumber": event.windowNumber,
                "mainWindowNumber": windowNumber,
                "visibilityState": String(describing: visibilityState),
                "isVisible": isVisible,
                "alpha": alphaValue,
                "ignoresMouseEvents": ignoresMouseEvents,
                "isKey": isKeyWindow,
                "isMain": isMainWindow,
                "occlusionState": occlusionState.rawValue,
                "frame": NSStringFromRect(frame),
                "pointerInside": isPointerInsideWindow,
                "interactionCount": activeInteractionLeaseIDs.count,
            ])
        }
        super.sendEvent(event)
    }

    private func applyBackgroundBlur() {
        guard windowNumber > 0 else { return }
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSMainConnectionID(),
            windowNumber,
            backgroundBlurRadius
        )
    }

    private func observeFrameInputs() {
        // Tile membership and order have exactly one publisher. Rendering
        // and frame measurement consume the same immutable snapshot, so a
        // transient tile cannot appear without contributing to natural size.
        presentation.$snapshot
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyCurrentFrame(animated: true, duration: self?.tileMutationAnimationDuration) }
            .store(in: &cancellables)

        observeChanges { [weak self] in
            guard let self else { return }
            // Touch every preference and dock-setting that drives frame
            // layout. The Observation framework tracks these reads and
            // re-runs the closure on any change.
            _ = preferences.effectiveTileVerticalPadding
            _ = preferences.effectiveTileSpacing
            _ = preferences.overflowBehavior
            _ = preferences.effectiveWindowAxisSizing
            _ = preferences.windowPosition
            _ = preferences.windowDisplayTarget
            _ = dockSettings.orientation
            _ = dockSettings.effectiveTileSize
            _ = dockSettings.effectiveLargeSize
            _ = dockSettings.effectiveMagnification
            self.applyCurrentFrame(animated: true, duration: self.tileMutationAnimationDuration)
        }
        .store(in: &cancellables)

        editMode.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                guard let self else { return }
                if isActive {
                    self.hideWorkItem?.cancel()
                    self.applyEffectiveVisibility(animated: true)
                } else {
                    self.scheduleHideIfNeeded()
                }
            }
            .store(in: &cancellables)

        // Keep the dock visible while any drag is in flight (Finder→dock,
        // palette, or icon-out-of-folder). The cursor can briefly be outside
        // the dock window during the transit, so without this the dock would
        // start to auto-hide just as the user is moving the drag toward it.
        Publishers.CombineLatest(
            DockDragService.shared.$kind
                .map { $0 != nil },
            DockPresentationService.shared.$internalDrag
                .map { $0.tileID != nil }
        )
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasDrag in
                guard let self else { return }
                self.isDragActiveForVisibility = hasDrag
                if hasDrag {
                    self.hideWorkItem?.cancel()
                    self.applyEffectiveVisibility(animated: true)
                } else {
                    self.scheduleHideIfNeeded()
                }
            }
            .store(in: &cancellables)

    }

    private func observeScreenAndSpaceInputs() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.reconcileTransientVisibilityState(reason: "screenParametersChanged")
                self.applyCurrentFrame(animated: false)
                self.updateFullscreenStateAndApply(
                    animated: false,
                    reason: "screenParametersChanged",
                    forceVisibilityApply: true
                )
            }
            .store(in: &cancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.reconcileTransientVisibilityState(reason: "activeSpaceNotification")
                self.applyCurrentFrame(animated: false)
                self.updateFullscreenStateAndApply(
                    animated: true,
                    reason: "activeSpaceNotification",
                    forceVisibilityApply: true
                )
                // The space change fires during the fullscreen exit animation
                // while the fullscreen window is still on-screen. Re-check once
                // the animation has had time to complete.
                self.scheduleFullscreenRecheck()
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFullscreenStateAndApply(
                    animated: true,
                    reason: "applicationActivated"
                )
                self?.scheduleFullscreenRecheck()
            }
            .store(in: &cancellables)
    }

    private func observeWindowPlacementInputs() {
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.windowSpaceBehavior
            guard let self else { return }
            self.applyCollectionBehavior()
            self.reconcileTransientVisibilityState(reason: "spaceBehaviorPreferenceChanged")
            self.updateFullscreenStateAndApply(
                animated: false,
                reason: "spaceBehaviorPreferenceChanged",
                forceVisibilityApply: true
            )
        }
        .store(in: &cancellables)

        observeChanges { [weak self] in
            _ = DockyPreferences.shared.windowDisplayTarget
            guard let self else { return }
            self.lastPointerScreenFrame = nil
            self.reconcileTransientVisibilityState(reason: "displayTargetPreferenceChanged")
            self.updatePointerScreenMonitoring()
            self.updateFullscreenStateAndApply(
                animated: true,
                reason: "displayTargetPreferenceChanged",
                forceVisibilityApply: true
            )
        }
        .store(in: &cancellables)

        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lastPointerScreenFrame = nil
                self?.updatePointerScreenMonitoring()
            }
            .store(in: &cancellables)

        // App-level activate/space changes don't fire when a window in the
        // foreground app gets maximized or fullscreened, so piggy-back on the
        // registry's AX resize/move signal. Debounce so a drag-resize doesn't
        // hammer the overlap recomputation.
        WindowRegistry.shared.$windows
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFullscreenStateAndApply(
                    animated: true,
                    reason: "axWindowSnapshotChanged"
                )
            }
            .store(in: &cancellables)
    }

    private func observeVisibilityInputs() {
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.autohidesWindow
            self?.applyEffectiveVisibility(animated: true)
        }
        .store(in: &cancellables)

        observeChanges { [weak self] in
            _ = DockyPreferences.shared.maximizedWindowBehavior
            _ = DockyPreferences.shared.hidesDuringFullscreen
            guard let self else { return }
            self.reconcileTransientVisibilityState(reason: "overlapPreferenceChanged")
            self.updateFullscreenStateAndApply(
                animated: true,
                reason: "overlapPreferenceChanged",
                forceVisibilityApply: true
            )
        }
        .store(in: &cancellables)
    }

    private func applyCollectionBehavior() {
        collectionBehavior = preferences.windowSpaceBehavior.collectionBehavior(includesFullScreenAuxiliary: true)
    }

    private func updatePointerScreenMonitoring() {
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }

        guard preferences.windowDisplayTarget == .displayContainingPointer else { return }

        let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        if PermissionsService.shared.accessibility == .granted {
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
                self?.handlePointerScreenChangeIfNeeded()
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            self?.handlePointerScreenChangeIfNeeded()
            return event
        }
    }

    private func updateDragRevealMonitoring() {
        if let globalDragRevealMonitor {
            NSEvent.removeMonitor(globalDragRevealMonitor)
            self.globalDragRevealMonitor = nil
        }
        if let localDragRevealMonitor {
            NSEvent.removeMonitor(localDragRevealMonitor)
            self.localDragRevealMonitor = nil
        }

        let dragEvents: NSEvent.EventTypeMask = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalDragRevealMonitor = NSEvent.addGlobalMonitorForEvents(matching: dragEvents) { [weak self] _ in
            self?.syncPointerPresenceForDragSession()
        }
        localDragRevealMonitor = NSEvent.addLocalMonitorForEvents(matching: dragEvents) { [weak self] event in
            self?.syncPointerPresenceForDragSession()
            return event
        }
    }

    private func handlePointerScreenChangeIfNeeded() {
        guard preferences.windowDisplayTarget == .displayContainingPointer else { return }
        let nextScreenFrame = targetScreen()?.frame
        guard nextScreenFrame != lastPointerScreenFrame else { return }
        lastPointerScreenFrame = nextScreenFrame
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileTransientVisibilityState(reason: "pointerDisplayChanged")
            self.applyCurrentFrame(animated: false)
            self.updateFullscreenStateAndApply(
                animated: true,
                reason: "pointerDisplayChanged",
                forceVisibilityApply: true
            )
        }
    }

    func pointerDidEnterWindow() {
        isPointerInsideWindow = true
        pointerRevealAuthorized = false
        hideWorkItem?.cancel()
        DiagnosticsTrace.shared.record(.input, "pointerEnteredMainWindow", fields: [
            "visibilityState": String(describing: visibilityState),
            "effectivelyAutohides": effectivelyAutohides,
            "fullscreen": isFullscreenActiveOnTargetScreen,
            "maximized": isMaximizedActiveOnTargetScreen,
            "requiresRevealAuthorization": visibilityDecision.requiresPointerRevealAuthorization,
            "leaseBlocksRevealAuthorization":
                visibilityDecision.interactionLeaseBlocksPointerRevealAuthorization,
        ])

        if visibilityDecision.requiresPointerRevealAuthorization {
            applyEffectiveVisibility(animated: true)
            guard !visibilityDecision.interactionLeaseBlocksPointerRevealAuthorization else {
                fullscreenRevealWorkItem?.cancel()
                fullscreenRevealWorkItem = nil
                return
            }
            if preferences.fullscreenRevealDelay > 0 {
                scheduleFullscreenReveal()
            } else {
                pointerRevealAuthorized = true
                applyEffectiveVisibility(animated: true)
            }
            return
        }

        pointerRevealAuthorized = isContentOverlapActive
        applyEffectiveVisibility(animated: true)
    }

    func pointerDidExitWindow() {
        isPointerInsideWindow = false
        pointerRevealAuthorized = false
        fullscreenRevealWorkItem?.cancel()
        fullscreenRevealWorkItem = nil
        DiagnosticsTrace.shared.record(.input, "pointerExitedMainWindow", fields: [
            "visibilityState": String(describing: visibilityState),
            "effectivelyAutohides": effectivelyAutohides,
            "interactionCount": activeInteractionLeaseIDs.count,
        ])
        scheduleHideIfNeeded()
    }

    private func scheduleFullscreenReveal() {
        fullscreenRevealWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullscreenRevealWorkItem = nil
            guard self.isPointerInsideWindow,
                  self.isContentOverlapActive
            else { return }
            self.pointerRevealAuthorized = true
            self.applyEffectiveVisibility(animated: true)
        }
        fullscreenRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.fullscreenRevealDelay, execute: workItem)
    }

    private func syncPointerPresenceForDragSession() {
        let hasDrag =
            DockDragService.shared.kind != nil
            || DockPresentationService.shared
                .internalDrag.tileID != nil
        if hasDrag != isDragActiveForVisibility {
            isDragActiveForVisibility = hasDrag
            applyEffectiveVisibility(animated: true)
        }

        let containsPointer = frame.contains(NSEvent.mouseLocation)
        if containsPointer, !isPointerInsideWindow {
            pointerDidEnterWindow()
        } else if !containsPointer, isPointerInsideWindow {
            pointerDidExitWindow()
        }
    }

    func acquireInteractionLease() -> MainWindowInteractionLease {
        precondition(
            Thread.isMainThread,
            "MainWindow interaction leases must be acquired on the main thread"
        )
        let id = UUID()
        activeInteractionLeaseIDs.insert(id)
        hideWorkItem?.cancel()
        // A lease can reveal Docky before the edge-dwell timer completes.
        // Do not let that now-hidden timer authorize the pointer while the
        // presenter is holding visibility; once the presenter closes, an
        // unauthorized pointer must reduce back to hidden.
        if isContentOverlapActive, !pointerRevealAuthorized {
            fullscreenRevealWorkItem?.cancel()
            fullscreenRevealWorkItem = nil
        }
        DiagnosticsTrace.shared.record(.input, "interactionBegan", fields: [
            "interactionCount": activeInteractionLeaseIDs.count,
            "visibilityState": String(describing: visibilityState),
        ])
        applyEffectiveVisibility(animated: true)

        return MainWindowInteractionLease(
            id: id,
            onRelease: { [weak self] leaseID in
                self?.releaseInteractionLease(leaseID)
            },
            isActive: { [weak self] in
                self?.activeInteractionLeaseIDs.contains(id) == true
            }
        )
    }

    private func releaseInteractionLease(_ id: UUID) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.releaseInteractionLease(id)
            }
            return
        }

        guard activeInteractionLeaseIDs.remove(id) != nil else { return }
        DiagnosticsTrace.shared.record(.input, "interactionEnded", fields: [
            "interactionCount": activeInteractionLeaseIDs.count,
            "visibilityState": String(describing: visibilityState),
        ])

        // If this was the last hold and the pointer entered while a presenter
        // was open, hide first and start a new dwell from the release boundary.
        // Time spent visible only because of a lease never earns edge reveal.
        let decision = visibilityDecision
        if activeInteractionLeaseIDs.isEmpty,
           decision.requiresPointerRevealAuthorization,
           decision.visibility == .hidden {
            fullscreenRevealWorkItem?.cancel()
            fullscreenRevealWorkItem = nil
            if preferences.fullscreenRevealDelay > 0 {
                applyEffectiveVisibility(animated: true)
                scheduleFullscreenReveal()
            } else {
                pointerRevealAuthorized = true
                applyEffectiveVisibility(animated: true)
            }
            return
        }
        scheduleHideIfNeeded()
    }

    /// Space/display/fullscreen changes can strand AppKit tracking areas and
    /// presenters without their matching exit/close callback. Reset transient
    /// claims at the boundary; existing lease objects become inert and their
    /// eventual RAII release remains idempotent.
    private func reconcileTransientVisibilityState(reason: String) {
        let previousLeaseCount = activeInteractionLeaseIDs.count
        let hadTransientState =
            isPointerInsideWindow
            || pointerRevealAuthorized
            || isDragActiveForVisibility
            || previousLeaseCount > 0
        if hadTransientState {
            DiagnosticsTrace.shared.record(
                .visibility,
                "transientVisibilityStateReconciled",
                fields: [
                    "reason": reason,
                    "pointerInside": isPointerInsideWindow,
                    "pointerRevealAuthorized": pointerRevealAuthorized,
                    "interactionCount": previousLeaseCount,
                    "dragActive": isDragActiveForVisibility,
                ]
            )
        }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fullscreenRevealWorkItem?.cancel()
        fullscreenRevealWorkItem = nil
        isPointerInsideWindow = false
        pointerRevealAuthorized = false
        isDragActiveForVisibility = false
        activeInteractionLeaseIDs.removeAll()
        DockMagnificationService.shared.clearPointer()
        // A still-live drag reasserts itself through the next drag event or
        // DockDragService publication. A stranded pre-transition value cannot
        // keep Docky visible indefinitely.
    }

    private func applyEffectiveVisibility(animated: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let decision = visibilityDecision
        DiagnosticsTrace.shared.record(.visibility, "effectiveVisibilityApplied", fields: [
            "effectiveAutohide": decision.effectivelyAutohides,
            "nextState": String(describing: decision.visibility),
            "pointerInside": isPointerInsideWindow,
            "pointerRevealAuthorized": pointerRevealAuthorized,
            "interactionCount": activeInteractionLeaseIDs.count,
            "editMode": editMode.isActive,
            "dragActive": isDragActiveForVisibility,
            "animated": animated,
        ])
        setVisibility(decision.visibility, animated: animated)
    }

    private func scheduleHideIfNeeded() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        let decision = visibilityDecision
        let decisionSignature = [
            String(decision.effectivelyAutohides),
            String(describing: decision.visibility),
            String(isPointerInsideWindow),
            String(pointerRevealAuthorized),
            String(activeInteractionLeaseIDs.count),
            String(editMode.isActive),
            String(isDragActiveForVisibility),
        ].joined(separator: "|")
        if decisionSignature != lastHideDecisionSignature {
            lastHideDecisionSignature = decisionSignature
            DiagnosticsTrace.shared.record(.visibility, "hideSchedulingEvaluated", fields: [
                "effectiveAutohide": decision.effectivelyAutohides,
                "shouldRemainVisible": decision.visibility == .visible,
                "pointerInside": isPointerInsideWindow,
                "pointerRevealAuthorized": pointerRevealAuthorized,
                "interactionCount": activeInteractionLeaseIDs.count,
                "editMode": editMode.isActive,
                "dragActive": isDragActiveForVisibility,
                "delaySeconds": preferences.autohideWindowDelay,
            ])
        }

        guard decision.visibility == .hidden else {
            applyEffectiveVisibility(animated: true)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil
            let latestDecision = self.visibilityDecision
            guard latestDecision.visibility == .hidden else {
                DiagnosticsTrace.shared.record(.visibility, "hideTimerBlocked", fields: [
                    "pointerInside": self.isPointerInsideWindow,
                    "pointerRevealAuthorized": self.pointerRevealAuthorized,
                    "interactionCount": self.activeInteractionLeaseIDs.count,
                    "editMode": self.editMode.isActive,
                    "dragActive": self.isDragActiveForVisibility,
                ])
                return
            }
            DiagnosticsTrace.shared.record(.visibility, "hideTimerFired")
            self.setVisibility(.hidden, animated: true)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.autohideWindowDelay, execute: workItem)
    }

    private func setVisibility(_ state: DockVisibility, animated: Bool) {
        guard visibilityState != state else {
            applyCurrentFrame(animated: false)
            return
        }

        let previousState = visibilityState
        let previousFrame = frame
        visibilityState = state
        applyCurrentFrame(animated: animated)
        DiagnosticsTrace.shared.record(.visibility, "visibilityChanged", fields: [
            "previousState": String(describing: previousState),
            "state": String(describing: state),
            "animated": animated,
            "previousFrame": NSStringFromRect(previousFrame),
            "frame": NSStringFromRect(frame),
            "effectiveAutohide": effectivelyAutohides,
            "persistedAutohide": preferences.autohidesWindow,
            "fullscreen": isFullscreenActiveOnTargetScreen,
            "maximized": isMaximizedActiveOnTargetScreen,
            "pointerInside": isPointerInsideWindow,
            "pointerRevealAuthorized": pointerRevealAuthorized,
            "interactionCount": activeInteractionLeaseIDs.count,
            "editMode": editMode.isActive,
            "dragActive": isDragActiveForVisibility,
        ])
    }

    private func applyCurrentFrame(animated: Bool) {
        applyCurrentFrame(animated: animated, duration: nil)
    }

    private func applyCurrentFrame(animated: Bool, duration: TimeInterval?) {
        let resolvedScreen = targetScreen() ?? screen ?? NSScreen.main
        let screenBounds = resolvedScreen?.frame ?? .zero
        lastPointerScreenFrame = screenBounds
        // Vertical full-axis used to span `screen.frame` and slipped
        // behind the menu bar (and the system Dock, when shown). Use
        // `visibleFrame` for vertical positions so axis length and
        // origin centering are computed against the same clamped
        // rect — the dock then sits exactly between the menu bar
        // and the system Dock without any per-edge offset math.
        // Horizontal positions stay anchored to `screen.frame` so a
        // top dock keeps anchoring to the top edge, etc.
        let visibleBounds = resolvedScreen?.visibleFrame ?? screenBounds
        // Window-frame math needs the *total* horizontal and vertical
        // padding the chrome view leaves around itself inside the panel.
        // Per-edge insets live in `DockyPreferences`; full-axis mode
        // forces them to zero in `MainWindowContainerView` and we
        // mirror that here so the panel sizing stays in sync.
        let fullAxis = preferences.effectiveWindowAxisSizing == .fullAxis
        let horizontalContentPadding: CGFloat = fullAxis ? 0
            : preferences.effectiveWindowContentInsetLeading + preferences.effectiveWindowContentInsetTrailing
        let verticalContentPadding: CGFloat = fullAxis ? 0
            : preferences.effectiveWindowContentInsetTop + preferences.effectiveWindowContentInsetBottom
        let position = preferences.windowPosition.resolved(systemOrientation: dockSettings.orientation)
        let baseTileSize = dockSettings.effectiveTileSize
        let baseTileHeight = baseTileSize + preferences.effectiveTileVerticalPadding * 2
        let sizingTiles = presentation.snapshot.items
        let dockPartition =
            presentation.snapshot.dockPartition
        let naturalContentLayout =
            TileContainerView.dockContentLayout(
            partition: dockPartition,
            tileSize: baseTileSize,
            tileHeight: baseTileHeight,
            tileSpacing: preferences.effectiveTileSpacing,
            position: position
        )
        let naturalContentSize =
            naturalContentLayout.combinedSize
        let alongAxisContentPadding = position.isVertical ? verticalContentPadding : horizontalContentPadding
        let layoutBounds = position.isVertical ? visibleBounds : screenBounds
        let unreservedAvailableAxisLength = max(
            0,
            axisLength(of: layoutBounds.size, position: position) - alongAxisContentPadding
        )
        let contentAvailableAxisLength = max(
            0,
            unreservedAvailableAxisLength
                - (shouldReserveStatusBarLength(
                    for: naturalContentSize,
                    availableAxisLength: unreservedAvailableAxisLength,
                    position: position
                ) ? reservedStatusBarLength : 0)
        )
        let availableAxisLength = preferences.effectiveWindowAxisSizing == .fullAxis
            ? unreservedAvailableAxisLength
            : contentAvailableAxisLength
        let compactsWidgetsForOverflow = shouldCompactWidgetsForOverflow(
            contentSize: naturalContentSize,
            availableAxisLength: availableAxisLength,
            position: position
        )
        let baseContentLayout =
            TileContainerView.dockContentLayout(
            partition: dockPartition,
            tileSize: baseTileSize,
            tileHeight: baseTileHeight,
            tileSpacing: preferences.effectiveTileSpacing,
            position: position,
            compactWidgets: compactsWidgetsForOverflow
        )
        let baseContentSize = baseContentLayout.combinedSize
        let contentScale = overflowContentScale(
            for: baseContentSize,
            availableAxisLength: availableAxisLength,
            position: position
        )
        layout.setContentScale(contentScale)
        layout.setCompactsWidgetsForOverflow(compactsWidgetsForOverflow)

        let scaledTileSize = baseTileSize * contentScale
        let scaledTileHeight = scaledTileSize + (preferences.effectiveTileVerticalPadding * contentScale * 2)
        let scaledTileSpacing = preferences.effectiveTileSpacing * contentScale
        let displayedContentLayout =
            TileContainerView.dockContentLayout(
            partition: dockPartition,
            tileSize: scaledTileSize,
            tileHeight: scaledTileHeight,
            tileSpacing: scaledTileSpacing,
            position: position,
            compactWidgets: compactsWidgetsForOverflow,
            mainEdgePadding:
                TileContainerView.edgePadding * contentScale,
            handoffEdgePadding:
                TileContainerView.handoffDockEdgePadding
                    * contentScale,
            interDockGap:
                TileContainerView.handoffDockGap
                    * contentScale
        )
        let displayedContentSize =
            displayedContentLayout.combinedSize
        let chromeSurfaces = resolvedChromeSurfaces(
            contentLayout: displayedContentLayout,
            availableAxisLength: availableAxisLength,
            position: position,
            fullAxis: fullAxis
        )
        layout.setChromeSurfaces(
            chromeSurfaces
        )
        // Keep the chrome stretched across the current dock axis even when the
        // tile layout itself remains content-sized.
        let displayedAxisLength = availableAxisLength
        // Magnified icons render beyond the chrome's natural cross-axis
        // extent. We grow only the window, not the chrome rect, so the
        // chrome itself keeps its resting shape and the icons spill into
        // the headroom above (or beside, on a vertical dock) it. Peak
        // size is the UNscaled `largeSize` even when overflow has shrunk
        // the resting tiles, so headroom is measured from the scaled
        // chrome height up to that fixed peak.
        let scaledBaseTileSize =
            dockSettings.effectiveTileSize * contentScale
        let magnifiedTileSize = dockSettings.effectiveLargeSize
        let magnificationHeadroom: CGFloat = (
            dockSettings.effectiveMagnification
                && magnifiedTileSize > scaledBaseTileSize
        )
            ? magnifiedTileSize - scaledBaseTileSize
            : 0
        let windowContentSize: CGSize = {
            guard magnificationHeadroom > 0 else { return displayedContentSize }
            return position.isVertical
                ? CGSize(width: displayedContentSize.width + magnificationHeadroom, height: displayedContentSize.height)
                : CGSize(width: displayedContentSize.width, height: displayedContentSize.height + magnificationHeadroom)
        }()
        let width = displayedWindowWidth(
            for: windowContentSize,
            displayedAxisLength: displayedAxisLength,
            availableAxisLength: availableAxisLength,
            horizontalContentPadding: horizontalContentPadding,
            position: position
        )
        let height = displayedWindowHeight(
            for: windowContentSize,
            displayedAxisLength: displayedAxisLength,
            verticalContentPadding: verticalContentPadding,
            position: position
        )
        let size = CGSize(width: width, height: height)
        let origin = frameOrigin(
            in: layoutBounds,
            size: size,
            position: position,
            visibilityState: visibilityState
        )

        let targetFrame = CGRect(origin: origin, size: size)
        let frameDiagnosticSignature = [
            NSStringFromRect(frame),
            NSStringFromRect(targetFrame),
            String(describing: position),
            String(describing: preferences.effectiveWindowAxisSizing),
            String(sizingTiles.count),
            NSStringFromSize(
                chromeSurfaces.primarySize
            ),
            NSStringFromSize(
                chromeSurfaces.handoffSize
            ),
            String(describing: contentScale),
            String(compactsWidgetsForOverflow),
            String(describing: visibilityState),
        ].joined(separator: "|")
        if frameDiagnosticSignature != lastFrameDiagnosticSignature {
            lastFrameDiagnosticSignature = frameDiagnosticSignature
            DiagnosticsTrace.shared.record(.visibility, "mainWindowFrameComputed", fields: [
                "currentFrame": NSStringFromRect(frame),
                "targetFrame": NSStringFromRect(targetFrame),
                "screenFrame": NSStringFromRect(screenBounds),
                "screenVisibleFrame": NSStringFromRect(visibleBounds),
                "position": String(describing: position),
                "axisSizing": String(describing: preferences.effectiveWindowAxisSizing),
                "visibilityState": String(describing: visibilityState),
                "tileCount": sizingTiles.count,
                "primaryTileCount":
                    dockPartition.mainItems.count,
                "handoffTileCount":
                    dockPartition.handoffItems.count,
                "naturalContentSize": NSStringFromSize(naturalContentSize),
                "displayedContentSize": NSStringFromSize(displayedContentSize),
                "primaryChromeSize": NSStringFromSize(
                    chromeSurfaces.primarySize
                ),
                "handoffChromeSize": NSStringFromSize(
                    chromeSurfaces.handoffSize
                ),
                "interDockGap":
                    chromeSurfaces.interDockGap,
                "primaryCenterOffset":
                    chromeSurfaces.primaryCenterOffset,
                "windowContentSize": NSStringFromSize(windowContentSize),
                "contentScale": contentScale,
                "compactsWidgets": compactsWidgetsForOverflow,
                "fullAxis": fullAxis,
                "animated": animated,
                "duration": duration ?? -1,
            ])
        }
        applyFrame(targetFrame, animated: animated, duration: duration)
    }

    private func applyFrame(_ frame: CGRect, animated: Bool, duration: TimeInterval?) {
        let shouldAnimate = animated && hasResolvedInitialFrame

        guard shouldAnimate else {
            setFrame(frame, display: true, animate: false)
            revealAfterInitialFrameIfNeeded()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration ?? autohideAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        }
    }

    private func revealAfterInitialFrameIfNeeded() {
        guard !hasResolvedInitialFrame else { return }
        hasResolvedInitialFrame = true
        alphaValue = 1
    }

    private var autohideAnimationDuration: TimeInterval {
        min(max(0, preferences.autohideAnimationDuration), 1)
    }

    private func overflowContentScale(
        for contentSize: CGSize,
        availableAxisLength: CGFloat,
        position: ResolvedDockWindowPosition
    ) -> CGFloat {
        guard preferences.overflowBehavior == .rescale, availableAxisLength > 0 else {
            return 1
        }

        let contentAxisLength = axisLength(of: contentSize, position: position)
        guard contentAxisLength > 0 else { return 1 }
        return min(1, availableAxisLength / contentAxisLength)
    }

    private func shouldCompactWidgetsForOverflow(
        contentSize: CGSize,
        availableAxisLength: CGFloat,
        position: ResolvedDockWindowPosition
    ) -> Bool {
        guard preferences.overflowBehavior == .rescale, availableAxisLength > 0 else {
            return false
        }

        return axisLength(of: contentSize, position: position) > availableAxisLength
    }

    private func axisLength(of size: CGSize, position: ResolvedDockWindowPosition) -> CGFloat {
        position.isVertical ? size.height : size.width
    }

    private func shouldReserveStatusBarLength(
        for contentSize: CGSize,
        availableAxisLength: CGFloat,
        position: ResolvedDockWindowPosition
    ) -> Bool {
        axisLength(of: contentSize, position: position) > availableAxisLength
    }

    private var reservedStatusBarLength: CGFloat {
        NSStatusBar.system.thickness * 4
    }

    private func displayedWindowWidth(
        for contentSize: CGSize,
        displayedAxisLength: CGFloat,
        availableAxisLength: CGFloat,
        horizontalContentPadding: CGFloat,
        position: ResolvedDockWindowPosition
    ) -> CGFloat {
        if position.isVertical {
            return contentSize.width + horizontalContentPadding
        }

        let visibleAxisLength = availableAxisLength > 0
            ? min(max(minimumWidth, displayedAxisLength), availableAxisLength)
            : max(minimumWidth, displayedAxisLength)
        return visibleAxisLength + horizontalContentPadding
    }

    private func displayedWindowHeight(
        for contentSize: CGSize,
        displayedAxisLength: CGFloat,
        verticalContentPadding: CGFloat,
        position: ResolvedDockWindowPosition
    ) -> CGFloat {
        if position.isVertical {
            return displayedAxisLength + verticalContentPadding
        }

        return contentSize.height + verticalContentPadding
    }

    private func resolvedChromeSurfaces(
        contentLayout: DockTileSurfaceContentLayout,
        availableAxisLength: CGFloat,
        position: ResolvedDockWindowPosition,
        fullAxis: Bool
    ) -> DockChromeSurfaceLayout {
        let handoffAxisLength = axisLength(
            of: contentLayout.handoffSize,
            position: position
        )
        let combinedAxisLength = axisLength(
            of: contentLayout.combinedSize,
            position: position
        )
        let constrainsPrimaryAxis =
            fullAxis
            || (
                preferences.overflowBehavior == .scroll
                && combinedAxisLength > availableAxisLength
            )
        let primaryNaturalAxisLength = axisLength(
            of: contentLayout.primarySize,
            position: position
        )
        let placement =
            PresentedTileDockSurfacePlacementMetrics
                .resolve(
                    primaryNaturalExtent:
                        primaryNaturalAxisLength,
                    handoffExtent: handoffAxisLength,
                    interDockGap:
                        contentLayout.interDockGap,
                    availableExtent: availableAxisLength,
                    constrainsPrimary:
                        constrainsPrimaryAxis
                )

        return DockChromeSurfaceLayout(
            primarySize: replacingAxisLength(
                of: contentLayout.primarySize,
                with: placement.primaryDockExtent,
                position: position
            ),
            handoffSize: contentLayout.handoffSize,
            interDockGap: placement.interDockGap,
            primaryCenterOffset:
                placement.primaryCenterOffset,
            constrainsPrimaryAxis: constrainsPrimaryAxis
        )
    }

    private func replacingAxisLength(
        of size: CGSize,
        with axisLength: CGFloat,
        position: ResolvedDockWindowPosition
    ) -> CGSize {
        if position.isVertical {
            return CGSize(
                width: size.width,
                height: axisLength
            )
        }
        return CGSize(
            width: axisLength,
            height: size.height
        )
    }

    private func frameOrigin(
        in screenBounds: CGRect,
        size: CGSize,
        position: ResolvedDockWindowPosition,
        visibilityState: DockVisibility
    ) -> CGPoint {
        let hidden = visibilityState == .hidden

        switch position {
        case .top:
            return CGPoint(
                x: screenBounds.minX + (screenBounds.width - size.width) / 2,
                y: hidden ? screenBounds.maxY - hiddenRevealThickness : screenBounds.maxY - size.height
            )
        case .left:
            return CGPoint(
                x: hidden ? screenBounds.minX - size.width + hiddenRevealThickness : screenBounds.minX,
                y: screenBounds.minY + (screenBounds.height - size.height) / 2
            )
        case .right:
            return CGPoint(
                x: hidden ? screenBounds.maxX - hiddenRevealThickness : screenBounds.maxX - size.width,
                y: screenBounds.minY + (screenBounds.height - size.height) / 2
            )
        case .bottom:
            return CGPoint(
                x: screenBounds.minX + (screenBounds.width - size.width) / 2,
                y: hidden ? screenBounds.minY - size.height + hiddenRevealThickness : screenBounds.minY
            )
        }
    }

    private func targetScreen() -> NSScreen? {
        switch preferences.windowDisplayTarget {
        case .primaryDisplay:
            return NSScreen.screens.first ?? NSScreen.main
        case .displayContainingPointer:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                ?? screen
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }
    }

    private func updateFullscreenStateAndApply(
        animated: Bool,
        reason: String,
        forceVisibilityApply: Bool = false
    ) {
        let observation = computeContentOverlapStateOnTargetScreen()
        let previousFullscreen = isFullscreenActiveOnTargetScreen
        let previousMaximized = isMaximizedActiveOnTargetScreen
        let previousEffectiveAutohide = effectivelyAutohides
        let contentOverlapWasActive = isContentOverlapActive
        let fullscreenChanged = observation.isFullscreen != previousFullscreen
        let maximizedChanged = observation.isMaximized != previousMaximized
        isFullscreenActiveOnTargetScreen = observation.isFullscreen
        isMaximizedActiveOnTargetScreen = observation.isMaximized
        if fullscreenChanged
            || maximizedChanged
            || reason != "axWindowSnapshotChanged" {
            recordContentOverlap(
                observation,
                reason: reason,
                previousFullscreen: previousFullscreen,
                previousMaximized: previousMaximized,
                previousEffectiveAutohide: previousEffectiveAutohide
            )
        }
        guard fullscreenChanged || maximizedChanged || forceVisibilityApply else { return }
        if fullscreenChanged || contentOverlapWasActive != isContentOverlapActive {
            reconcileTransientVisibilityState(reason: "contentOverlapChanged:\(reason)")
        }
        applyEffectiveVisibility(animated: animated)
    }

    private func scheduleFullscreenRecheck() {
        fullscreenRecheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullscreenRecheckWorkItem = nil
            self.updateFullscreenStateAndApply(
                animated: true,
                reason: "delayedFullscreenRecheck"
            )
        }
        fullscreenRecheckWorkItem = workItem
        // Long enough to cover the macOS fullscreen exit animation, which can
        // run up to ~750 ms with reduce-motion off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    private struct ContentOverlapObservation {
        let isFullscreen: Bool
        let isMaximized: Bool
        let spaceID: UInt64
        let spaceType: Int32?
        let fullscreenSource: String
        let inspectedWindowCount: Int
        let fullscreenCandidateCount: Int
        let maximizedCandidateCount: Int
    }

    private func recordContentOverlap(
        _ observation: ContentOverlapObservation,
        reason: String,
        previousFullscreen: Bool,
        previousMaximized: Bool,
        previousEffectiveAutohide: Bool
    ) {
        DiagnosticsTrace.shared.record(.visibility, "contentOverlapEvaluated", fields: [
            "reason": reason,
            "spaceID": observation.spaceID,
            "spaceType": observation.spaceType.map(String.init) ?? "unknown",
            "fullscreenSource": observation.fullscreenSource,
            "previousFullscreen": previousFullscreen,
            "fullscreen": observation.isFullscreen,
            "previousMaximized": previousMaximized,
            "maximized": observation.isMaximized,
            "inspectedWindowCount": observation.inspectedWindowCount,
            "fullscreenCandidateCount": observation.fullscreenCandidateCount,
            "maximizedCandidateCount": observation.maximizedCandidateCount,
            "persistedAutohide": preferences.autohidesWindow,
            "hidesDuringFullscreen": preferences.hidesDuringFullscreen,
            "maximizedBehavior": String(describing: preferences.maximizedWindowBehavior),
            "previousEffectiveAutohide": previousEffectiveAutohide,
            "effectiveAutohide": effectivelyAutohides,
            "pointerInside": isPointerInsideWindow,
            "interactionCount": activeInteractionLeaseIDs.count,
            "editMode": editMode.isActive,
            "dragActive": isDragActiveForVisibility,
            "visibilityState": String(describing: visibilityState),
        ])
    }

    private func computeContentOverlapStateOnTargetScreen() -> ContentOverlapObservation {
        guard let screen = targetScreen() else {
            return ContentOverlapObservation(
                isFullscreen: false,
                isMaximized: false,
                spaceID: 0,
                spaceType: nil,
                fullscreenSource: "screenUnavailable",
                inspectedWindowCount: 0,
                fullscreenCandidateCount: 0,
                maximizedCandidateCount: 0
            )
        }

        // Native fullscreen is a property of the current Mission Control
        // Space on the display Docky actually targets. Prefer that direct
        // per-display signal over window geometry so a fullscreen Space on
        // another monitor cannot hide or reveal this Docky window. Unknown
        // Space data retains the CGWindow + Accessibility fallback below.
        let spaceSnapshot = activeSpaceSnapshot(for: screen)
        let fullscreenSpaceState = spaceSnapshot.isFullscreen

        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else {
            return ContentOverlapObservation(
                isFullscreen: fullscreenSpaceState ?? false,
                isMaximized: false,
                spaceID: spaceSnapshot.spaceID,
                spaceType: spaceSnapshot.rawType,
                fullscreenSource: fullscreenSpaceState == nil
                    ? "primaryScreenUnavailable"
                    : "spaceType",
                inspectedWindowCount: 0,
                fullscreenCandidateCount: 0,
                maximizedCandidateCount: 0
            )
        }

        let listOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID) as? [[String: Any]] else {
            return ContentOverlapObservation(
                isFullscreen: fullscreenSpaceState ?? false,
                isMaximized: false,
                spaceID: spaceSnapshot.spaceID,
                spaceType: spaceSnapshot.rawType,
                fullscreenSource: fullscreenSpaceState == nil
                    ? "windowListUnavailable"
                    : "spaceType",
                inspectedWindowCount: 0,
                fullscreenCandidateCount: 0,
                maximizedCandidateCount: 0
            )
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let dockSide = preferences.windowPosition.resolved(systemOrientation: dockSettings.orientation)
        var fullscreenCandidate = false
        var foundMaximized = false
        var fullscreenCandidatePIDs = Set<pid_t>()
        var inspectedWindowCount = 0
        var fullscreenCandidateCount = 0
        var maximizedCandidateCount = 0

        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }

            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            if ownerPID == ownPID {
                continue
            }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            inspectedWindowCount += 1

            // CGWindow uses a flipped Y axis with origin at the top-left of the
            // primary display; convert back to NSScreen space before comparing.
            let nsBounds = CGRect(
                x: cgBounds.minX,
                y: primaryScreenHeight - cgBounds.maxY,
                width: cgBounds.width,
                height: cgBounds.height
            )

            // Fullscreen: window covers the entire NSScreen.frame (including
            // the menubar area). Maximized: window fills a full axis of the
            // visibleFrame flush against Docky's edge, so it falls behind
            // Docky. This catches a true maximize (all four edges flush) as
            // well as a half tile that spans the full axis touching Docky
            // (e.g. tiled right with Docky on the right, or tiled top with
            // Docky on either side), which a strict visibleFrame match misses.
            if Self.rect(nsBounds, matches: frame) {
                fullscreenCandidate = true
                fullscreenCandidateCount += 1
                if let ownerPID { fullscreenCandidatePIDs.insert(ownerPID) }
            } else if Self.fillsFullAxisBehindDock(nsBounds, visibleFrame: visibleFrame, dockSide: dockSide) {
                foundMaximized = true
                maximizedCandidateCount += 1
            }
        }

        let geometryReportsFullscreen = fullscreenSpaceState == nil
            && fullscreenCandidate
            && registryReportsFullscreenWindow(
                candidatePIDs: fullscreenCandidatePIDs,
                matching: frame,
                primaryScreenHeight: primaryScreenHeight
            )
        let foundFullscreen = fullscreenSpaceState ?? geometryReportsFullscreen

        let fullscreenSource: String
        if fullscreenSpaceState != nil {
            fullscreenSource = "spaceType"
        } else if geometryReportsFullscreen {
            fullscreenSource = "geometryAndAX"
        } else {
            fullscreenSource = "geometryAndAXNoMatch"
        }

        return ContentOverlapObservation(
            isFullscreen: foundFullscreen,
            isMaximized: foundMaximized,
            spaceID: spaceSnapshot.spaceID,
            spaceType: spaceSnapshot.rawType,
            fullscreenSource: fullscreenSource,
            inspectedWindowCount: inspectedWindowCount,
            fullscreenCandidateCount: fullscreenCandidateCount,
            maximizedCandidateCount: maximizedCandidateCount
        )
    }

    private func registryReportsFullscreenWindow(
        candidatePIDs: Set<pid_t>,
        matching frame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> Bool {
        func fills(_ window: AppWindow) -> Bool {
            guard !window.isMinimized, let axFrame = window.frame else { return false }
            let nsFrame = CGRect(
                x: axFrame.minX,
                y: primaryScreenHeight - axFrame.maxY,
                width: axFrame.width,
                height: axFrame.height
            )
            return Self.rect(nsFrame, matches: frame, tolerance: 2)
        }

        for pid in candidatePIDs {
            if WindowRegistry.shared.liveWindows(for: pid).contains(where: fills) {
                return true
            }
        }

        return WindowRegistry.shared.windows.contains(where: fills)
    }

    private static func rect(_ a: CGRect, matches b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) < tolerance
            && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    /// True when `rect` fills a full axis of `visibleFrame` (at least three
    /// edges flush, i.e. a half tile or full maximize) AND is flush against
    /// the edge Docky occupies, meaning it extends into Docky's strip. A
    /// window with a non-flush edge on Docky's side (e.g. tiled to the
    /// opposite half) stays clear and returns false.
    private static func fillsFullAxisBehindDock(
        _ rect: CGRect,
        visibleFrame: CGRect,
        dockSide: ResolvedDockWindowPosition,
        tolerance: CGFloat = 2
    ) -> Bool {
        let flushLeft = abs(rect.minX - visibleFrame.minX) < tolerance
        let flushRight = abs(rect.maxX - visibleFrame.maxX) < tolerance
        let flushBottom = abs(rect.minY - visibleFrame.minY) < tolerance
        let flushTop = abs(rect.maxY - visibleFrame.maxY) < tolerance

        let flushCount = [flushLeft, flushRight, flushBottom, flushTop].filter { $0 }.count
        guard flushCount >= 3 else { return false }

        switch dockSide {
        case .left: return flushLeft
        case .right: return flushRight
        case .bottom: return flushBottom
        case .top: return flushTop
        }
    }
}
