//
//  DisplaySpaceSnapshot.swift
//  Docky
//
//  Pure Mission Control identity, display resolution, and transition
//  reconciliation. Numeric SkyLight IDs are observations, never identities.
//

import Foundation

/// Durable identity for a Mission Control Space.
///
/// SkyLight gives ordinary Spaces a non-empty name/UUID. That value follows
/// the Space when it is reordered or moved to another display, so display
/// identity must not be part of the key. The root Desktop has an empty name;
/// only that special case is scoped to a physical display (or the shared
/// Mission Control display when "Displays have separate Spaces" is disabled).
nonisolated struct MissionControlSpaceIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable {
    static let sharedDisplayScope = "shared"

    let spaceUUID: String
    let rootDisplayScope: String?

    init?(displayUUID: String?, spaceUUID: String?) {
        guard let spaceUUID else { return nil }
        let normalizedSpaceUUID =
            DisplaySpaceSnapshotResolver.normalizeSpaceIdentifier(spaceUUID)
        self.spaceUUID = normalizedSpaceUUID

        if normalizedSpaceUUID.isEmpty {
            guard let displayUUID else { return nil }
            let normalizedDisplay =
                DisplaySpaceSnapshotResolver.normalizeDisplayIdentifier(
                    displayUUID
                )
            guard !normalizedDisplay.isEmpty else { return nil }
            rootDisplayScope = normalizedDisplay
        } else {
            // A named Space keeps its identity if Mission Control moves it to
            // another display.
            rootDisplayScope = nil
        }
    }

    /// Compatibility projection used only while decoding the previous
    /// per-trigger representation.
    var displayUUID: String? {
        rootDisplayScope
    }

    var storageKey: String {
        if let rootDisplayScope {
            return "root:\(rootDisplayScope)"
        }
        return "space:\(spaceUUID)"
    }

    private enum CodingKeys: String, CodingKey {
        case spaceUUID
        case rootDisplayScope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let spaceUUID = try container.decode(
            String.self,
            forKey: .spaceUUID
        )
        let rootScope = try container.decodeIfPresent(
            String.self,
            forKey: .rootDisplayScope
        )
        guard let identity = Self(
            displayUUID: rootScope,
            spaceUUID: spaceUUID
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .spaceUUID,
                in: container,
                debugDescription:
                    "A root Space requires a non-empty display scope."
            )
        }
        self = identity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spaceUUID, forKey: .spaceUUID)
        try container.encodeIfPresent(
            rootDisplayScope,
            forKey: .rootDisplayScope
        )
    }
}

/// One observation of the current Space on Docky's target display.
///
/// `spaceID`, display identifier, and ordinal are deliberately observational:
/// they make diagnostics and UI labels useful but never participate in a
/// persisted assignment.
nonisolated struct ActiveSpaceSnapshot: Equatable, Sendable {
    let spaceID: UInt64
    let identity: MissionControlSpaceIdentity?
    let rawType: Int32?
    let isAnimating: Bool
    let displayIdentifier: String?
    let displayOrdinal: Int?

    static let unknown = ActiveSpaceSnapshot(spaceID: 0, rawType: nil)

    init(
        spaceID: UInt64,
        identity: MissionControlSpaceIdentity? = nil,
        rawType: Int32?,
        isAnimating: Bool = false,
        displayIdentifier: String? = nil,
        displayOrdinal: Int? = nil
    ) {
        self.spaceID = spaceID
        self.identity = identity
        self.rawType = rawType
        self.isAnimating = isAnimating
        self.displayIdentifier = displayIdentifier
        self.displayOrdinal = displayOrdinal
    }

    var isFullscreen: Bool? {
        switch rawType {
        case 0:
            return false
        case 4:
            return true
        default:
            return nil
        }
    }

    /// Exact profile assignment is intentionally limited to user Desktop
    /// Spaces. Fullscreen/tiled Spaces can still use the app-on-Space trigger.
    var assignableIdentity: MissionControlSpaceIdentity? {
        rawType == 0 ? identity : nil
    }
}

nonisolated struct ManagedDisplaySpaceRecord: Equatable, Sendable {
    let displayIdentifier: String
    let spaceID: UInt64
    let spaceUUID: String?
    let rawType: Int32?
    let isAnimating: Bool
    let ordinal: Int?

    init(
        displayIdentifier: String,
        spaceID: UInt64,
        spaceUUID: String? = nil,
        rawType: Int32?,
        isAnimating: Bool = false,
        ordinal: Int? = nil
    ) {
        self.displayIdentifier = displayIdentifier
        self.spaceID = spaceID
        self.spaceUUID = spaceUUID
        self.rawType = rawType
        self.isAnimating = isAnimating
        self.ordinal = ordinal
    }

    func snapshot(identityDisplayScope: String) -> ActiveSpaceSnapshot {
        ActiveSpaceSnapshot(
            spaceID: spaceID,
            identity: MissionControlSpaceIdentity(
                displayUUID: identityDisplayScope,
                spaceUUID: spaceUUID
            ),
            rawType: rawType,
            isAnimating: isAnimating,
            displayIdentifier: displayIdentifier,
            displayOrdinal: ordinal
        )
    }
}

