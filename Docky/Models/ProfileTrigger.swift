//
//  ProfileTrigger.swift
//  Docky
//
//  Per-profile rules that switch the active dock profile automatically
//  based on system signals. Phase 1: time-of-day, frontmost app, and
//  Mission Control space. Phase 2 will add Wi-Fi SSID and Bluetooth
//  proximity, both of which require lazy permission prompts.
//
//  Exact Space ownership is intentionally not a generic trigger. It lives in
//  the profile-store assignment table, where one Space can have one owner.
//  The cases below retain `exactSpace` only to decode and explicitly repair
//  documents written by older Docky builds.
//

import Foundation

nonisolated enum ProfileMutationCredentialValidation:
    Equatable,
    Sendable {
    case current
    case profileChanged
    case revisionChanged
}

/// Identity and document revision captured before an asynchronous profile
/// mutation begins. Completion must validate both fields atomically; looking
/// up the active profile again after an `await` can redirect stale work into a
/// different Space's profile.
nonisolated struct ProfileMutationCredentials:
    Equatable,
    Sendable {
    let profileID: String
    let revision: UInt64

    func validation(
        activeProfileID: String,
        currentRevision: UInt64
    ) -> ProfileMutationCredentialValidation {
        guard activeProfileID == profileID else {
            return .profileChanged
        }
        guard currentRevision == revision else {
            return .revisionChanged
        }
        return .current
    }
}

nonisolated enum ProfileTrigger:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    case timeOfDay(TimeOfDayTrigger)
    case frontmostApp(FrontmostAppTrigger)
    case space(SpaceTrigger)
    case exactSpace(ExactSpaceTrigger)

    var id: String {
        switch self {
        case .timeOfDay(let trigger): return trigger.id
        case .frontmostApp(let trigger): return trigger.id
        case .space(let trigger): return trigger.id
        case .exactSpace(let trigger): return trigger.id
        }
    }

    /// Higher specificity beats lower when multiple generic triggers match.
    /// Exact Space assignments are resolved separately at priority 4.
    var specificity: Int {
        switch self {
        case .exactSpace: return 4
        case .space: return 3
        case .frontmostApp: return 2
        case .timeOfDay: return 1
        }
    }
}

/// Stable identity used by trigger editors to project their value from the
/// authoritative profile document.
///
/// Editors deliberately do not retain a draft trigger after submitting an
/// edit. A rejected mutation therefore keeps showing the canonical value, and
/// a later persistence rollback is reflected as soon as `ProfileService`
/// publishes the restored profile document.
nonisolated struct ProfileTriggerEditorIdentity:
    Equatable,
    Sendable {
    let profileID: String
    let triggerID: String

    func resolve(
        canonicalProfileID: String,
        triggers: [ProfileTrigger]
    ) -> ProfileTrigger? {
        guard canonicalProfileID == profileID else {
            return nil
        }
        let matches = triggers.filter { $0.id == triggerID }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }
}

/// A metadata lookup result is valid only for the exact canonical bundle
/// identifier that started it. Task cancellation alone is not sufficient:
/// an already-returning async lookup may still publish after a rejected edit
/// rolls the profile document back.
nonisolated struct ProfileApplicationNameResolution:
    Equatable,
    Sendable {
    let bundleIdentifier: String
    let displayName: String?

    func displayName(
        forCanonicalBundleIdentifier canonicalBundleIdentifier: String
    ) -> String? {
        guard bundleIdentifier == canonicalBundleIdentifier else {
            return nil
        }
        return displayName
    }
}

/// Fires while the local time falls inside `[startMinuteOfDay,
/// endMinuteOfDay)` on any of the listed weekdays. Minute-of-day is 0
/// (00:00) up to 1439 (23:59). Wraparound (e.g. 22:00 → 06:00) is
/// supported by `endMinuteOfDay < startMinuteOfDay`.
nonisolated struct TimeOfDayTrigger:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    let id: String
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int
    /// Weekdays where this trigger is active. `1 == Sunday`,
    /// `7 == Saturday` (matches `Calendar.component(.weekday, from:)`).
    var weekdays: Set<Int>

    init(
        id: String = UUID().uuidString,
        startMinuteOfDay: Int = 9 * 60,
        endMinuteOfDay: Int = 18 * 60,
        weekdays: Set<Int> = [2, 3, 4, 5, 6]
    ) {
        self.id = id
        self.startMinuteOfDay = max(0, min(startMinuteOfDay, 1439))
        self.endMinuteOfDay = max(0, min(endMinuteOfDay, 1439))
        self.weekdays = weekdays
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startMinuteOfDay
        case endMinuteOfDay
        case weekdays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        id = try container.decode(String.self, forKey: .id)
        startMinuteOfDay = try container.decode(
            Int.self,
            forKey: .startMinuteOfDay
        )
        endMinuteOfDay = try container.decode(
            Int.self,
            forKey: .endMinuteOfDay
        )
        weekdays = Set(
            try container.decode(
                [Int].self,
                forKey: .weekdays
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self
        )
        try container.encode(id, forKey: .id)
        try container.encode(
            startMinuteOfDay,
            forKey: .startMinuteOfDay
        )
        try container.encode(
            endMinuteOfDay,
            forKey: .endMinuteOfDay
        )
        // Set iteration order is process-random. Recovery snapshots are
        // byte-compared before UserDefaults writes, so encode a canonical
        // array to make an unchanged settings document a true no-op.
        try container.encode(
            weekdays.sorted(),
            forKey: .weekdays
        )
    }

    func matches(date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard weekdays.contains(weekday) else { return false }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinuteOfDay == endMinuteOfDay {
            return false
        }
        if startMinuteOfDay < endMinuteOfDay {
            return minuteOfDay >= startMinuteOfDay && minuteOfDay < endMinuteOfDay
        }
        // Wraparound (e.g. 22:00 → 06:00 the next morning).
        return minuteOfDay >= startMinuteOfDay || minuteOfDay < endMinuteOfDay
    }
}

