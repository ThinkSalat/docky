//
//  CGSPrivate.swift
//  Docky
//
//  SkyLight (CoreGraphics Services) SPI. Not for App Store submission without review.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

typealias CGSConnectionID = Int

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

// Returns the session-local SkyLight space ID for the currently-active
// Mission Control Space on the focused display. This number is never persisted.
@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ connection: CGSConnectionID) -> UInt64

// Returns 0 for a regular desktop Space and 4 for a native fullscreen
// or tiled-window Space on current macOS releases.
@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ connection: CGSConnectionID, _ space: UInt64) -> Int32

// These SLS symbols are present in SkyLight but are not linkable API. Resolve
// them optionally at runtime; the managed-display dictionary and monotonic
// reconciler remain fail-closed fallbacks when a release removes a symbol.
private let spaceIdentitySkyLightHandle:
    UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_LAZY | RTLD_LOCAL
)

private typealias SLSSpaceCopyNameFunction =
    @convention(c) (CGSConnectionID, UInt64)
        -> Unmanaged<CFString>?
private typealias SLSManagedDisplayGetCurrentSpaceFunction =
    @convention(c) (CGSConnectionID, CFString) -> UInt64
private typealias SLSManagedDisplayIsAnimatingFunction =
    @convention(c) (CGSConnectionID, CFString) -> Bool

private func persistentSpaceName(
    connection: CGSConnectionID,
    spaceID: UInt64
) -> String? {
    guard let spaceIdentitySkyLightHandle,
          let symbol = dlsym(
              spaceIdentitySkyLightHandle,
              "SLSSpaceCopyName"
          )
    else {
        return nil
    }
    let function = unsafeBitCast(
        symbol,
        to: SLSSpaceCopyNameFunction.self
    )
    return function(connection, spaceID)?
        .takeRetainedValue() as String?
}

private func managedDisplayCurrentSpace(
    connection: CGSConnectionID,
    displayIdentifier: String
) -> UInt64? {
    guard let spaceIdentitySkyLightHandle,
          let symbol = dlsym(
              spaceIdentitySkyLightHandle,
              "SLSManagedDisplayGetCurrentSpace"
          )
    else {
        return nil
    }
    let function = unsafeBitCast(
        symbol,
        to: SLSManagedDisplayGetCurrentSpaceFunction.self
    )
    let spaceID = function(
        connection,
        displayIdentifier as CFString
    )
    return spaceID == 0 ? nil : spaceID
}

private func managedDisplayIsAnimating(
    connection: CGSConnectionID,
    displayIdentifier: String
) -> Bool {
    // Mature Space managers report that this SPI stopped returning reliable
    // animation state in macOS 14. Docky supports macOS 14 and newer, so the
    // monotonic quiet-window reconciler is the authority on supported systems.
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14 else {
        return false
    }
    guard let spaceIdentitySkyLightHandle,
          let symbol = dlsym(
              spaceIdentitySkyLightHandle,
              "SLSManagedDisplayIsAnimating"
          )
    else {
        return false
    }
    let function = unsafeBitCast(
        symbol,
        to: SLSManagedDisplayIsAnimatingFunction.self
    )
    return function(connection, displayIdentifier as CFString)
}

func activeSpaceSnapshot() -> ActiveSpaceSnapshot {
    let connection = CGSMainConnectionID()
    let spaceID = CGSGetActiveSpace(connection)
    guard spaceID != 0 else {
        return .unknown
    }

    let rawType = CGSSpaceGetType(connection, spaceID)
    return ActiveSpaceSnapshot(spaceID: spaceID, rawType: rawType)
}

func activeSpaceFullscreenState() -> Bool? {
    activeSpaceSnapshot().isFullscreen
}

// Returns the ordered list of spaces per managed display. Each element is
// a dictionary with `Display Identifier` and `Spaces` keys; `Spaces` is
// an ordered array of `{id64, uuid, type, …}` dicts. We use it to resolve
// the active space's 1-based positional index.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ connection: CGSConnectionID) -> Unmanaged<CFArray>?

