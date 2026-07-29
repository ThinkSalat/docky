//
//  DockDragService.swift
//  Docky
//
//  Single source of truth for external drag-and-drop into the dock.
//  The NSView-side dragging destination writes drag kind + cursor location.
//  SwiftUI observes and computes the destination index from tile geometry,
//  writing it back so the renderer can splice in a preview tile.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Monotonic identity for the current real macOS Space interaction epoch.
///
/// Profile activation and settled topology are intentionally asynchronous, so
/// neither profile ID nor profile revision can prove that a drag still belongs
/// to the Desktop where it began. This observer runs directly from the
/// workspace lifecycle notification; every drag credential captures its
/// generation and fails closed as soon as macOS announces a Space change.
@MainActor
final class DockSpaceInteractionEpoch: ObservableObject {
    static let shared = DockSpaceInteractionEpoch()

    @Published private(set) var generation: UInt64 = 0

    private var activeSpaceObserver: NSObjectProtocol?

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        activeSpaceObserver = center.addObserver(
            forName:
                NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.generation &+= 1
            }
        }
    }
}

@MainActor
final class DockDragService: ObservableObject {
    static let shared = DockDragService()

    struct InteractionCredentials: Equatable {
        let profileID: String
        let revision: UInt64
        let spaceGeneration: UInt64
    }

    enum Kind: Equatable {
        case app(URL, AppTile)
        case folder(URL, FolderTile)
        case document([URL])
    }

    enum Section: Equatable {
        case pinned, trailing
    }

    @Published private(set) var kind: Kind?
    @Published var cursorLocation: CGPoint?
    @Published var destinationIndex: Int?
    @Published var destinationSection: Section?
    @Published var documentTargetTileID: String?
    /// App folder tile id that has spring-opened due to a sustained hover
    /// during an external drag. Mirrors macOS Finder spring-loaded folders:
    /// hover dwell triggers the popover so the user can drop on a sub-target.
    @Published var springLoadedTileID: String?
    /// Set when the active drag began from inside an app folder popover.
    /// Lets the drop handler remove the app from its source folder before
    /// pinning it at the destination, so dragging an icon out of a folder
    /// onto the dock relocates it instead of duplicating it.
    @Published var sourceFolderTileID: String?
    @Published var sourceFolderBundleIdentifier: String?
    private(set) var interactionCredentials:
        InteractionCredentials?
    private var interactionBeganAtDockySource = false
    private var interactionInvalidated = false
    private var draggingSequenceNumber: Int?

    private var springLoadCandidateTileID: String?
    private var springLoadWorkItem: DispatchWorkItem?
    private let springLoadDwell: TimeInterval = 0.7
    private var mouseReleasePoll: DispatchSourceTimer?

    private init() {}

    /// Starts a drag at its Docky-owned source. The destination-side
    /// `begin(kind:at:)` call preserves these credentials when the cursor
    /// subsequently enters or re-enters the dock window.
    func beginSource() {
        clear()
        interactionCredentials =
            currentInteractionCredentials()
        interactionBeganAtDockySource = true
    }

    func beginSource(kind: Kind) {
        beginSource()
        self.kind = kind
    }

    func begin(
        kind: Kind,
        at location: CGPoint,
        sequenceNumber: Int
    ) -> Bool {
        if interactionInvalidated {
            if interactionBeganAtDockySource
                && draggingSequenceNumber == nil {
                // The source profile changed before this Docky-owned drag
                // reached the destination. Bind its AppKit sequence only so
                // every re-entry of that same interaction remains rejected.
                draggingSequenceNumber = sequenceNumber
                interactionBeganAtDockySource = false
                return false
            }
            guard draggingSequenceNumber
                    != sequenceNumber else {
                return false
            }

            // A different AppKit sequence is a genuinely new external drag,
            // so the previous session tombstone no longer applies.
            clear()
        }

        if draggingSequenceNumber != sequenceNumber {
            let isUnboundDockySourceSession =
                interactionBeganAtDockySource
                && draggingSequenceNumber == nil
                && interactionCredentials != nil
            if !isUnboundDockySourceSession {
                interactionCredentials =
                    currentInteractionCredentials()
                sourceFolderTileID = nil
                sourceFolderBundleIdentifier = nil
            }
            draggingSequenceNumber = sequenceNumber
            // Once AppKit has bound the source interaction to a concrete
            // sequence, any later sequence is a new external drag and must
            // capture fresh credentials rather than inheriting this source.
            interactionBeganAtDockySource = false
        } else if interactionCredentials == nil {
            interactionCredentials =
                currentInteractionCredentials()
        }
        self.kind = kind
        self.cursorLocation = location
        guard hasCurrentInteractionCredentials(
            sequenceNumber: sequenceNumber
        ) else {
            invalidateCurrentInteraction(
                sequenceNumber: sequenceNumber
            )
            return false
        }
        return true
    }