/// Fires while the user's frontmost application matches the bound
/// bundle identifier.
nonisolated struct FrontmostAppTrigger:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    let id: String
    var bundleIdentifier: String

    init(id: String = UUID().uuidString, bundleIdentifier: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Fires while the user is on a Mission Control space that contains a
/// visible window of the bound app. Identifying spaces by their app
/// (rather than positional index) survives macOS's automatic space
/// rearrangement based on most-recently-used apps. The common case is
/// a fullscreen app on its own dedicated space.
nonisolated struct SpaceTrigger:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    let id: String
    var bundleIdentifier: String

    init(id: String = UUID().uuidString, bundleIdentifier: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Legacy exact-Space trigger payload.
///
/// Schema 2 stores valid exact assignments in `SpaceProfileAssignment`.
/// This type remains decodable so schema-1 UUID bindings can be migrated and
/// numeric-only bindings can be shown as repair-required without guessing.
nonisolated struct ExactSpaceTrigger:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    let id: String
    /// Numeric Space IDs are session-local and are never migrated or matched.
    var spaceID: UInt64?
    /// Empty is the root Desktop's valid SkyLight identity.
    var spaceUUID: String?
    /// Previous schema's physical-display component. It is used only to scope
    /// the root Desktop; named Space identity no longer includes a display.
    var displayUUID: String?

    init(
        id: String = UUID().uuidString,
        identity: MissionControlSpaceIdentity
    ) {
        self.id = id
        spaceID = nil
        spaceUUID = identity.spaceUUID
        displayUUID = identity.displayUUID
    }

    /// Compatibility initializer for old in-memory callers.
    init(id: String = UUID().uuidString, spaceID: UInt64) {
        self.id = id
        self.spaceID = spaceID
        spaceUUID = nil
        displayUUID = nil
    }

    var identity: MissionControlSpaceIdentity? {
        MissionControlSpaceIdentity(
            displayUUID: displayUUID,
            spaceUUID: spaceUUID
        )
    }

    func matches(_ currentIdentity: MissionControlSpaceIdentity?) -> Bool {
        guard let identity, let currentIdentity else { return false }
        return identity == currentIdentity
    }

    mutating func bind(to identity: MissionControlSpaceIdentity) {
        spaceID = nil
        spaceUUID = identity.spaceUUID
        displayUUID = identity.displayUUID
    }

}

/// The authoritative one-to-one Space ownership record.
///
/// Profile contents never live here and assignment operations never mutate
/// profile contents. A profile may own several Spaces; a Space may own only
/// one profile.
nonisolated struct SpaceProfileAssignment:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    let identity: MissionControlSpaceIdentity
    var profileID: String

    var id: String { identity.storageKey }
}

nonisolated enum SpaceProfileAssignmentPolicy {
    static func profileID(
        for identity: MissionControlSpaceIdentity?,
        in assignments: [SpaceProfileAssignment]
    ) -> String? {
        guard let identity else { return nil }
        let matches = assignments.filter { $0.identity == identity }
        // Corrupt/conflicting input fails closed. Schema validation normally
        // prevents this state from entering the service.
        guard matches.count == 1 else { return nil }
        return matches[0].profileID
    }

    /// Atomically reassigns exactly one Space while preserving all other
    /// Space assignments and every profile's content.
    static func assigning(
        _ identity: MissionControlSpaceIdentity,
        to profileID: String,
        in assignments: [SpaceProfileAssignment]
    ) -> [SpaceProfileAssignment] {
        let existingOwners = assignments.filter {
            $0.identity == identity
        }
        if existingOwners.count == 1,
           existingOwners[0].profileID == profileID {
            return assignments
        }

        var updated = assignments.filter { $0.identity != identity }
        updated.append(
            SpaceProfileAssignment(
                identity: identity,
                profileID: profileID
            )
        )
        return updated
    }
}

/// Minimal schema-1 input needed to plan exact-Space migration without
/// constructing ProfileService or mutating profile content.
nonisolated struct LegacyExactSpaceMigrationProfileInput:
    Equatable,
    Sendable {
    let profileID: String
    let triggers: [ProfileTrigger]
}