/// Low-latency identity read for exact profile switching.
///
/// This follows the same primitive used by yabai: the numeric Space ID locates
/// the current runtime object and `SLSSpaceCopyName` supplies its persistent
/// name. Display membership and Desktop ordinal are presentation metadata, so
/// they do not gate an already-saved exact-name lookup. The fuller parser
/// below remains in place for assignment authorization, catalogs, and settled
/// generic-trigger evidence.
func fastActiveSpaceSnapshot(
    for screen: NSScreen?
) -> ActiveSpaceSnapshot {
    guard let screen,
          let screenNumber = screen.deviceDescription[
              NSDeviceDescriptionKey("NSScreenNumber")
          ] as? NSNumber
    else {
        return .unknown
    }
    let displayID = CGDirectDisplayID(screenNumber.uint32Value)
    let connection = CGSMainConnectionID()

    let physicalDisplayIdentifier =
        CGDisplayCreateUUIDFromDisplayID(displayID)
            .map {
                CFUUIDCreateString(
                    nil,
                    $0.takeRetainedValue()
                ) as String
            }
    let hasSeparateSpaces =
        NSScreen.screensHaveSeparateSpaces
    let managedDisplayIdentifier: String
    let identityDisplayScope: String
    if hasSeparateSpaces {
        guard let physicalDisplayIdentifier else {
            return .unknown
        }
        managedDisplayIdentifier = physicalDisplayIdentifier
        identityDisplayScope = physicalDisplayIdentifier
    } else {
        managedDisplayIdentifier = "Main"
        identityDisplayScope =
            MissionControlSpaceIdentity.sharedDisplayScope
    }

    // yabai's direct path: display UUID -> current volatile SID -> persistent
    // Space name. This avoids waiting for the larger managed-display
    // dictionary to become internally self-consistent after a transition.
    let directDisplayIdentifiers =
        [
            physicalDisplayIdentifier,
            managedDisplayIdentifier,
        ]
        .compactMap { $0 }
        .reduce(into: [String]()) { identifiers, value in
            if !identifiers.contains(value) {
                identifiers.append(value)
            }
        }
    for directDisplayIdentifier in directDisplayIdentifiers {
        if let spaceID = managedDisplayCurrentSpace(
            connection: connection,
            displayIdentifier: directDisplayIdentifier
        ),
           let spaceName = persistentSpaceName(
               connection: connection,
               spaceID: spaceID
           ) {
            return ActiveSpaceSnapshot(
                spaceID: spaceID,
                identity: MissionControlSpaceIdentity(
                    displayUUID: identityDisplayScope,
                    spaceUUID: spaceName
                ),
                rawType: CGSSpaceGetType(connection, spaceID),
                isAnimating: managedDisplayIsAnimating(
                    connection: connection,
                    displayIdentifier:
                        directDisplayIdentifier
                ),
                displayIdentifier:
                    managedDisplayIdentifier,
                displayOrdinal: nil
            )
        }
    }

    // Optional-SPI compatibility fallback. It still persists only the
    // SkyLight name/UUID, never the numeric ID or Desktop ordinal.
    guard let rawDisplays = CGSCopyManagedDisplaySpaces(connection)?
        .takeRetainedValue() as? [[String: Any]]
    else {
        return .unknown
    }

    guard let selection = ManagedDisplayTargetSelectionPolicy.select(
        displayIdentifiers: rawDisplays.map {
            $0["Display Identifier"] as? String
        },
        targetDisplayUUID: physicalDisplayIdentifier,
        spacesHaveSeparateSpaces: hasSeparateSpaces
    ) else {
        return .unknown
    }

    let display = rawDisplays[selection.index]
    guard let displayIdentifier =
            display["Display Identifier"] as? String,
          let currentSpaceDictionary =
            display["Current Space"] as? [String: Any],
          let currentSpace =
            managedSpaceObservation(currentSpaceDictionary)
    else {
        return .unknown
    }

    // Prefer the direct persistent-name SPI. The dictionary UUID is a
    // compatibility fallback for a macOS release where the optional symbol is
    // unavailable, never a positional or numeric persisted identity.
    let spaceName =
        persistentSpaceName(
            connection: connection,
            spaceID: currentSpace.spaceID
        )
        ?? currentSpace.spaceUUID
    return ActiveSpaceSnapshot(
        spaceID: currentSpace.spaceID,
        identity: MissionControlSpaceIdentity(
            displayUUID: selection.identityDisplayScope,
            spaceUUID: spaceName
        ),
        rawType: CGSSpaceGetType(
            connection,
            currentSpace.spaceID
        ),
        isAnimating: managedDisplayIsAnimating(
            connection: connection,
            displayIdentifier: displayIdentifier
        ),
        displayIdentifier: displayIdentifier,
        displayOrdinal: nil
    )
}