    func updateCursor(_ location: CGPoint) {
        self.cursorLocation = location
    }

    func clear() {
        self.kind = nil
        interactionCredentials = nil
        interactionBeganAtDockySource = false
        interactionInvalidated = false
        draggingSequenceNumber = nil
        self.cursorLocation = nil
        self.destinationIndex = nil
        self.destinationSection = nil
        self.documentTargetTileID = nil
        self.sourceFolderTileID = nil
        self.sourceFolderBundleIdentifier = nil
        clearSpringLoad()
        cancelMouseReleasePoll()
    }

    func hasCurrentInteractionCredentials(
        sequenceNumber: Int
    ) -> Bool {
        guard !interactionInvalidated,
              draggingSequenceNumber == sequenceNumber,
              let interactionCredentials else {
            return false
        }
        let profileService = ProfileService.shared
        return interactionCredentials.profileID
                == profileService.activeProfileID
            && interactionCredentials.revision
                == profileService.stateRevision
            && interactionCredentials.spaceGeneration
                == DockSpaceInteractionEpoch.shared.generation
    }

    /// Permanently rejects the current AppKit drag without forgetting its
    /// sequence. Keeping this tombstone prevents the same still-live drag from
    /// being admitted as a fresh interaction after a profile switch.
    func invalidateCurrentInteraction(
        sequenceNumber: Int? = nil
    ) {
        if draggingSequenceNumber == nil,
           let sequenceNumber {
            draggingSequenceNumber = sequenceNumber
        }
        interactionInvalidated = true
        interactionCredentials = nil
        kind = nil
        cursorLocation = nil
        destinationIndex = nil
        destinationSection = nil
        documentTargetTileID = nil
        sourceFolderTileID = nil
        sourceFolderBundleIdentifier = nil
        clearSpringLoad()
    }

    private func currentInteractionCredentials()
        -> InteractionCredentials {
        let profileService = ProfileService.shared
        return InteractionCredentials(
            profileID: profileService.activeProfileID,
            revision: profileService.stateRevision,
            spaceGeneration:
                DockSpaceInteractionEpoch.shared.generation
        )
    }

    /// Polls the global mouse-button state and clears drag state when the
    /// primary button is released. Used by drags that begin OUTSIDE the dock
    /// window (e.g. dragging an icon out of an app folder popover) — the
    /// dock's `draggingEnded(_:)` only fires if the cursor passes through
    /// the dock view, so without this a drag that drops on the desktop or
    /// Finder would leave `kind` non-nil and freeze the dock visible.
    func armMouseReleaseCleanup() {
        cancelMouseReleasePoll()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var sawPressed =
            (NSEvent.pressedMouseButtons & 1) != 0
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            let pressed = (NSEvent.pressedMouseButtons & 1) != 0
            if pressed {
                sawPressed = true
            } else if sawPressed {
                self?.clear()
            }
        }
        timer.resume()
        mouseReleasePoll = timer
    }

    private func cancelMouseReleasePoll() {
        mouseReleasePoll?.cancel()
        mouseReleasePoll = nil
    }

    /// Schedules a spring-load for `tileID` after a brief dwell. Passing nil
    /// (or repeatedly passing the same id) preserves the candidate; a different
    /// non-nil id resets the timer for the new candidate. The opened popover
    /// stays open until the drag operation ends — close happens via clear().
    func updateSpringLoadCandidate(_ tileID: String?) {
        guard tileID != springLoadCandidateTileID else { return }
        springLoadCandidateTileID = tileID
        springLoadWorkItem?.cancel()
        springLoadWorkItem = nil

        guard let tileID, springLoadedTileID != tileID else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.springLoadCandidateTileID == tileID else { return }
            self.springLoadedTileID = tileID
        }
        springLoadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + springLoadDwell, execute: work)
    }

    private func clearSpringLoad() {
        springLoadWorkItem?.cancel()
        springLoadWorkItem = nil
        springLoadCandidateTileID = nil
        springLoadedTileID = nil
    }

    static func resolvePreview(from urls: [URL]) -> Kind? {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return nil }

        if let appURL = fileURLs.first(where: isDroppableApp),
           let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            let displayName = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
            IconCacheService.shared.preloadIcon(forBundleIdentifier: bundleIdentifier, fileURL: appURL)
            return .app(appURL, AppTile(bundleIdentifier: bundleIdentifier, displayName: displayName))
        }
        if let folderURL = fileURLs.first(where: isDroppableFolder) {
            let displayName = FileManager.default.displayName(atPath: folderURL.path)
            return .folder(folderURL, FolderTile(
                url: folderURL,
                displayName: displayName,
                displayMode: .contents
            ))
        }
        return .document(fileURLs)
    }

    private static func isDroppableApp(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .typeIdentifierKey])
        guard values?.isDirectory == true, values?.isPackage == true else { return false }
        return values?.typeIdentifier == UTType.application.identifier
    }

    private static func isDroppableFolder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