/// Exact identities that may be removed from one schema-1 profile after the
/// corresponding assignments have been committed to the schema-2 table.
nonisolated struct LegacyExactSpaceMigrationProfileResult:
    Equatable,
    Sendable {
    let profileID: String
    let migratedIdentities: [MissionControlSpaceIdentity]
}

/// Deterministic, non-mutating result of schema-1 exact-Space analysis.
nonisolated struct LegacyExactSpaceAssignmentMigrationPlan:
    Equatable,
    Sendable {
    let assignments: [SpaceProfileAssignment]
    let profileResults: [LegacyExactSpaceMigrationProfileResult]

    func migratedIdentities(
        for profileID: String
    ) -> [MissionControlSpaceIdentity] {
        profileResults.first {
            $0.profileID == profileID
        }?.migratedIdentities ?? []
    }
}

/// Extracts only globally-unambiguous persistent identities. Numeric-only
/// triggers and cross-profile conflicts are intentionally absent from the
/// result, which leaves their legacy rows available for explicit repair.
nonisolated enum LegacyExactSpaceAssignmentMigrationPolicy {
    static func makePlan(
        profiles: [LegacyExactSpaceMigrationProfileInput],
        rootDisplayScopeOverride: String? = nil
    ) -> LegacyExactSpaceAssignmentMigrationPlan {
        var ownersByIdentity:
            [MissionControlSpaceIdentity: Set<String>] = [:]

        for profile in profiles {
            for trigger in profile.triggers {
                guard case .exactSpace(let exact) = trigger,
                      let identity = migrationIdentity(
                          for: exact,
                          rootDisplayScopeOverride:
                              rootDisplayScopeOverride
                      )
                else {
                    continue
                }
                ownersByIdentity[identity, default: []]
                    .insert(profile.profileID)
            }
        }

        let assignments = ownersByIdentity.compactMap {
            identity,
            owners -> SpaceProfileAssignment? in
            guard owners.count == 1,
                  let profileID = owners.first
            else {
                return nil
            }
            return SpaceProfileAssignment(
                identity: identity,
                profileID: profileID
            )
        }
        .sorted {
            if $0.identity.storageKey == $1.identity.storageKey {
                return $0.profileID < $1.profileID
            }
            return $0.identity.storageKey < $1.identity.storageKey
        }

        var identitiesByProfile:
            [String: [MissionControlSpaceIdentity]] = [:]
        for assignment in assignments {
            identitiesByProfile[
                assignment.profileID,
                default: []
            ].append(assignment.identity)
        }
        let profileResults = identitiesByProfile.map {
            profileID,
            identities in
            LegacyExactSpaceMigrationProfileResult(
                profileID: profileID,
                migratedIdentities: identities.sorted {
                    $0.storageKey < $1.storageKey
                }
            )
        }
        .sorted { $0.profileID < $1.profileID }

        return LegacyExactSpaceAssignmentMigrationPlan(
            assignments: assignments,
            profileResults: profileResults
        )
    }

    static func migrationIdentity(
        for trigger: ExactSpaceTrigger,
        rootDisplayScopeOverride: String?
    ) -> MissionControlSpaceIdentity? {
        guard let spaceUUID = trigger.spaceUUID else {
            // A numeric SkyLight ID has no durable cross-session meaning.
            return nil
        }
        let normalizedSpaceUUID =
            DisplaySpaceSnapshotResolver.normalizeSpaceIdentifier(
                spaceUUID
            )
        if normalizedSpaceUUID.isEmpty,
           let rootDisplayScopeOverride {
            return MissionControlSpaceIdentity(
                displayUUID: rootDisplayScopeOverride,
                spaceUUID: normalizedSpaceUUID
            )
        }
        return trigger.identity
    }
}

/// Host-testable input to profile-trigger resolution. Keeping the policy out
/// of the AppKit observer makes new/unassigned Space behavior deterministic
/// and regression-testable.
nonisolated struct ProfileTriggerEvaluationProfile: Equatable, Sendable {
    let id: String
    let dateCreated: Date
    let triggers: [ProfileTrigger]
}

/// The settled Space state relevant to exact profile ownership.
///
/// A regular Desktop with no assignment is different from a fullscreen or
/// otherwise nonassignable Space: the former must retain its current layout,
/// while the latter may still use generic app/time rules.
nonisolated enum ProfileSpaceAssignmentEvaluationState:
    Equatable,
    Sendable {
    case assigned(profileID: String)
    case unassignedRegular
    case nonassignable
    case unresolved
}

nonisolated struct ProfileTriggerEvaluationContext: Sendable {
    let now: Date
    let frontmostBundleID: String?
    let spaceApps: Set<String>
    let spaceAssignmentState: ProfileSpaceAssignmentEvaluationState
    /// Arrival on a newly-created or newly-visited unassigned Desktop keeps
    /// the visible layout. A later, independently revalidated app/time event
    /// may still run the user's generic rules without creating an assignment.
    let allowsGenericRulesOnUnassignedRegular: Bool

    init(
        now: Date,
        frontmostBundleID: String?,
        spaceApps: Set<String>,
        spaceAssignmentState: ProfileSpaceAssignmentEvaluationState,
        allowsGenericRulesOnUnassignedRegular: Bool = false
    ) {
        self.now = now
        self.frontmostBundleID = frontmostBundleID
        self.spaceApps = spaceApps
        self.spaceAssignmentState = spaceAssignmentState
        self.allowsGenericRulesOnUnassignedRegular =
            allowsGenericRulesOnUnassignedRegular
    }
}