/// Returns the current Mission Control Space for the physical display backing
/// `screen`. Unlike `CGSGetActiveSpace`, this does not accidentally report the
/// focused display when Docky is configured for a different display.
///
/// `nil` fullscreen state is intentional when SkyLight's private schema cannot
/// be mapped unambiguously. Callers should retain their geometry fallback.
func activeSpaceSnapshot(for screen: NSScreen?) -> ActiveSpaceSnapshot {
    guard let screen,
          let screenNumber = screen.deviceDescription[
              NSDeviceDescriptionKey("NSScreenNumber")
          ] as? NSNumber
    else {
        return .unknown
    }
    let displayID = CGDirectDisplayID(screenNumber.uint32Value)

    let connection = CGSMainConnectionID()
    guard let rawDisplays = CGSCopyManagedDisplaySpaces(connection)?
        .takeRetainedValue() as? [[String: Any]]
    else {
        return .unknown
    }

    let targetUUID = CGDisplayCreateUUIDFromDisplayID(displayID)
        .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    guard let selection = ManagedDisplayTargetSelectionPolicy.select(
        displayIdentifiers: rawDisplays.map {
            $0["Display Identifier"] as? String
        },
        targetDisplayUUID: targetUUID,
        spacesHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces
    ),
          let record = managedDisplaySpaceRecord(
              rawDisplays[selection.index],
              connection: connection
          )
    else {
        return .unknown
    }

    let resolved = record.snapshot(
        identityDisplayScope: selection.identityDisplayScope
    )

    let liveRawType = CGSSpaceGetType(connection, resolved.spaceID)
    guard ManagedDisplaySpaceEvidencePolicy.rawTypesAgree(
        [
            resolved.rawType,
            liveRawType,
        ]
    ) else {
        return .unknown
    }
    if resolved.rawType == nil {
        return ActiveSpaceSnapshot(
            spaceID: resolved.spaceID,
            identity: resolved.identity,
            rawType: liveRawType,
            isAnimating: resolved.isAnimating,
            displayIdentifier: resolved.displayIdentifier,
            displayOrdinal: resolved.displayOrdinal
        )
    }
    return resolved
}