/// Primitive SkyLight Space data used by the pure managed-display parser.
///
/// Keeping the dictionary-to-model policy here makes the transition-sensitive
/// membership and ordinal rules host-testable without linking private APIs.
nonisolated struct ManagedDisplaySpaceObservation: Equatable, Sendable {
    let spaceID: UInt64
    let spaceUUID: String?
    let rawType: Int32?

    init(
        spaceID: UInt64,
        spaceUUID: String? = nil,
        rawType: Int32? = nil
    ) {
        self.spaceID = spaceID
        self.spaceUUID = spaceUUID
        self.rawType = rawType
    }
}

/// The one raw managed-display entry that is safe to parse for a target.
///
/// Selection happens before dictionary parsing so a malformed duplicate cannot
/// disappear through `compactMap` and make a conflicting topology look unique.
nonisolated struct ManagedDisplayTargetSelection: Equatable, Sendable {
    let index: Int
    let identityDisplayScope: String
}

nonisolated enum ManagedDisplayTargetSelectionPolicy {
    static func select(
        displayIdentifiers: [String?],
        targetDisplayUUID: String?,
        spacesHaveSeparateSpaces: Bool
    ) -> ManagedDisplayTargetSelection? {
        let targetIdentifier: String
        let identityDisplayScope: String

        if spacesHaveSeparateSpaces {
            guard let targetDisplayUUID else { return nil }
            targetIdentifier =
                DisplaySpaceSnapshotResolver.normalizeDisplayIdentifier(
                    targetDisplayUUID
                )
            guard !targetIdentifier.isEmpty else { return nil }
            identityDisplayScope = targetIdentifier
        } else {
            targetIdentifier = "main"
            identityDisplayScope =
                MissionControlSpaceIdentity.sharedDisplayScope
        }

        let matches = displayIdentifiers.enumerated().filter {
            guard let displayIdentifier = $0.element else {
                return false
            }
            return DisplaySpaceSnapshotResolver.normalizeDisplayIdentifier(
                displayIdentifier
            ) == targetIdentifier
        }
        guard matches.count == 1,
              let match = matches.first
        else {
            return nil
        }

        return ManagedDisplayTargetSelection(
            index: match.offset,
            identityDisplayScope: identityDisplayScope
        )
    }
}

nonisolated enum ManagedDisplaySpaceEvidencePolicy {
    static func identifiersAgree(_ values: [String?]) -> Bool {
        Set(
            values
                .compactMap { $0 }
                .map(
                    DisplaySpaceSnapshotResolver.normalizeSpaceIdentifier
                )
        ).count <= 1
    }

    static func rawTypesAgree(_ values: [Int32?]) -> Bool {
        Set(values.compactMap { $0 }).count <= 1
    }
}

/// Non-authoritative presentation metadata for one currently-listed regular
/// Desktop. The durable assignment key remains `identity`; display and ordinal
/// are only labels and may change when Mission Control reorders or moves it.
nonisolated struct MissionControlSpacePresentation:
    Equatable,
    Identifiable,
    Sendable {
    let identity: MissionControlSpaceIdentity
    let displayIdentifier: String
    let displayName: String
    let ordinal: Int

    var id: String { identity.storageKey }
}

nonisolated enum MissionControlSpaceCatalogPolicy {
    static func presentations(
        displayIdentifier: String,
        displayName: String,
        listedSpaces: [ManagedDisplaySpaceObservation],
        spacesHaveSeparateSpaces: Bool
    ) -> [MissionControlSpacePresentation] {
        let normalizedDisplay =
            DisplaySpaceSnapshotResolver.normalizeDisplayIdentifier(
                displayIdentifier
            )
        guard !normalizedDisplay.isEmpty else { return [] }

        let rootScope = spacesHaveSeparateSpaces
            ? normalizedDisplay
            : MissionControlSpaceIdentity.sharedDisplayScope
        var ordinal = 0
        return listedSpaces.compactMap { space in
            guard space.rawType == 0 else { return nil }
            ordinal += 1
            guard let identity = MissionControlSpaceIdentity(
                displayUUID: rootScope,
                spaceUUID: space.spaceUUID
            ) else {
                return nil
            }
            return MissionControlSpacePresentation(
                identity: identity,
                displayIdentifier: normalizedDisplay,
                displayName: displayName,
                ordinal: ordinal
            )
        }
    }
}