nonisolated struct ProfileTriggerResolution: Equatable, Sendable {
    let profileID: String
    let specificity: Int
    let usedUnassignedSpaceFallback: Bool
}

/// Why the engine is reconciling Space state.
///
/// The reason is typed because assignment verification and manual binding are
/// observations only: neither is allowed to run profile automation as a side
/// effect. Diagnostic strings must never decide runtime behavior.
nonisolated enum ProfileTriggerSamplingPurpose:
    Equatable,
    Sendable {
    case startup
    case topology
    case frontmostApplication
    case minute
    case assignmentVerification
    case manualBinding

    var shouldEvaluateAutomation: Bool {
        switch self {
        case .startup, .topology, .frontmostApplication, .minute:
            return true
        case .assignmentVerification, .manualBinding:
            return false
        }
    }
}

/// Coalesces every invalidation that belongs to one unsettled reconciliation
/// epoch.
///
/// Callback order is not intent order. In particular, a delayed topology
/// callback must not erase a genuine app or minute event that arrived while
/// the same Desktop was settling. Observation-only workflows are stronger
/// still: an incidental automation callback cannot turn the observation into
/// an activation.
///
/// Assignment verification is not stored through this policy. It is a
/// token-owned overlay in `ProfileTriggerEngine`, so aborting verification
/// cannot leave an observation-only purpose behind.
nonisolated enum ProfileTriggerSamplingPurposePolicy {
    static func coalescing(
        current: ProfileTriggerSamplingPurpose?,
        incoming: ProfileTriggerSamplingPurpose
    ) -> ProfileTriggerSamplingPurpose {
        guard let current else { return incoming }

        if !incoming.shouldEvaluateAutomation {
            return incoming
        }
        if !current.shouldEvaluateAutomation {
            return current
        }

        if current == .minute || incoming == .minute {
            return .minute
        }
        if current == .frontmostApplication
            || incoming == .frontmostApplication {
            return .frontmostApplication
        }
        return incoming
    }
}

/// A Space assignment read from the profile document that has actually
/// reached durable storage, paired with the narrow current-state checks needed
/// to apply that owner safely.
///
/// Whole-document revision equality is deliberately diagnostic only. An
/// unrelated pending edit must not make every assigned Space slow. Instead the
/// fast lane proves that this identity still has the same owner and that this
/// owner's layout still matches its durable profile.
nonisolated struct ProfileDurableSpaceAssignmentState:
    Equatable,
    Sendable {
    let profileID: String?
    let currentOwnerMatchesDurable: Bool
    let targetProfileMatchesDurable: Bool
    let persistenceIsAuthoritative: Bool
    let currentRevision: UInt64
    let durableRevision: UInt64
}

/// Shared admission gate for every immediate Space activation, including the
/// manual round-trip restoration branch. Observation-only sampling and fresh
/// assignment verification must not mutate the active profile.
nonisolated enum ProfileFastSpaceActivationAttemptPolicy {
    static func allowsAttempt(
        purpose: ProfileTriggerSamplingPurpose,
        verificationInProgress: Bool
    ) -> Bool {
        purpose.shouldEvaluateAutomation
            && !verificationInProgress
    }
}

/// Narrow authorization for the low-latency exact-Space activation lane.
///
/// This lane deliberately does not publish a settled Space or authorize
/// generic app/time rules. It can only reapply an already-persisted owner for
/// a complete regular-Space observation. The ordinary reconciler continues in
/// the background and remains authoritative for discovery and assignment.
nonisolated enum ProfileAssignedSpaceFastActivationPolicy {
    static func profileID(
        snapshot: ActiveSpaceSnapshot,
        purpose: ProfileTriggerSamplingPurpose,
        targetChanged: Bool,
        durableAssignment:
            ProfileDurableSpaceAssignmentState,
        availableProfileIDs: Set<String>,
        verificationInProgress: Bool,
        manualOverrideAllowsTransition: Bool
    ) -> String? {
        guard purpose.shouldEvaluateAutomation,
              targetChanged,
              !verificationInProgress,
              manualOverrideAllowsTransition,
              snapshot.spaceID != 0,
              !snapshot.isAnimating,
              snapshot.rawType == 0,
              snapshot.assignableIdentity != nil,
              durableAssignment.persistenceIsAuthoritative,
              durableAssignment.currentOwnerMatchesDurable,
              durableAssignment.targetProfileMatchesDurable,
              let profileID = durableAssignment.profileID,
              availableProfileIDs.contains(profileID)
        else {
            return nil
        }
        return profileID
    }
}

