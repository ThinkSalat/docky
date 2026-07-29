//
//  WindowSwitcherService.swift
//  Docky
//

import AppKit
import Carbon
import Combine

struct FocusedWindowPreview {
    let windowIdentifier: String
    let image: NSImage
    let screenBounds: CGRect
}

final class WindowSwitcherService: ObservableObject {
    static let shared = WindowSwitcherService()

    @Published private(set) var isPresented = false
    @Published private(set) var windows: [AppWindow] = []
    @Published private(set) var windowPreviews: [String: NSImage] = [:]
    @Published private(set) var selectedWindowIdentifier: String?
    @Published private(set) var isContextMenuPresented = false
    @Published private(set) var focusedPreview: FocusedWindowPreview?

    private let hotKeyBackend: GlobalHotKeyBackend
    private var hotKeyRef: EventHotKeyRef?
    private var orphanedHotKeyRefs: [EventHotKeyRef] = []
    private var registeredShortcut: KeyboardShortcut?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hotKeyHandlerInstallationError: String?
    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var focusedPreviewTask: Task<Void, Never>?
    private var instantFocusTask: Task<Void, Never>?
    private let forwardHotKeyID = EventHotKeyID(signature: OSType(0x444B5957), id: 1)
    private let reverseHotKeyID = EventHotKeyID(signature: OSType(0x444B5957), id: 2)
    private var reverseHotKeyRef: EventHotKeyRef?

    var resolvedLayout: WindowSwitcherLayout {
        let canCapture = PermissionsService.shared.screenCapture == .granted
        return DockyPreferences.shared.windowSwitcherLayout.resolved(canCaptureThumbnails: canCapture)
    }

    private var activePreviewMode: WindowSwitcherPreviewMode? {
        // Both preview modes are thumbnail-mode features: in-place needs the
        // captured image to show behind the switcher, and instant-focus's
        // "see the real window come forward" UX fights with the list overlay.
        // In list mode the list itself is the preview substitute.
        guard DockyPreferences.shared.showsWindowSwitcherFocusPreview,
              resolvedLayout == .thumbnails else {
            return nil
        }

        return DockyPreferences.shared.windowSwitcherPreviewMode
    }

    private var usesInPlacePreview: Bool {
        activePreviewMode == .inPlace
    }

    private var usesInstantFocusPreview: Bool {
        activePreviewMode == .instantFocus
    }

    init(hotKeyBackend: GlobalHotKeyBackend = .live) {
        self.hotKeyBackend = hotKeyBackend
        installHotKeyHandlerIfNeeded()
        let initialResult = replaceHotKey(
            with: DockyPreferences.shared.windowSwitcherShortcut
        )
        DockyPreferences.shared
            .recordWindowSwitcherHotKeyRegistrationResult(
                initialResult
            )
        installEventMonitors()
        subscribeToPreferences()
        observeWindowPreviews()
    }

