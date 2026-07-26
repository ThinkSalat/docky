//
//  DisplaySpaceSnapshot.swift
//  Docky
//
//  Pure, host-testable mapping between a physical display identifier and
//  the current Mission Control Space reported for that display.
//

import Foundation

struct ActiveSpaceSnapshot: Equatable, Sendable {
    let spaceID: UInt64
    let rawType: Int32?
    let isFullscreen: Bool?

    static let unknown = ActiveSpaceSnapshot(
        spaceID: 0,
        rawType: nil,
        isFullscreen: nil
    )

    init(spaceID: UInt64, rawType: Int32?) {
        self.spaceID = spaceID
        self.rawType = rawType
        switch rawType {
        case 0:
            isFullscreen = false
        case 4:
            isFullscreen = true
        default:
            isFullscreen = nil
        }
    }

    init(spaceID: UInt64, rawType: Int32?, isFullscreen: Bool?) {
        self.spaceID = spaceID
        self.rawType = rawType
        self.isFullscreen = isFullscreen
    }
}

struct ManagedDisplaySpaceRecord: Equatable, Sendable {
    let displayIdentifier: String
    let spaceID: UInt64
    let rawType: Int32?

    var snapshot: ActiveSpaceSnapshot {
        ActiveSpaceSnapshot(spaceID: spaceID, rawType: rawType)
    }
}

enum DisplaySpaceSnapshotResolver {
    /// Resolves a current Space for the actual display Docky targets.
    ///
    /// SkyLight normally identifies displays with the same UUID returned by
    /// `CGDisplayCreateUUIDFromDisplayID`. Older/global-Space configurations
    /// can use the sentinel `Main` instead. A single-record result is safe as
    /// a last fallback because there is no competing display whose fullscreen
    /// state could be applied by mistake. Ambiguous multi-display input fails
    /// closed so callers can use their window-geometry fallback.
    static func resolve(
        records: [ManagedDisplaySpaceRecord],
        targetDisplayUUID: String?,
        targetIsMainDisplay: Bool
    ) -> ActiveSpaceSnapshot? {
        if let targetDisplayUUID {
            let normalizedTarget = normalizeDisplayIdentifier(targetDisplayUUID)
            if let exact = records.first(where: {
                normalizeDisplayIdentifier($0.displayIdentifier) == normalizedTarget
            }) {
                return exact.snapshot
            }
        }

        if targetIsMainDisplay,
           let main = records.first(where: {
               $0.displayIdentifier.compare(
                   "Main",
                   options: [.caseInsensitive, .diacriticInsensitive]
               ) == .orderedSame
           }) {
            return main.snapshot
        }

        if records.count == 1 {
            return records[0].snapshot
        }

        return nil
    }

    private static func normalizeDisplayIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .lowercased()
    }
}