/// Returns presentation-only metadata for every currently-listed regular
/// Desktop on connected displays. Assignment matching never consumes this
/// catalog; it exists solely to give saved identities honest, recognizable
/// labels and to mark identities no longer present in the live topology.
func missionControlSpacePresentations()
    -> [MissionControlSpacePresentation] {
    let connection = CGSMainConnectionID()
    guard let rawDisplays = CGSCopyManagedDisplaySpaces(connection)?
        .takeRetainedValue() as? [[String: Any]]
    else {
        return []
    }

    let hasSeparateSpaces = NSScreen.screensHaveSeparateSpaces
    let connectedDisplayNames: [String: String] =
        NSScreen.screens.reduce(into: [:]) {
            result,
            screen in
            guard let screenNumber =
                    screen.deviceDescription[
                        NSDeviceDescriptionKey(
                            "NSScreenNumber"
                        )
                    ] as? NSNumber,
                  let uuid =
                    CGDisplayCreateUUIDFromDisplayID(
                        CGDirectDisplayID(
                            screenNumber.uint32Value
                        )
                    )
            else {
                return
            }
            let identifier =
                CFUUIDCreateString(
                    nil,
                    uuid.takeRetainedValue()
                ) as String
            result[
                DisplaySpaceSnapshotResolver
                    .normalizeDisplayIdentifier(identifier)
            ] = screen.localizedName
        }

    let rawDisplayIdentifiers = rawDisplays.map {
        $0["Display Identifier"] as? String
    }
    var candidates: [MissionControlSpacePresentation] = []
    for (rawIndex, display) in rawDisplays.enumerated() {
        guard let displayIdentifier =
                display["Display Identifier"] as? String,
              let selection =
                ManagedDisplayTargetSelectionPolicy.select(
                    displayIdentifiers: rawDisplayIdentifiers,
                    targetDisplayUUID: displayIdentifier,
                    spacesHaveSeparateSpaces: hasSeparateSpaces
                ),
              selection.index == rawIndex
        else {
            continue
        }
        let normalizedDisplay =
            DisplaySpaceSnapshotResolver
            .normalizeDisplayIdentifier(displayIdentifier)

        let displayName: String
        if hasSeparateSpaces {
            guard let connectedName =
                connectedDisplayNames[normalizedDisplay]
            else {
                // Ignore stale/disconnected managed-display records.
                continue
            }
            displayName = connectedName
        } else {
            guard normalizedDisplay == "main" else {
                continue
            }
            displayName = "All displays"
        }

        guard let rawListedSpaces =
                display["Spaces"] as? [[String: Any]]
        else {
            continue
        }
        let listedSpaces =
            rawListedSpaces.compactMap { dictionary
                -> ManagedDisplaySpaceObservation? in
                guard let observation =
                    managedSpaceObservation(dictionary)
                else {
                    return nil
                }
                let copiedSpaceName = persistentSpaceName(
                    connection: connection,
                    spaceID: observation.spaceID
                )
                let liveRawType = CGSSpaceGetType(
                    connection,
                    observation.spaceID
                )
                guard ManagedDisplaySpaceEvidencePolicy
                    .identifiersAgree(
                        [
                            copiedSpaceName,
                            observation.spaceUUID,
                        ]
                    ),
                      ManagedDisplaySpaceEvidencePolicy
                        .rawTypesAgree(
                            [
                                observation.rawType,
                                liveRawType,
                            ]
                        )
                else {
                    return nil
                }
                return ManagedDisplaySpaceObservation(
                    spaceID: observation.spaceID,
                    spaceUUID:
                        copiedSpaceName ?? observation.spaceUUID,
                    rawType:
                        observation.rawType ?? liveRawType
                )
            }
        guard listedSpaces.count == rawListedSpaces.count else {
            // A partial catalog would relabel every following Desktop with the
            // wrong ordinal, so omit this display until topology settles.
            continue
        }
        candidates +=
            MissionControlSpaceCatalogPolicy.presentations(
                displayIdentifier: displayIdentifier,
                displayName: displayName,
                listedSpaces: listedSpaces,
                spacesHaveSeparateSpaces: hasSeparateSpaces
            )
    }

    // Duplicate identities indicate a partially-updated topology. Omit them
    // rather than showing a confidently wrong display/ordinal label.
    let grouped = Dictionary(grouping: candidates, by: \.identity)
    return grouped.values.compactMap { values in
        values.count == 1 ? values[0] : nil
    }
    .sorted {
        if $0.displayName == $1.displayName {
            return $0.ordinal < $1.ordinal
        }
        return $0.displayName.localizedStandardCompare(
            $1.displayName
        ) == .orderedAscending
    }
}