nonisolated enum ManagedDisplaySpaceRecordParser {
    /// Produces a record only when the display's `Current Space` occurs exactly
    /// once in that same display's ordered `Spaces` collection.
    ///
    /// SkyLight can expose partially-updated dictionaries during Mission
    /// Control and display reconfiguration. A missing or duplicate membership
    /// or a lossy raw-array conversion is therefore unresolved state, not an
    /// invitation to guess.
    static func parse(
        displayIdentifier: String?,
        currentSpace: ManagedDisplaySpaceObservation?,
        listedSpaces: [ManagedDisplaySpaceObservation],
        rawListedSpaceCount: Int? = nil,
        copiedSpaceName: String?,
        isAnimating: Bool
    ) -> ManagedDisplaySpaceRecord? {
        if let rawListedSpaceCount,
           rawListedSpaceCount != listedSpaces.count
        {
            return nil
        }
        guard let displayIdentifier,
              !displayIdentifier.isEmpty,
              let currentSpace,
              currentSpace.spaceID != 0
        else {
            return nil
        }

        let matches = listedSpaces.enumerated().filter {
            $0.element.spaceID == currentSpace.spaceID
        }
        guard matches.count == 1,
              let listedMatch = matches.first
        else {
            return nil
        }

        let listedIndex = listedMatch.offset
        let listedSpace = listedMatch.element

        // Current Space, its matching Spaces entry, and the persistent-name
        // API are independent observations. During a transition they can
        // briefly describe different Spaces. Accept missing evidence, but
        // never choose a winner when present evidence contradicts itself.
        guard ManagedDisplaySpaceEvidencePolicy.identifiersAgree(
            [
                copiedSpaceName,
                currentSpace.spaceUUID,
                listedSpace.spaceUUID,
            ]
        ) else {
            return nil
        }
        guard ManagedDisplaySpaceEvidencePolicy.rawTypesAgree(
            [
                currentSpace.rawType,
                listedSpace.rawType,
            ]
        ) else {
            return nil
        }

        let rawType = currentSpace.rawType ?? listedSpace.rawType
        let ordinal: Int?
        if rawType == 0 {
            ordinal = listedSpaces[...listedIndex].reduce(into: 0) {
                count,
                space in
                if space.rawType == 0
                    || (
                        space.spaceID == currentSpace.spaceID
                        && rawType == 0
                    ) {
                    count += 1
                }
            }
        } else {
            ordinal = nil
        }

        return ManagedDisplaySpaceRecord(
            displayIdentifier: displayIdentifier,
            spaceID: currentSpace.spaceID,
            spaceUUID:
                copiedSpaceName
                ?? currentSpace.spaceUUID
                ?? listedSpace.spaceUUID,
            rawType: rawType,
            isAnimating: isAnimating,
            ordinal: ordinal
        )
    }
}

nonisolated enum DisplaySpaceSnapshotResolver {
    /// Resolves only an exact display record.
    ///
    /// With separate Spaces enabled, the managed-display identifier must equal
    /// the physical display UUID. With shared Spaces disabled, SkyLight uses
    /// the literal `Main` scope. No record-order, main-display, or single-record
    /// fallback is allowed because any of them can bind the wrong desktop
    /// during display reconfiguration.
    static func resolve(
        records: [ManagedDisplaySpaceRecord],
        targetDisplayUUID: String?,
        spacesHaveSeparateSpaces: Bool
    ) -> ActiveSpaceSnapshot? {
        if spacesHaveSeparateSpaces {
            guard let targetDisplayUUID else { return nil }
            let normalizedTarget =
                normalizeDisplayIdentifier(targetDisplayUUID)
            let matches = records.filter {
                normalizeDisplayIdentifier($0.displayIdentifier)
                    == normalizedTarget
            }
            guard !normalizedTarget.isEmpty,
                  matches.count == 1,
                  let exact = matches.first
            else {
                return nil
            }
            return exact.snapshot(identityDisplayScope: normalizedTarget)
        }

        let matches = records.filter {
            normalizeDisplayIdentifier($0.displayIdentifier) == "main"
        }
        guard matches.count == 1,
              let shared = matches.first
        else {
            return nil
        }
        return shared.snapshot(
            identityDisplayScope:
                MissionControlSpaceIdentity.sharedDisplayScope
        )
    }

    static func normalizeDisplayIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .lowercased()
    }

    static func normalizeSpaceIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .lowercased()
    }
}