/// Unconsumed intent for one reconciliation epoch.
///
/// Manual binding and automation occupy separate lanes. A manual-binding
/// commit consumes only the observation lane; topology/app/minute intent that
/// arrived underneath it remains available for a follow-up reconciliation.
/// Assignment verification is deliberately absent from both lanes because it
/// is owned by an asynchronous verification token.
///
/// `crossedTarget` deliberately survives a failed evidence bracket. Otherwise
/// a retry on the newly-entered Desktop would look like a later same-Desktop
/// event and a retained minute intent could incorrectly authorize a generic
/// rule.
nonisolated struct ProfileTriggerSamplingEpochState:
    Equatable,
    Sendable {
    private(set) var observationPurpose:
        ProfileTriggerSamplingPurpose?
    private(set) var automationPurpose:
        ProfileTriggerSamplingPurpose?
    private(set) var crossedTarget = false

    var purpose: ProfileTriggerSamplingPurpose? {
        observationPurpose ?? automationPurpose
    }

    mutating func record(
        _ incoming: ProfileTriggerSamplingPurpose
    ) {
        switch incoming {
        case .assignmentVerification:
            // Assignment verification is a token-owned engine overlay. Never
            // persist it as epoch state, where timeout or cancellation could
            // poison the next real topology reconciliation.
            assertionFailure(
                "Assignment verification must be token-owned"
            )
        case .manualBinding:
            observationPurpose = .manualBinding
        case .startup, .topology, .frontmostApplication, .minute:
            automationPurpose =
                ProfileTriggerSamplingPurposePolicy.coalescing(
                    current: automationPurpose,
                    incoming: incoming
                )
        }
    }

    mutating func noteCommittedTargetChange(
        _ targetChanged: Bool
    ) {
        crossedTarget = crossedTarget || targetChanged
    }

    func effectivePurpose(
        fallback: ProfileTriggerSamplingPurpose
    ) -> ProfileTriggerSamplingPurpose {
        if fallback == .assignmentVerification {
            return .assignmentVerification
        }
        if let observationPurpose {
            return observationPurpose
        }
        return ProfileTriggerSamplingPurposePolicy.coalescing(
            current: automationPurpose,
            incoming: fallback
        )
    }

    func effectiveTargetChanged(
        currentCommitTargetChanged: Bool
    ) -> Bool {
        crossedTarget || currentCommitTargetChanged
    }

    mutating func consumeAutomation() {
        automationPurpose = nil
        crossedTarget = false
    }

    /// Consumes a committed observation-only lane and returns any automation
    /// intent that must be reconciled afterward.
    mutating func consumeObservation(
        _ committedPurpose: ProfileTriggerSamplingPurpose
    ) -> ProfileTriggerSamplingPurpose? {
        guard committedPurpose == .manualBinding else {
            return automationPurpose
        }
        observationPurpose = nil
        if automationPurpose == nil {
            crossedTarget = false
        }
        return automationPurpose
    }

    mutating func reset() {
        observationPurpose = nil
        consumeAutomation()
    }
}

/// Coalesces harmless automation signals while a fresh assignment
/// verification owns the Space sampler. Topology and manual signals are not
/// accepted here because they must still invalidate the verification.
nonisolated struct ProfileTriggerAutomationSignalDeferral:
    Equatable,
    Sendable {
    private(set) var deferredPurpose:
        ProfileTriggerSamplingPurpose?

    mutating func receive(
        _ purpose: ProfileTriggerSamplingPurpose,
        verificationInProgress: Bool
    ) -> ProfileTriggerSamplingPurpose? {
        guard purpose == .frontmostApplication
                || purpose == .minute
        else {
            return purpose
        }
        guard verificationInProgress else {
            return purpose
        }
        deferredPurpose =
            ProfileTriggerSamplingPurposePolicy.coalescing(
                current: deferredPurpose,
                incoming: purpose
            )
        return nil
    }

    mutating func verificationDidFinish()
        -> ProfileTriggerSamplingPurpose? {
        defer { deferredPurpose = nil }
        return deferredPurpose
    }

    mutating func reset() {
        deferredPurpose = nil
    }
}

/// Tokenized lease for an asynchronous fresh-Space verification.
///
/// A stopped engine may start again before an old task's `defer` runs. The
/// epoch/serial token prevents that late completion from releasing a newer
/// verification lease.
nonisolated struct ProfileFreshReconciliationGate:
    Equatable,
    Sendable {
    nonisolated struct Token: Equatable, Sendable {
        let runEpoch: UInt64
        let serial: UInt64
    }

    private(set) var activeToken: Token?
    private var nextSerial: UInt64 = 0

    var isInProgress: Bool {
        activeToken != nil
    }

    mutating func begin(runEpoch: UInt64) -> Token? {
        guard activeToken == nil else { return nil }
        nextSerial &+= 1
        let token = Token(
            runEpoch: runEpoch,
            serial: nextSerial
        )
        activeToken = token
        return token
    }

    mutating func finish(_ token: Token) {
        guard activeToken == token else { return }
        activeToken = nil
    }

    func isActive(_ token: Token) -> Bool {
        activeToken == token
    }

    mutating func invalidate() {
        activeToken = nil
    }
}

/// App evidence captured between a settled Space observation and a matching
/// post-query observation.
nonisolated struct ProfileTriggerSpaceEvidence:
    Equatable,
    Sendable {
    let frontmostBundleID: String?
    let spaceApps: Set<String>
}