    deinit {
        unregisterHotKey()

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }

        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
    }

    func handleHotKeyPress(direction: Int) {
        guard DockyPreferences.shared.enablesWindowSwitcher else {
            dismiss()
            return
        }

        if isPresented {
            guard !windows.isEmpty else {
                dismiss()
                return
            }

            moveSelection(delta: direction)
            return
        }

        guard PermissionsService.shared.accessibility == .granted else {
            PermissionsService.shared.presentPermissionAlert(for: .accessibility, actionTitle: "switch between windows")
            return
        }

        let latestWindows = WindowRegistry.shared.switchable(
            includeMinimized: DockyPreferences.shared.includesMinimizedWindows
        )

        windows = latestWindows
        freezeWindowPreviews(for: latestWindows)
        isPresented = true

        if latestWindows.isEmpty {
            // Show the chrome with a "No windows available" message
            // instead of silently no-op'ing — confirming the shortcut
            // worked and there's just nothing to switch to.
            selectedWindowIdentifier = nil
            return
        }

        let initialIndex: Int
        if latestWindows.count <= 1 {
            initialIndex = 0
        } else if direction < 0 {
            initialIndex = latestWindows.count - 1
        } else {
            initialIndex = 1
        }
        selectWindow(at: initialIndex)
    }

    func confirmSelection() {
        guard let selectedWindow else {
            dismiss()
            return
        }

        dismiss()

        Task {
            _ = await WindowRegistry.shared.focus(selectedWindow)
        }
    }

    func dismiss() {
        cancelFocusedPreview()
        isPresented = false
        isContextMenuPresented = false
        selectedWindowIdentifier = nil
        // Defer the windows/previews wipe past the overlay's fade-out
        // (0.18s in WindowSwitcherOverlayWindowController) so the chrome
        // keeps rendering its last frame and doesn't flash to the
        // "No windows available" card mid-dismiss. The next show pass
        // overwrites both arrays anyway, so this only matters as a
        // visual cushion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isPresented else { return }
            self.windows = []
            self.windowPreviews = [:]
        }
    }

    func moveSelection(delta: Int) {
        guard !windows.isEmpty else { return }

        let currentIndex = selectedWindow.flatMap { window in
            windows.firstIndex { $0.windowIdentifier == window.windowIdentifier }
        } ?? 0
        selectWindow(at: currentIndex + delta)
    }

    func selectWindow(withIdentifier identifier: String) {
        guard windows.contains(where: { $0.windowIdentifier == identifier }) else {
            return
        }

        selectedWindowIdentifier = identifier

        if usesInstantFocusPreview {
            cancelFocusedPreview()
            focusSelectedWindowImmediately(identifier: identifier)
            return
        }

        scheduleFocusedPreview(forWindowIdentifier: identifier)
    }

    func setContextMenuPresented(_ isPresented: Bool) {
        isContextMenuPresented = isPresented

        if isPresented {
            cancelFocusedPreview()
        }

        guard !isPresented else {
            return
        }

        dismissIfShortcutReleased(flags: NSEvent.modifierFlags)
    }

    func minimizeSelectedWindow() {
        guard let window = selectedWindow else { return }
        Task { [weak self] in
            if await WorkspaceService.shared.minimize(window: window) {
                self?.removeWindow(
                    withIdentifier: window.windowIdentifier
                )
            }
        }
    }

    func closeSelectedWindow() {
        guard let window = selectedWindow else { return }
        Task { [weak self] in
            if await WorkspaceService.shared.close(window: window) {
                self?.removeWindow(
                    withIdentifier: window.windowIdentifier
                )
            }
        }
    }

    func zoomSelectedWindow() {
        guard let window = selectedWindow else { return }
        // Bypass WorkspaceService.zoom's focus side-effect: focusing the target
        // window would yank key status from the switcher overlay and break the
        // local key monitor, so subsequent shortcuts would stop working.
        Task {
            _ = await WindowRegistry.shared.zoom(window)
        }
    }

    func removeWindow(withIdentifier identifier: String) {
        guard let removedIndex = windows.firstIndex(where: { $0.windowIdentifier == identifier }) else {
            return
        }

        windows.remove(at: removedIndex)
        windowPreviews.removeValue(forKey: identifier)

        guard !windows.isEmpty else {
            dismiss()
            return
        }

        let nextIndex = min(removedIndex, windows.count - 1)
        selectWindow(withIdentifier: windows[nextIndex].windowIdentifier)
    }

    private var selectedWindow: AppWindow? {
        guard let selectedWindowIdentifier else {
            return nil
        }

        return windows.first { $0.windowIdentifier == selectedWindowIdentifier }
    }

    private func subscribeToPreferences() {
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.showsWindowSwitcherFocusPreview
            _ = DockyPreferences.shared.windowSwitcherPreviewMode
            _ = DockyPreferences.shared.windowSwitcherLayout
            self?.refreshSelectionPresentation()
        }
        .store(in: &cancellables)

        PermissionsService.shared.$screenCapture
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSelectionPresentation()
            }
            .store(in: &cancellables)

        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateGlobalEventMonitors()
            }
            .store(in: &cancellables)
    }

    private func observeWindowPreviews() {
        WorkspaceService.shared.$appWindowPreviews
            .receive(on: DispatchQueue.main)
            .sink { [weak self] previews in
                self?.mergeWindowPreviews(previews)
            }
            .store(in: &cancellables)
    }

    private func installEventMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented else {
                return event
            }

            switch event.keyCode {
            case 53:
                self.dismiss()
                return nil
            case 36, 76:
                self.confirmSelection()
                return nil
            case 123, 126:
                self.moveSelection(delta: -1)
                return nil
            case 124, 125:
                self.moveSelection(delta: 1)
                return nil
            default:
                break
            }

            // User-configurable action keys. Navigation cases above take
            // precedence — if a user rebinds an action onto an arrow / Escape /
            // Return key, the built-in nav wins and the action never fires.
            let prefs = DockyPreferences.shared
            switch event.keyCode {
            case prefs.switcherMinimizeKeyCode:
                self.minimizeSelectedWindow()
                return nil
            case prefs.switcherCloseKeyCode:
                self.closeSelectedWindow()
                return nil
            case prefs.switcherZoomKeyCode:
                self.zoomSelectedWindow()
                return nil
            default:
                return event
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierReleaseIfNeeded(flags: event.modifierFlags)
            return event
        }

        updateGlobalEventMonitors()
    }

    private func updateGlobalEventMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }

        guard PermissionsService.shared.accessibility == .granted else {
            return
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierReleaseIfNeeded(flags: event.modifierFlags)
        }
    }

    private func handleModifierReleaseIfNeeded(flags: NSEvent.ModifierFlags) {
        guard isPresented else { return }
        guard !isContextMenuPresented else { return }

        let requiredFlags = DockyPreferences.shared.windowSwitcherShortcut.modifierFlags
        let activeFlags = flags.intersection(KeyboardShortcut.supportedModifierFlags)
        guard !requiredFlags.isEmpty, !activeFlags.isSuperset(of: requiredFlags) else {
            return
        }

        confirmSelection()
    }

    private func dismissIfShortcutReleased(flags: NSEvent.ModifierFlags) {
        guard isPresented else { return }

        let requiredFlags = DockyPreferences.shared.windowSwitcherShortcut.modifierFlags
        let activeFlags = flags.intersection(KeyboardShortcut.supportedModifierFlags)
        guard !requiredFlags.isEmpty, !activeFlags.isSuperset(of: requiredFlags) else {
            return
        }

        dismiss()
    }

    private func selectWindow(at index: Int) {
        guard !windows.isEmpty else {
            selectedWindowIdentifier = nil
            return
        }

        let wrappedIndex = ((index % windows.count) + windows.count) % windows.count
        selectWindow(withIdentifier: windows[wrappedIndex].windowIdentifier)
    }

    private func freezeWindowPreviews(for windows: [AppWindow]) {
        var previews: [String: NSImage] = [:]

        for window in windows {
            if let preview = WorkspaceService.shared.appWindowPreview(for: window) {
                previews[window.windowIdentifier] = preview
            }
        }

        windowPreviews = previews
    }

    private func mergeWindowPreviews(_ previews: [String: NSImage]) {
        guard isPresented, !windows.isEmpty else {
            return
        }

        var updatedPreviews = windowPreviews
        var didChange = false

        for window in windows {
            guard updatedPreviews[window.windowIdentifier] == nil,
                  let preview = previews[window.windowIdentifier] else {
                continue
            }

            updatedPreviews[window.windowIdentifier] = preview
            didChange = true
        }

        if didChange {
            windowPreviews = updatedPreviews
        }
    }

    func windowPreview(for window: AppWindow) -> NSImage? {
        windowPreviews[window.windowIdentifier]
    }

    private func cancelFocusedPreview() {
        focusedPreviewTask?.cancel()
        focusedPreviewTask = nil
        instantFocusTask?.cancel()
        instantFocusTask = nil
        WorkspaceService.shared.stopLiveFocusPreview()
        focusedPreview = nil
    }

    private func refreshSelectionPresentation() {
        guard let selectedWindowIdentifier else {
            cancelFocusedPreview()
            return
        }

        if usesInstantFocusPreview {
            cancelFocusedPreview()
            focusSelectedWindowImmediately(identifier: selectedWindowIdentifier)
            return
        }

        if usesInPlacePreview {
            scheduleFocusedPreview(forWindowIdentifier: selectedWindowIdentifier)
        } else {
            cancelFocusedPreview()
        }
    }

    private func focusSelectedWindowImmediately(identifier: String) {
        guard isPresented,
              let window = windows.first(where: { $0.windowIdentifier == identifier }) else {
            return
        }

        instantFocusTask = Task { [weak self] in
            _ = await WorkspaceService.shared.focus(window: window)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.instantFocusTask?.isCancelled == false else {
                    return
                }
                self?.instantFocusTask = nil
            }
        }
    }

    private func scheduleFocusedPreview(forWindowIdentifier identifier: String) {
        focusedPreviewTask?.cancel()
        focusedPreviewTask = nil

        focusedPreview = nil

        guard usesInPlacePreview,
              isPresented,
              !isContextMenuPresented,
              windows.contains(where: { $0.windowIdentifier == identifier }) else {
            return
        }

        focusedPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))

            await self?.runFocusedPreviewLoop(forWindowIdentifier: identifier)
        }
    }

    private func runFocusedPreviewLoop(forWindowIdentifier identifier: String) async {
        guard usesInPlacePreview,
              isPresented,
              !isContextMenuPresented,
              selectedWindowIdentifier == identifier,
              let window = windows.first(where: { $0.windowIdentifier == identifier }),
              let screenBounds = window.screenBounds,
              !screenBounds.isEmpty else {
            focusedPreview = nil
            return
        }

        let startedLivePreview = await WorkspaceService.shared.startLiveFocusPreview(for: window) { [weak self] image in
            guard let self,
                  self.isPresented,
                  !self.isContextMenuPresented,
                  self.selectedWindowIdentifier == identifier,
                  let image else {
                return
            }

            self.focusedPreview = FocusedWindowPreview(
                windowIdentifier: identifier,
                image: image,
                screenBounds: screenBounds
            )
        }

        guard !startedLivePreview else { return }

        while !Task.isCancelled {
            guard usesInPlacePreview,
                  isPresented,
                  !isContextMenuPresented,
                  selectedWindowIdentifier == identifier,
                  let currentWindow = windows.first(where: { $0.windowIdentifier == identifier }),
                  let currentScreenBounds = currentWindow.screenBounds,
                  !currentScreenBounds.isEmpty else {
                focusedPreview = nil
                return
            }

            if let image = await WorkspaceService.shared.liveFocusPreviewImage(for: currentWindow) {
                focusedPreview = FocusedWindowPreview(
                    windowIdentifier: identifier,
                    image: image,
                    screenBounds: currentScreenBounds
                )
            }

            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let service = Unmanaged<WindowSwitcherService>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr,
                  hotKeyID.signature == service.forwardHotKeyID.signature else {
                return OSStatus(eventNotHandledErr)
            }

            let direction = hotKeyID.id == service.reverseHotKeyID.id ? -1 : 1

            Task { @MainActor in
                service.handleHotKeyPress(direction: direction)
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        guard status == noErr, hotKeyHandlerRef != nil else {
            hotKeyHandlerRef = nil
            hotKeyHandlerInstallationError =
                "Window Switcher could not install its global shortcut "
                + "event handler (OSStatus \(status))."
            return
        }
        hotKeyHandlerInstallationError = nil
    }

    @discardableResult
    func replaceHotKey(
        with shortcut: KeyboardShortcut
    ) -> GlobalHotKeyRegistrationResult {
        reconcileHotKey(
            isEnabled:
                DockyPreferences.shared.enablesWindowSwitcher,
            shortcut: shortcut,
            validatesRequestedShortcut: true
        )
    }

    @discardableResult
    func setEnabled(
        _ isEnabled: Bool,
        shortcut: KeyboardShortcut
    ) -> GlobalHotKeyRegistrationResult {
        reconcileHotKey(
            isEnabled: isEnabled,
            shortcut: shortcut,
            validatesRequestedShortcut: isEnabled
        )
    }

    private func reconcileHotKey(
        isEnabled: Bool,
        shortcut: KeyboardShortcut,
        validatesRequestedShortcut: Bool
    ) -> GlobalHotKeyRegistrationResult {
        if hotKeyHandlerRef == nil {
            installHotKeyHandlerIfNeeded()
        }
        if let hotKeyHandlerInstallationError {
            return .failed(hotKeyHandlerInstallationError)
        }

        if let recoveryError = healTrackedRegistrationIfNeeded() {
            return .failed(recoveryError)
        }

        if let cleanupError = retryOrphanCleanup() {
            return .failed(cleanupError)
        }

        if validatesRequestedShortcut {
            switch WindowSwitcherBaseShortcutPolicy.validate(
                isConfigured: shortcut.isValid,
                containsShift:
                    shortcut.modifierFlags.contains(.shift)
            ) {
            case .accepted, .inactive:
                break
            case .rejected(let message):
                return .failed(message)
            }
        }

        guard isEnabled, shortcut.isValid else {
            if let cleanupError = unregisterHotKey() {
                let rollbackDetail: String
                if let rollbackError =
                    healTrackedRegistrationIfNeeded()
                {
                    rollbackDetail =
                        " Restoring the previously confirmed shortcut "
                        + "also failed: \(rollbackError)"
                } else {
                    rollbackDetail =
                        " The previously confirmed shortcut was restored."
                }
                return .failed(cleanupError + rollbackDetail)
            }
            return .inactive
        }

        if registeredShortcut == shortcut,
           hotKeyRef != nil,
           reverseHotKeyRef != nil {
            return .registered
        }

        let forwardCandidate = hotKeyBackend.register(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            forwardHotKeyID
        )
        guard forwardCandidate.status == noErr,
              let forwardCandidateRef =
                  forwardCandidate.reference else {
            return .failed(
                hotKeyFailureMessage(
                    direction: "forward",
                    status: forwardCandidate.status
                )
            )
        }

        let reverseCandidate = hotKeyBackend.register(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags | UInt32(shiftKey),
            reverseHotKeyID
        )
        guard reverseCandidate.status == noErr,
              let reverseCandidateRef =
                  reverseCandidate.reference else {
            let cleanupStatus =
                hotKeyBackend.unregister(forwardCandidateRef)
            var cleanupDetail = ""
            if cleanupStatus != noErr {
                orphanedHotKeyRefs.append(forwardCandidateRef)
                cleanupDetail =
                    " Cleanup of the forward candidate also failed "
                    + "(OSStatus \(cleanupStatus)); Docky retained its "
                    + "reference and will retry."
            }
            return .failed(
                hotKeyFailureMessage(
                    direction: "reverse",
                    status: reverseCandidate.status
                )
                    + cleanupDetail
            )
        }

        let previousForwardRef = hotKeyRef
        let previousReverseRef = reverseHotKeyRef

        if let previousForwardRef {
            let status =
                hotKeyBackend.unregister(previousForwardRef)
            guard status == noErr else {
                let cleanupDetail = cleanupCandidatePair(
                    forwardCandidateRef,
                    reverseCandidateRef
                )
                return .failed(
                    "Window Switcher registered the candidate shortcuts "
                        + "but could not remove the previous forward "
                        + "shortcut (OSStatus \(status)). The saved "
                        + "shortcut was not changed."
                        + cleanupDetail
                )
            }
            hotKeyRef = nil
        }

        if let previousReverseRef {
            let status =
                hotKeyBackend.unregister(previousReverseRef)
            guard status == noErr else {
                let cleanupDetail = cleanupCandidatePair(
                    forwardCandidateRef,
                    reverseCandidateRef
                )
                let rollbackDetail: String
                if let rollbackError =
                    healTrackedRegistrationIfNeeded()
                {
                    rollbackDetail =
                        " Restoring the previous shortcut pair also failed: "
                        + rollbackError
                } else {
                    rollbackDetail =
                        " The previous shortcut pair was restored."
                }
                return .failed(
                    "Window Switcher registered the candidate shortcuts "
                        + "but could not remove the previous reverse "
                        + "shortcut (OSStatus \(status)). The saved "
                        + "shortcut was not changed."
                        + cleanupDetail
                        + rollbackDetail
                )
            }
            reverseHotKeyRef = nil
        }

        hotKeyRef = forwardCandidateRef
        reverseHotKeyRef = reverseCandidateRef
        registeredShortcut = shortcut
        return .registered
    }

    @discardableResult
    private func unregisterHotKey() -> String? {
        var failures: [String] = []
        if let hotKeyRef {
            let status = hotKeyBackend.unregister(hotKeyRef)
            if status == noErr {
                self.hotKeyRef = nil
            } else {
                failures.append("forward OSStatus \(status)")
            }
        }

        if let reverseHotKeyRef {
            let status = hotKeyBackend.unregister(reverseHotKeyRef)
            if status == noErr {
                self.reverseHotKeyRef = nil
            } else {
                failures.append("reverse OSStatus \(status)")
            }
        }

        if let cleanupError = retryOrphanCleanup() {
            failures.append(cleanupError)
        }

        guard failures.isEmpty else {
            return "Window Switcher could not unregister every tracked "
                + "global shortcut "
                + "(\(failures.joined(separator: "; "))). References and "
                + "confirmed shortcut metadata were retained for retry."
        }

        registeredShortcut = nil
        return nil
    }

    private func cleanupCandidatePair(
        _ forward: EventHotKeyRef,
        _ reverse: EventHotKeyRef
    ) -> String {
        var failedStatuses: [OSStatus] = []
        for reference in [forward, reverse] {
            let status = hotKeyBackend.unregister(reference)
            if status != noErr {
                orphanedHotKeyRefs.append(reference)
                failedStatuses.append(status)
            }
        }

        guard !failedStatuses.isEmpty else {
            return ""
        }
        return " Candidate rollback also failed "
            + "(OSStatus "
            + failedStatuses.map(String.init).joined(separator: ", ")
            + "); Docky retained those references and will retry."
    }

    private func healTrackedRegistrationIfNeeded() -> String? {
        guard let registeredShortcut else {
            guard hotKeyRef == nil, reverseHotKeyRef == nil else {
                return "Window Switcher retained a registration without "
                    + "enough shortcut metadata to repair it safely."
            }
            return nil
        }

        guard hotKeyRef == nil || reverseHotKeyRef == nil else {
            return nil
        }

        switch WindowSwitcherBaseShortcutPolicy.validate(
            isConfigured: registeredShortcut.isValid,
            containsShift:
                registeredShortcut.modifierFlags.contains(.shift)
        ) {
        case .accepted:
            break
        case .inactive, .rejected:
            return "Window Switcher cannot repair the previously saved "
                + "shortcut because its forward and reverse chords are "
                + "not distinct."
        }

        if hotKeyRef == nil {
            let forward = hotKeyBackend.register(
                UInt32(registeredShortcut.keyCode),
                registeredShortcut.carbonModifierFlags,
                forwardHotKeyID
            )
            guard forward.status == noErr,
                  let forwardRef = forward.reference else {
                return "Window Switcher could not restore the previous "
                    + "forward shortcut (OSStatus \(forward.status)). "
                    + "Its registration state was retained for retry."
            }
            hotKeyRef = forwardRef
        }

        if reverseHotKeyRef == nil {
            let reverse = hotKeyBackend.register(
                UInt32(registeredShortcut.keyCode),
                registeredShortcut.carbonModifierFlags
                    | UInt32(shiftKey),
                reverseHotKeyID
            )
            guard reverse.status == noErr,
                  let reverseRef = reverse.reference else {
                return "Window Switcher could not restore the previous "
                    + "reverse shortcut (OSStatus \(reverse.status)). "
                    + "Its registration state was retained for retry."
            }
            reverseHotKeyRef = reverseRef
        }

        return nil
    }

    private func retryOrphanCleanup() -> String? {
        guard !orphanedHotKeyRefs.isEmpty else {
            return nil
        }

        var retained: [EventHotKeyRef] = []
        var statuses: [OSStatus] = []
        for reference in orphanedHotKeyRefs {
            let status = hotKeyBackend.unregister(reference)
            if status != noErr {
                retained.append(reference)
                statuses.append(status)
            }
        }
        orphanedHotKeyRefs = retained

        guard !statuses.isEmpty else {
            return nil
        }
        return "Window Switcher could not clean up candidate global "
            + "shortcuts (OSStatus "
            + statuses.map(String.init).joined(separator: ", ")
            + ")."
    }

    private func hotKeyFailureMessage(
        direction: String,
        status: OSStatus
    ) -> String {
        "Window Switcher could not register the \(direction) global "
            + "shortcut (OSStatus \(status)). Another app or system "
            + "shortcut may already be using it. The previous shortcut "
            + "was kept."
    }
}