nonisolated enum SpaceReconciliationOutcome: Equatable, Sendable {
    /// No exact identity may be used while Mission Control is in this state.
    case pending
    /// The latest observation agrees with the already-settled state.
    case unchanged
    /// A quiet run of identical non-animating observations settled.
    case committed(ActiveSpaceSnapshot)
}

/// Converts noisy Mission Control observations into one settled state.
///
/// Every lifecycle signal invalidates the previous identity immediately.
/// A state commits only after at least three equal, non-animating observations
/// spanning at least half a second of caller-supplied monotonic uptime. This
/// deliberately does not rely on SkyLight's animation bit, which is unreliable
/// on modern macOS.
nonisolated struct SpaceTransitionReconciler: Sendable {
    static let minimumQuietInterval: TimeInterval = 0.5
    static let minimumSampleCount = 3

    let quietInterval: TimeInterval
    let requiredSampleCount: Int

    private(set) var settledSnapshot: ActiveSpaceSnapshot?
    private var candidateSnapshot: ActiveSpaceSnapshot?
    private var candidateSinceUptime: TimeInterval?
    private var candidateSampleCount = 0
    private var lastObservationUptime: TimeInterval?

    init(
        quietInterval: TimeInterval = minimumQuietInterval,
        requiredSampleCount: Int = minimumSampleCount
    ) {
        self.quietInterval = max(
            Self.minimumQuietInterval,
            quietInterval.isFinite
                ? quietInterval
                : Self.minimumQuietInterval
        )
        self.requiredSampleCount = max(
            Self.minimumSampleCount,
            requiredSampleCount
        )
    }

    /// Source-compatible bridge for callers being moved from the previous
    /// interval name. The hard safety floor and sample count still apply.
    init(stabilityInterval: TimeInterval) {
        self.init(quietInterval: stabilityInterval)
    }

    mutating func invalidate() {
        settledSnapshot = nil
        candidateSnapshot = nil
        candidateSinceUptime = nil
        candidateSampleCount = 0
        lastObservationUptime = nil
    }

    mutating func observe(
        _ snapshot: ActiveSpaceSnapshot?,
        atUptime uptime: TimeInterval
    ) -> SpaceReconciliationOutcome {
        guard uptime.isFinite,
              uptime >= 0,
              lastObservationUptime.map({ uptime >= $0 }) ?? true,
              let snapshot,
              snapshot.spaceID != 0,
              !snapshot.isAnimating
        else {
            invalidate()
            return .pending
        }
        lastObservationUptime = uptime

        if let settledSnapshot,
           reconciliationKey(for: settledSnapshot)
                == reconciliationKey(for: snapshot) {
            self.settledSnapshot = snapshot
            candidateSnapshot = nil
            candidateSinceUptime = nil
            candidateSampleCount = 0
            return .unchanged
        }

        // Any disagreement with the committed state fails closed immediately.
        settledSnapshot = nil

        guard let candidateSnapshot,
              let candidateSinceUptime,
              reconciliationKey(for: candidateSnapshot)
                == reconciliationKey(for: snapshot)
        else {
            self.candidateSnapshot = snapshot
            candidateSinceUptime = uptime
            candidateSampleCount = 1
            return .pending
        }

        self.candidateSnapshot = snapshot
        candidateSampleCount += 1
        guard candidateSampleCount >= requiredSampleCount,
              uptime - candidateSinceUptime >= quietInterval
        else {
            return .pending
        }

        settledSnapshot = snapshot
        self.candidateSnapshot = nil
        self.candidateSinceUptime = nil
        candidateSampleCount = 0
        return .committed(snapshot)
    }

    /// Compatibility bridge for the current app call site. Reconciliation
    /// state itself never stores or compares wall-clock time.
    @available(
        *,
        deprecated,
        message: "Pass caller-supplied monotonic uptime with atUptime:."
    )
    mutating func observe(
        _ snapshot: ActiveSpaceSnapshot?,
        at _: Date
    ) -> SpaceReconciliationOutcome {
        observe(
            snapshot,
            atUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func reconciliationKey(
        for snapshot: ActiveSpaceSnapshot
    ) -> ReconciliationKey {
        ReconciliationKey(
            spaceID: snapshot.spaceID,
            identity: snapshot.identity,
            rawType: snapshot.rawType,
            displayIdentifier: snapshot.displayIdentifier
        )
    }

    private struct ReconciliationKey: Equatable, Sendable {
        let spaceID: UInt64
        let identity: MissionControlSpaceIdentity?
        let rawType: Int32?
        let displayIdentifier: String?
    }
}