/// A seqlock-style evidence check around AppKit/CoreGraphics queries.
///
/// There is no public API that atomically returns the active Space, frontmost
/// app, and its windows. Docky therefore publishes the evidence only when the
/// frontmost app is stable across the query and a post-query Space observation
/// exactly matches the committed observation.
nonisolated enum ProfileTriggerSpaceEvidencePolicy {
    static func validated(
        committedSnapshot: ActiveSpaceSnapshot,
        postQuerySnapshot: ActiveSpaceSnapshot,
        frontmostBefore: String?,
        frontmostAfter: String?,
        spaceApps: Set<String>
    ) -> ProfileTriggerSpaceEvidence? {
        guard isCompleteObservation(committedSnapshot),
              isCompleteObservation(postQuerySnapshot),
              sameObservation(
                  committedSnapshot,
                  postQuerySnapshot
              ),
              frontmostBefore == frontmostAfter
        else {
            return nil
        }
        return ProfileTriggerSpaceEvidence(
            frontmostBundleID: frontmostAfter,
            spaceApps: spaceApps
        )
    }

    /// Generic rules on an unassigned Desktop become eligible only after an
    /// independently-observed change on that same residency. A delayed,
    /// duplicate activation callback is not a new signal.
    static func genericRulesAllowed(
        currentlyAllowed: Bool,
        purpose: ProfileTriggerSamplingPurpose,
        targetChanged: Bool,
        previousEvidence: ProfileTriggerSpaceEvidence?,
        newEvidence: ProfileTriggerSpaceEvidence
    ) -> Bool {
        guard !targetChanged else { return false }
        switch purpose {
        case .frontmostApplication:
            guard let previousEvidence else {
                return currentlyAllowed
            }
            return currentlyAllowed
                || previousEvidence.frontmostBundleID
                    != newEvidence.frontmostBundleID
        case .minute:
            return true
        case .startup, .topology, .assignmentVerification, .manualBinding:
            return currentlyAllowed
        }
    }

    private static func isCompleteObservation(
        _ snapshot: ActiveSpaceSnapshot
    ) -> Bool {
        snapshot.spaceID != 0
            && !snapshot.isAnimating
            && (snapshot.rawType == 0 || snapshot.rawType == 4)
    }

    private static func sameObservation(
        _ lhs: ActiveSpaceSnapshot,
        _ rhs: ActiveSpaceSnapshot
    ) -> Bool {
        lhs.spaceID == rhs.spaceID
            && lhs.identity == rhs.identity
            && lhs.rawType == rhs.rawType
            && DisplaySpaceSnapshotResolver
                .normalizeDisplayIdentifier(
                    lhs.displayIdentifier ?? ""
                )
                == DisplaySpaceSnapshotResolver
                .normalizeDisplayIdentifier(
                    rhs.displayIdentifier ?? ""
                )
            && lhs.displayOrdinal == rhs.displayOrdinal
    }
}

/// Assignment ownership captured when a Desktop residency is entered.
///
/// The live assignment table may be edited while the user remains on the
/// Desktop. Those edits are deliberately deferred until a different target is
/// entered and this target is entered again (or the engine restarts).
nonisolated struct ProfileSpaceResidencyState:
    Equatable,
    Sendable {
    private(set) var regularIdentity:
        MissionControlSpaceIdentity?
    private(set) var latchedProfileID: String?

    mutating func reset() {
        regularIdentity = nil
        latchedProfileID = nil
    }

    mutating func reconcileCommittedTarget(
        _ snapshot: ActiveSpaceSnapshot,
        targetChanged: Bool,
        liveAssignedProfileID: String?
    ) {
        if targetChanged {
            reset()
        }
        guard snapshot.rawType == 0,
              let identity = snapshot.identity
        else {
            return
        }

        // `regularIdentity == identity` means the assignment was already
        // latched for this residency. Never refresh it merely because the
        // underlying ownership table changed.
        guard regularIdentity != identity else {
            return
        }
        regularIdentity = identity
        latchedProfileID = liveAssignedProfileID
    }

    func evaluationState(
        for snapshot: ActiveSpaceSnapshot
    ) -> ProfileSpaceAssignmentEvaluationState {
        switch snapshot.rawType {
        case 0:
            guard let identity = snapshot.identity,
                  regularIdentity == identity
            else {
                // A regular Desktop without durable identity is unresolved,
                // not a safely-unassigned Desktop.
                return .unresolved
            }
            if let latchedProfileID {
                return .assigned(
                    profileID: latchedProfileID
                )
            }
            return .unassignedRegular
        case 4:
            return .nonassignable
        default:
            return .unresolved
        }
    }
}