private func managedDisplaySpaceRecord(
    _ display: [String: Any],
    connection: CGSConnectionID
) -> ManagedDisplaySpaceRecord? {
    guard let displayIdentifier =
            display["Display Identifier"] as? String,
          let currentSpaceDictionary =
            display["Current Space"] as? [String: Any],
          let currentSpace = managedSpaceObservation(
              currentSpaceDictionary
          )
    else {
        return nil
    }

    // A Collapsed Space belongs to an inactive/disconnected display and must
    // never be promoted to active state. Current Space is also accepted only
    // when the pure parser proves it occurs exactly once in Spaces.
    guard let rawListedSpaces =
            display["Spaces"] as? [[String: Any]]
    else {
        return nil
    }
    let listedSpaces = rawListedSpaces.compactMap(
        managedSpaceObservation
    )

    // Prefer the same persistent name API used by mature Space managers.
    // Preserve an empty returned string: it is the root Desktop's identity.
    let copiedSpaceName = persistentSpaceName(
        connection: connection,
        spaceID: currentSpace.spaceID
    )

    return ManagedDisplaySpaceRecordParser.parse(
        displayIdentifier: displayIdentifier,
        currentSpace: currentSpace,
        listedSpaces: listedSpaces,
        rawListedSpaceCount: rawListedSpaces.count,
        copiedSpaceName: copiedSpaceName,
        isAnimating: managedDisplayIsAnimating(
            connection: connection,
            displayIdentifier: displayIdentifier
        )
    )
}

private func managedSpaceObservation(
    _ space: [String: Any]
) -> ManagedDisplaySpaceObservation? {
    guard let spaceID =
            (space["id64"] as? NSNumber)?.uint64Value,
          spaceID != 0
    else {
        return nil
    }
    return ManagedDisplaySpaceObservation(
        spaceID: spaceID,
        spaceUUID: space["uuid"] as? String,
        rawType: (space["type"] as? NSNumber)?.int32Value
    )
}

// Returns the system CGWindowID backing an AX window element. Preferred over
// the AXWindowNumber attribute, which some apps populate with their own
// internal IDs rather than the system window number.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
nonisolated func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ wid: inout CGWindowID
) -> AXError

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
func CGSSetWindowBackgroundBlurRadius(
    _ connection: CGSConnectionID,
    _ windowID: Int,
    _ radius: Int
) -> Int32

// `CGWindowListCreateImage` follows the CoreFoundation Create Rule:
// the caller owns the returned reference (+1). Importing it via the
// public CoreGraphics header lets the clang `cf_returns_retained`
// audit balance ARC for us, but `@_silgen_name` bypasses that audit
// and Swift treats the return value as +0. The system still holds
// its +1, ARC emits an extra release at scope exit, and on Sequoia
// the freed slot gets reused fast enough that the next access
// SEGVs in `objc_release` (see the Sentry crash with
// `WorkspaceService.captureAppWindowPreview` at the top of the
// stack, with `rdi` holding a `Double`-shaped value reused from
// freed CGImage storage).
//
// Declaring the raw binding as `Unmanaged<CGImage>?` opts out of
// implicit ARC and lets us consume the +1 explicitly via
// `takeRetainedValue()` in the wrapper below. All five callers in
// `WorkspaceService.swift` keep working with a managed `CGImage?`.
@_silgen_name("CGWindowListCreateImage")
private func _CGWindowListCreateImagePrivate(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> Unmanaged<CGImage>?

func CGWindowListCreateImagePrivate(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> CGImage? {
    _CGWindowListCreateImagePrivate(
        screenBounds,
        listOption,
        windowID,
        imageOption
    )?.takeRetainedValue()
}

@_silgen_name("CGSGetWindowAlpha")
func CGSGetWindowAlpha(
    _ connection: CGSConnectionID,
    _ windowID: Int,
    _ alpha: UnsafeMutablePointer<Float>
) -> Int32

@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(
    _ connection: CGSConnectionID,
    _ windowID: Int,
    _ alpha: Float
) -> Int32

// MARK: - SkyLight Process Switching (SLPS)

nonisolated struct ProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

@_silgen_name("GetProcessForPID")
nonisolated func GetProcessForPID(
    _ pid: pid_t,
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>
) -> OSStatus

@_silgen_name("ShowHideProcess")
private func ShowHideProcess(
    _ psn: UnsafePointer<ProcessSerialNumber>,
    _ visible: UInt8
) -> Int16

/// Process Manager fallback for visibility changes. `NSRunningApplication`
/// can refuse `hide()` for another process when Docky's Accessibility grant
/// is stale, even though the classic process-level operation still succeeds.
@discardableResult
func setProcessVisible(pid: pid_t, visible: Bool) -> Bool {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(pid, &psn) == noErr else { return false }
    return ShowHideProcess(&psn, visible ? 1 : 0) == noErr
}

nonisolated enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

private typealias SLPSSetFrontProcessWithOptionsType = @convention(c) (
    UnsafeMutableRawPointer,
    CGWindowID,
    UInt32
) -> CGError

private typealias SLPSPostEventRecordToType = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutablePointer<UInt8>
) -> CGError

nonisolated(unsafe) private var skyLightHandle: UnsafeMutableRawPointer?
nonisolated(unsafe) private var setFrontProcessPtr:
    SLPSSetFrontProcessWithOptionsType?
nonisolated(unsafe) private var postEventRecordPtr:
    SLPSPostEventRecordToType?

// Single-threaded-by-convention: window focus paths run on the serialized AX
// worker, so the lazy load does not need a lock.
nonisolated private func loadSkyLightFunctions() {
    guard skyLightHandle == nil else { return }

    let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(skyLightPath, RTLD_LAZY) else { return }
    skyLightHandle = handle

    if let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") {
        setFrontProcessPtr = unsafeBitCast(symbol, to: SLPSSetFrontProcessWithOptionsType.self)
    }
    if let symbol = dlsym(handle, "SLPSPostEventRecordTo") {
        postEventRecordPtr = unsafeBitCast(symbol, to: SLPSPostEventRecordToType.self)
    }
}

@discardableResult
nonisolated func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ wid: CGWindowID,
    _ mode: SLPSMode.RawValue
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = setFrontProcessPtr else { return CGError(rawValue: -1)! }
    return fn(psn, wid, mode)
}

@discardableResult
nonisolated func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = postEventRecordPtr else { return CGError(rawValue: -1)! }
    return fn(psn, bytes)
}

// MARK: - Dock Notifications (HIServices)
//
// `CoreDockSendNotification` is the private function the system Dock invokes
// when its own menus pick "Show All Windows" / "Mission Control" / etc.
// Posting via `DistributedNotificationCenter` with the same name string does
// not route through the Dock and is a no-op. Loaded by dlsym because the
// symbol is not exported in the SDK.

private typealias CoreDockSendNotificationType = @convention(c) (CFString, Int32) -> Void
private var hiServicesHandle: UnsafeMutableRawPointer?
private var coreDockSendNotificationPtr: CoreDockSendNotificationType?

private func loadHIServicesFunctions() {
    guard hiServicesHandle == nil else { return }

    let hiServicesPath = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices"
    guard let handle = dlopen(hiServicesPath, RTLD_LAZY) else { return }
    hiServicesHandle = handle

    if let symbol = dlsym(handle, "CoreDockSendNotification") {
        coreDockSendNotificationPtr = unsafeBitCast(symbol, to: CoreDockSendNotificationType.self)
    }
}

func CoreDockSendNotification(_ message: String) {
    loadHIServicesFunctions()
    guard let fn = coreDockSendNotificationPtr else { return }
    fn(message as CFString, 0)
}

nonisolated func slpsMakeKeyWindow(
    psn: inout ProcessSerialNumber,
    windowID: CGWindowID
) {
    var bytes = [UInt8](repeating: 0, count: 0xF8)
    bytes[0x04] = 0xF8
    bytes[0x3A] = 0x10
    var wid = UInt32(windowID)
    memcpy(&bytes[0x3C], &wid, MemoryLayout<UInt32>.size)
    memset(&bytes[0x20], 0xFF, 0x10)
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes)
}