/// A stable-enough target observed at the instant of a manual profile choice.
/// Numeric IDs are used only inside this process as a fallback when SkyLight
/// has not supplied a durable identity; they are never persisted.
nonisolated struct ProfileManualOverrideTarget:
    Equatable,
    Sendable {
    let identity: MissionControlSpaceIdentity?
    let spaceID: UInt64
    let rawType: Int32
    let displayIdentifier: String

    init?(_ snapshot: ActiveSpaceSnapshot?) {
        guard let snapshot,
              snapshot.spaceID != 0,
              !snapshot.isAnimating,
              let rawType = snapshot.rawType,
              rawType == 0 || rawType == 4
        else {
            return nil
        }
        identity = snapshot.identity
        spaceID = snapshot.spaceID
        self.rawType = rawType
        displayIdentifier =
            DisplaySpaceSnapshotResolver.normalizeDisplayIdentifier(
                snapshot.displayIdentifier ?? ""
            )
    }

    static func == (
        lhs: ProfileManualOverrideTarget,
        rhs: ProfileManualOverrideTarget
    ) -> Bool {
        lhs.identity == rhs.identity
            && lhs.spaceID == rhs.spaceID
            && lhs.rawType == rhs.rawType
            && lhs.displayIdentifier == rhs.displayIdentifier
    }

    func isSameLogicalTarget(
        as other: ProfileManualOverrideTarget
    ) -> Bool {
        guard rawType == other.rawType,
              displayIdentifier == other.displayIdentifier
        else {
            return false
        }
        if let identity,
           let otherIdentity = other.identity {
            return identity == otherIdentity
        }
        return spaceID == other.spaceID
    }
}

/// Tracks notification-time arrivals independently from slower settled-state
/// publication. Without this state, a rapid A → B → A round trip completed
/// inside the settlement window would compare the final A with stale settled
/// A and incorrectly delay its exact owner.
nonisolated struct ProfileFastSpaceArrivalState:
    Equatable,
    Sendable {
    private(set) var lastObservedTarget:
        ProfileManualOverrideTarget?
    private var activationWasConsumed = false

    mutating func reset() {
        lastObservedTarget = nil
        activationWasConsumed = false
    }

    /// A lifecycle callback is useful even when its first SkyLight read is
    /// incomplete. Keep the arrival open so an early retry can consume it
    /// once the persistent Space name becomes available.
    mutating func beginArrival() {
        activationWasConsumed = false
    }

    /// Returns true while the current arrival remains eligible for an
    /// activation attempt. Merely observing an identity-less snapshot does
    /// not consume the arrival; only `markActivationSucceeded` does that.
    /// Invalid/animating observations do not erase the last target.
    mutating func observe(
        _ snapshot: ActiveSpaceSnapshot
    ) -> Bool {
        guard let observedTarget =
                ProfileManualOverrideTarget(snapshot)
        else {
            return false
        }
        if let lastObservedTarget {
            if !lastObservedTarget.isSameLogicalTarget(
                as: observedTarget
            ) {
                self.lastObservedTarget = observedTarget
                activationWasConsumed = false
            }
        } else {
            lastObservedTarget = observedTarget
            activationWasConsumed = false
        }
        return !activationWasConsumed
    }

    mutating func markActivationSucceeded(
        for snapshot: ActiveSpaceSnapshot
    ) {
        guard let observedTarget =
                ProfileManualOverrideTarget(snapshot),
              let lastObservedTarget,
              lastObservedTarget.isSameLogicalTarget(
                as: observedTarget
              )
        else {
            return
        }
        activationWasConsumed = true
    }

    mutating func synchronize(
        _ snapshot: ActiveSpaceSnapshot
    ) {
        guard let target =
                ProfileManualOverrideTarget(snapshot)
        else {
            return
        }
        lastObservedTarget = target
        activationWasConsumed = true
    }
}

/// Explicit manual-override state shared by runtime policy and host tests.
/// The choice is tied to the Space observed when the action occurred, rather
/// than callback order. If that instant is unresolved, the next committed
/// target conservatively adopts the manual choice.
nonisolated struct ProfileManualOverrideState:
    Equatable,
    Sendable {
    private(set) var profileID: String?
    private(set) var recordedTarget: ProfileManualOverrideTarget?
    private(set) var awaitsTargetBinding = false

    mutating func record(
        profileID: String,
        observedTarget: ActiveSpaceSnapshot?
    ) {
        self.profileID = profileID
        recordedTarget = ProfileManualOverrideTarget(observedTarget)
        awaitsTargetBinding = recordedTarget == nil
    }

    mutating func recordUnbound(profileID: String) {
        self.profileID = profileID
        recordedTarget = nil
        awaitsTargetBinding = true
    }

    mutating func clear() {
        profileID = nil
        recordedTarget = nil
        awaitsTargetBinding = false
    }

    /// A bound override may be cleared immediately by a coherent observation
    /// of a different logical target. An unbound post-click choice must wait
    /// for the ordinary reconciler to decide which residency owns it.
    func allowsFastTransition(
        to snapshot: ActiveSpaceSnapshot
    ) -> Bool {
        guard profileID != nil else {
            return true
        }
        guard !awaitsTargetBinding,
              let recordedTarget,
              let observedTarget =
                ProfileManualOverrideTarget(snapshot)
        else {
            return false
        }
        return !recordedTarget.isSameLogicalTarget(
            as: observedTarget
        )
    }

    /// If a fast, uncommitted departure returns to the residency that owns a
    /// manual choice, restore that choice instead of applying the Space's
    /// automatic owner. Once a different target commits, normal reconciliation
    /// clears the override and this path becomes unavailable.
    func fastReactivationProfileID(
        on snapshot: ActiveSpaceSnapshot
    ) -> String? {
        guard let profileID,
              !awaitsTargetBinding,
              let recordedTarget,
              let observedTarget =
                ProfileManualOverrideTarget(snapshot),
              recordedTarget.isSameLogicalTarget(
                as: observedTarget
              )
        else {
            return nil
        }
        return profileID
    }

    mutating func reconcileCommittedTarget(
        _ snapshot: ActiveSpaceSnapshot
    ) {
        guard profileID != nil,
              let committedTarget =
                ProfileManualOverrideTarget(snapshot)
        else {
            return
        }
        if awaitsTargetBinding {
            recordedTarget = committedTarget
            awaitsTargetBinding = false
            return
        }

        guard let recordedTarget else {
            self.recordedTarget = committedTarget
            awaitsTargetBinding = false
            return
        }
        guard recordedTarget.isSameLogicalTarget(
            as: committedTarget
        ) else {
            clear()
            return
        }

        // Upgrade an identity-less in-process observation once SkyLight
        // supplies the durable identity. Never downgrade a known identity if
        // one later observation temporarily omits it.
        if recordedTarget.identity == nil,
           committedTarget.identity != nil {
            self.recordedTarget = committedTarget
        } else if recordedTarget.identity != nil,
                  committedTarget.identity == nil {
            self.recordedTarget = recordedTarget
        } else {
            self.recordedTarget = committedTarget
        }
    }

}

nonisolated enum CurrentSpaceAssignmentAuthorizationPolicy {
    /// A reviewed assignment is authorized only if a fresh post-confirmation
    /// observation resolves the same identity and the ownership table has not
    /// changed in the meantime.
    static func permitsCommit(
        proposedIdentity: MissionControlSpaceIdentity,
        proposedOwnerProfileID: String?,
        freshlyObservedIdentity:
            MissionControlSpaceIdentity?,
        currentOwnerProfileID: String?
    ) -> Bool {
        freshlyObservedIdentity == proposedIdentity
            && currentOwnerProfileID
                == proposedOwnerProfileID
    }
}

nonisolated enum ProfileTriggerResolver {
    /// Resolves exact ownership first, then generic triggers. An unassigned
    /// Space never selects or mutates a profile implicitly.
    static func resolve(
        profiles: [ProfileTriggerEvaluationProfile],
        context: ProfileTriggerEvaluationContext
    ) -> ProfileTriggerResolution? {
        switch context.spaceAssignmentState {
        case .assigned(let profileID):
            // A dangling assignment is invalid authoritative state. Do not
            // hide it by falling through to a lower-priority generic rule.
            guard profiles.contains(where: { $0.id == profileID }) else {
                return nil
            }
            return ProfileTriggerResolution(
                profileID: profileID,
                specificity: 4,
                usedUnassignedSpaceFallback: false
            )
        case .unassignedRegular:
            // The transition that first discovers an unassigned Desktop keeps
            // the already-visible profile. Generic rules become eligible only
            // after a later app/time signal has independently revalidated that
            // the same Desktop is still current.
            guard context.allowsGenericRulesOnUnassignedRegular else {
                return nil
            }
        case .nonassignable:
            // Fullscreen/tiled Spaces have no durable exact assignment but can
            // still use the established time/app trigger behavior.
            break
        case .unresolved:
            // Unknown Space type/identity is never generic-trigger evidence.
            return nil
        }

        var best: ProfileTriggerResolution?
        var bestDateCreated: Date?

        for profile in profiles {
            var profileBestSpecificity: Int?
            for trigger in profile.triggers {
                guard matches(
                    trigger,
                    context: context
                ) else {
                    continue
                }
                if profileBestSpecificity.map({
                    trigger.specificity > $0
                }) ?? true {
                    profileBestSpecificity = trigger.specificity
                }
            }

            guard let specificity = profileBestSpecificity else { continue }
            let shouldReplaceBest: Bool
            if let best, let bestDateCreated {
                shouldReplaceBest =
                    specificity > best.specificity
                    || (
                        specificity == best.specificity
                        && profile.dateCreated < bestDateCreated
                    )
            } else {
                shouldReplaceBest = true
            }
            if shouldReplaceBest {
                best = ProfileTriggerResolution(
                    profileID: profile.id,
                    specificity: specificity,
                    usedUnassignedSpaceFallback:
                        context.spaceAssignmentState
                            == .unassignedRegular
                )
                bestDateCreated = profile.dateCreated
            }
        }

        return best
    }

    private static func matches(
        _ trigger: ProfileTrigger,
        context: ProfileTriggerEvaluationContext
    ) -> Bool {
        switch trigger {
        case .timeOfDay(let trigger):
            return trigger.matches(date: context.now)
        case .frontmostApp(let trigger):
            return context.frontmostBundleID == trigger.bundleIdentifier
        case .space(let trigger):
            return context.spaceApps.contains(trigger.bundleIdentifier)
        case .exactSpace:
            // Legacy rows are inert until explicitly repaired into the
            // globally-unique assignment table.
            return false
        }
    }
}
