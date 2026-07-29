//
//  ProfileService.swift
//  Docky
//
//  Owns Docky's profile state. Profiles and the active profile identifier
//  are persisted as one versioned document. That document is authoritative;
//  the older UserDefaults keys remain compatibility snapshots only.
//

import AppKit
import Foundation
import Observation

extension Notification.Name {
    static let profileActivationDidChange =
        Notification.Name(
            "Docky.profileActivationDidChange"
        )
    static let profileSpaceAssignmentsDidChange =
        Notification.Name(
            "Docky.profileSpaceAssignmentsDidChange"
        )
}

nonisolated enum ProfileActivationSource: String, Equatable, Sendable {
    case manual
    case trigger
    case launchReapply
    case deleteFallback
    case rollback
}

nonisolated struct ProfileActivationChange: Equatable, Sendable {
    let source: ProfileActivationSource
    let previousProfileID: String
    let newProfileID: String
}

nonisolated struct ProfileSpaceAssignmentChange: Equatable, Sendable {
    let identity: MissionControlSpaceIdentity
    let oldProfileID: String?
    let newProfileID: String?
}

typealias ProfileStoreDocument = ProfileStoreEnvelope<DockProfile>

extension DockProfile: ProfileStoreLegacyExactSpaceRepairable {}

@Observable
final class ProfileService {
    static var shared: ProfileService {
        ProfileStateBootstrap.shared.profileService
    }

    /// All known profiles, in user-defined order.
    private(set) var profiles: [DockProfile]

    /// Identifier of the currently-active profile.
    private(set) var activeProfileID: String

    /// Durable/default profile used at launch and whenever no automation owns
    /// the current context. This may differ from the runtime-active profile.
    var defaultProfileID: String {
        persistedActiveProfileID
    }

    /// The manual/default selection stored in the profile document. Automatic
    /// trigger activation changes `activeProfileID` only; keeping the durable
    /// selection separate prevents Space navigation from rotating profile
    /// backups or incrementing the document revision.
    private var persistedActiveProfileID: String

    /// Tracks whether the effective runtime profile is derived automation.
    /// On a durable-write rollback, a valid derived profile can remain visible
    /// even though the manual/default selection returns to its durable value.
    @ObservationIgnored
    private var runtimeActivationSource: ProfileActivationSource

    /// Globally unique exact-Space ownership. Profile content is never copied
    /// or mutated when this table changes.
    private(set) var spaceAssignments: [SpaceProfileAssignment]

    /// Set when existing persistence material could not be recovered safely.
    /// In this state Docky preserves the files and rejects profile mutations
    /// instead of overwriting potentially newer or recoverable data.
    private(set) var persistenceIsBlocked: Bool

    /// Most recent persistence failure, retained for diagnostics/UI surfacing.
    private(set) var lastPersistenceError: String?

    var activeProfile: DockProfile? {
        profiles.first(where: { $0.id == activeProfileID })
    }

    var hasLegacyExactSpaceTriggers: Bool {
        profiles.contains { profile in
            profile.triggers.contains {
                guard case .exactSpace(let trigger) = $0 else {
                    return false
                }
                return trigger.identity == nil
            }
        }
    }

    private weak var preferences: DockyPreferences?
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let store: AtomicJSONFileStore<ProfileStoreDocument>
    private var revision: UInt64

    /// Monotonic generation of the authoritative profile document.
    ///
    /// Long-lived interactions such as drag-and-drop capture this value at
    /// gesture start and use it as a compare-and-swap guard at commit. This
    /// prevents a drop from applying stale tile identities or indices after
    /// another settings/profile mutation changed the same layout.
    var stateRevision: UInt64 {
        revision
    }

    func captureMutationCredentials()
        -> ProfileMutationCredentials {
        ProfileMutationCredentials(
            profileID: activeProfileID,
            revision: revision
        )
    }

    private var didCompleteBootstrap = false
    @ObservationIgnored
    private lazy var persistenceCoordinator =
        CoalescingPersistenceCoordinator(
            initialDurableValue: currentDocument,
            persist: {
                [store] document,
                durablePredecessor in
                try store.save(
                    document,
                    validate: Self.validateDocument,
                    expectedPrimary:
                        .value(durablePredecessor)
                )
            },
            onEvent: { [weak self] event in
                self?.handlePersistenceEvent(event)
            }
        )
    @ObservationIgnored
    private lazy var legacySnapshotCoordinator =
        CoalescingPersistenceCoordinator(
            initialDurableValue: currentDocument,
            persist: { [defaults] document in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let documentData =
                    try ProfileStoreRecoverySnapshotCodec.encode(
                        document
                    )
                let profilesData = try encoder.encode(
                    document.profiles
                )
                if defaults.data(forKey: LegacyKeys.fullDocument)
                    != documentData {
                    defaults.set(
                        documentData,
                        forKey: LegacyKeys.fullDocument
                    )
                }
                if defaults.data(forKey: LegacyKeys.profiles)
                    != profilesData {
                    defaults.set(
                        profilesData,
                        forKey: LegacyKeys.profiles
                    )
                }
                if defaults.string(
                    forKey: LegacyKeys.activeProfileID
                ) != document.activeProfileID {
                    defaults.set(
                        document.activeProfileID,
                        forKey: LegacyKeys.activeProfileID
                    )
                }
                return documentData.count + profilesData.count
            },
            onEvent: { [weak self] event in
                self?.handleLegacySnapshotEvent(event)
            }
        )

    private enum LegacyKeys {
        static let fullDocument =
            "docky.profileStoreSnapshotV2"
        static let profiles = "docky.profiles"
        static let activeProfileID = "docky.activeProfileID"
    }

    private struct LegacyCandidate {
        let document: ProfileStoreDocument
        let source: String
        let storedActiveWasValid: Bool
        let failure: Error?
    }

    init(
        preferences: DockyPreferences,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.preferences = preferences
        self.defaults = defaults
        self.store = Self.makeDefaultStore(fileManager: fileManager)

        let rootDisplayScopeOverride =
            NSScreen.screensHaveSeparateSpaces
            ? nil
            : MissionControlSpaceIdentity.sharedDisplayScope
        let legacy = Self.makeLegacyCandidate(
            preferences: preferences,
            defaults: defaults,
            decoder: decoder,
            rootDisplayScopeOverride: rootDisplayScopeOverride
        )

        var initialDocument = legacy.document
        var blocked = false
        var persistenceError: String?
        var loadSource = legacy.source
        var recoveredFromBackup = false
        var migrated = false
        var encodedBytes: Int?

        do {
            if let loaded = try store.load(
                validate: Self.validateDocumentForLoad,
                canRecoverPrimaryFailure: { error in
                    guard let validationError = error as? ProfileStoreValidationError else {
                        return true
                    }
                    return !validationError.isForwardIncompatible
                }
            ) {
                initialDocument = loaded.value
                loadSource = loaded.source.rawValue
                recoveredFromBackup = loaded.source == .backup
                if let repairFailure =
                    loaded.primaryRepairFailureDescription {
                    blocked = true
                    persistenceError =
                        "The backup was loaded, but the primary could not be repaired: \(repairFailure)"
                }
                if initialDocument.schemaVersion
                    < ProfileStoreDocument.currentSchemaVersion {
                    initialDocument = try Self.migrateSchema1Document(
                        initialDocument,
                        rootDisplayScopeOverride:
                            rootDisplayScopeOverride
                    )
                    encodedBytes = try store.save(
                        initialDocument,
                        validate: Self.validateDocument,
                        validateExisting:
                            Self.validateDocumentForLoad,
                        expectedPrimary: .value(loaded.value),
                        archiveExistingGenerations: true
                    )
                    loadSource += "+schema1Migration"
                    migrated = true
                }
            } else if let legacyFailure = legacy.failure {
                blocked = true
                persistenceError = Self.describe(legacyFailure)
            } else {
                encodedBytes = try store.save(
                    legacy.document,
                    validate: Self.validateDocument,
                    expectedPrimary: .missing
                )
                migrated = true
            }
        } catch {
            // Existing primary/backup material is never overwritten after an
            // unrecoverable or forward-incompatible load. The legacy/top-level
            // snapshot is used in memory so Docky remains usable, but profile
            // mutations are rejected until the store is repaired.
            blocked = true
            persistenceError = Self.describe(error)
        }

        profiles = initialDocument.profiles
        activeProfileID = initialDocument.activeProfileID
        persistedActiveProfileID = initialDocument.activeProfileID
        runtimeActivationSource = .launchReapply
        spaceAssignments = initialDocument.spaceAssignments
        revision = initialDocument.revision
        persistenceIsBlocked = blocked
        lastPersistenceError = persistenceError

        let diagnostics = DiagnosticsTrace.shared
        if migrated {
            diagnostics.record(.profiles, "legacyProfileMigrated", fields: [
                "migrationSource": legacy.source,
                "activeProfileToken": diagnostics.token(activeProfileID),
                "storedActiveWasValid": legacy.storedActiveWasValid,
                "profileCount": profiles.count,
                "spaceAssignmentCount": spaceAssignments.count,
                "pinnedItemCount": activeProfile?.pinnedItems.count ?? 0,
                "trailingItemCount": activeProfile?.trailingItems.count ?? 0,
                "schemaVersion": ProfileStoreDocument.currentSchemaVersion,
                "revision": revision,
                "encodedBytes": encodedBytes ?? 0,
            ])
        } else {
            diagnostics.record(.profiles, "profilesLoaded", fields: [
                "loadSource": loadSource,
                "profileCount": profiles.count,
                "spaceAssignmentCount": spaceAssignments.count,
                "activeProfileToken": diagnostics.token(activeProfileID),
                "storedActiveWasValid": legacy.storedActiveWasValid,
                "schemaVersion": initialDocument.schemaVersion,
                "revision": revision,
                "recoveredFromBackup": recoveredFromBackup,
                "persistenceBlocked": blocked,
            ])
        }

        if let persistenceError {
            diagnostics.record(.profiles, "profileStoreLoadFailed", fields: [
                "fallbackSource": legacy.source,
                "profileCount": profiles.count,
                "activeProfileToken": diagnostics.token(activeProfileID),
                "error":
                    DiagnosticPrivacy.redactedTextDescriptor(
                        persistenceError
                    ),
                "persistenceBlocked": true,
            ])
        }
    }

    /// Called by `ProfileStateBootstrap` before either singleton becomes
    /// visible to a consumer. This closes the migration/reconciliation
    /// window in which a stale top-level preference could otherwise be
    /// mirrored back over authoritative profile state.
    func completeBootstrap() {
        guard !didCompleteBootstrap else { return }
        didCompleteBootstrap = true

        // The in-memory document is always the only authoritative profile
        // state, even when the store has entered a read-only/repair-required
        // mode. In particular, a valid backup must still be applied to the
        // UI; skipping it leaves ProfileService and top-level preferences
        // describing different configurations.
        if let profile = activeProfile {
            preferences?.applyProfile(profile)
            DiagnosticsTrace.shared.record(.profiles, "profileBootstrapApplied", fields: [
                "activeProfileToken": DiagnosticsTrace.shared.token(activeProfileID),
                "readOnly": persistenceIsBlocked,
            ])
        }

        if !persistenceIsBlocked {
            persistLegacyCompatibilitySnapshot()
        }

        DiagnosticsTrace.shared.record(.profiles, "profileBootstrapCompleted", fields: [
            "profileCount": profiles.count,
            "spaceAssignmentCount": spaceAssignments.count,
            "activeProfileToken": DiagnosticsTrace.shared.token(activeProfileID),
            "revision": revision,
            "persistenceBlocked": persistenceIsBlocked,
        ])
    }

    @discardableResult
    func setActiveProfile(
        id: String,
        source: ProfileActivationSource = .manual
    ) -> Bool {
        let diagnostics = DiagnosticsTrace.shared
        guard let profile = profiles.first(where: { $0.id == id }) else {
            diagnostics.record(.profiles, "profileActivationSkipped", fields: [
                "reason": "profileNotFound",
                "source": source.rawValue,
                "profileToken": diagnostics.token(id),
            ])
            return false
        }

        let previousID = activeProfileID
        let runtimeAlreadyActive = previousID == id
        let durableAlreadySelected = persistedActiveProfileID == id
        let manualDisposition =
            source == .manual
            ? ManualActivationDispositionPolicy.resolve(
                runtimeAlreadyActive: runtimeAlreadyActive,
                durableAlreadySelected: durableAlreadySelected
            )
            : nil

        if source == .trigger {
            guard !runtimeAlreadyActive else {
                diagnostics.record(
                    .profiles,
                    "profileActivationSkipped",
                    fields: [
                        "reason": "alreadyActive",
                        "source": source.rawValue,
                        "profileToken": diagnostics.token(id),
                    ]
                )
                return true
            }
            return activateRuntimeProfile(
                profile,
                source: source,
                previousID: previousID
            )
        }

        if let manualDisposition,
           manualDisposition.isVisuallyAndDurablyIdempotent {
            // This is an explicit user intent even when it is visually and
            // durably idempotent. Runtime policy uses the notification to
            // reassert a manual override for the current Space residency.
            runtimeActivationSource = .manual
            if manualDisposition.shouldEmitIntentNotification {
                postActivationChange(
                    source: .manual,
                    previousProfileID: previousID,
                    newProfileID: id
                )
            }
            diagnostics.record(.profiles, "profileActivationSkipped", fields: [
                "reason": "alreadyActiveAndPersisted",
                "source": source.rawValue,
                "profileToken": diagnostics.token(id),
            ])
            return true
        }

        diagnostics.record(.profiles, "profileActivationBegan", fields: [
            "source": source.rawValue,
            "previousProfileToken": diagnostics.token(previousID),
            "profileToken": diagnostics.token(id),
            "pinnedItemCount": profile.pinnedItems.count,
            "trailingItemCount": profile.trailingItems.count,
            "widgetPlacementCount": profile.widgetPlacements.count,
            "hiddenAppCount": profile.hiddenAppBundleIdentifiers.count,
        ])

        if manualDisposition?.shouldPersistDefault == true {
            guard commit(
                profiles: profiles,
                persistedActiveProfileID: id,
                reason: "manualActivation"
            ) else {
                diagnostics.record(
                    .profiles,
                    "profileActivationFailed",
                    fields: [
                        "source": source.rawValue,
                        "previousProfileToken":
                            diagnostics.token(previousID),
                        "profileToken": diagnostics.token(id),
                        "error":
                            DiagnosticPrivacy.redactedTextDescriptor(
                                lastPersistenceError
                            ),
                    ]
                )
                return false
            }
        }

        return activateRuntimeProfile(
            profile,
            source: source,
            previousID: previousID,
            applyProfile:
                manualDisposition?.shouldApplyLayout
                ?? !runtimeAlreadyActive
        )
    }

    @discardableResult
    private func activateRuntimeProfile(
        _ profile: DockProfile,
        source: ProfileActivationSource,
        previousID: String,
        applyProfile: Bool = true
    ) -> Bool {
        activeProfileID = profile.id
        runtimeActivationSource = source
        if applyProfile {
            preferences?.applyProfile(profile)
        }
        postActivationChange(
            source: source,
            previousProfileID: previousID,
            newProfileID: profile.id
        )

        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(.profiles, "profileActivationCompleted", fields: [
            "source": source.rawValue,
            "previousProfileToken": diagnostics.token(previousID),
            "profileToken": diagnostics.token(profile.id),
            "persistedProfileToken":
                diagnostics.token(persistedActiveProfileID),
            "revision": revision,
        ])
        return true
    }

    /// Reconciles the legacy top-level tile snapshot from the authoritative
    /// active profile. Bootstrap already performs this before consumers are
    /// exposed; this method remains an idempotent launch repair hook.
    func reapplyActiveProfile() {
        guard !persistenceIsBlocked else {
            DiagnosticsTrace.shared.record(.profiles, "profileReapplySkipped", fields: [
                "reason": "persistenceBlocked",
                "activeProfileToken": DiagnosticsTrace.shared.token(activeProfileID),
                "error":
                    DiagnosticPrivacy.redactedTextDescriptor(
                        lastPersistenceError
                    ),
            ])
            return
        }
        guard let profile = activeProfile else {
            DiagnosticsTrace.shared.record(.profiles, "profileReapplySkipped", fields: [
                "reason": "activeProfileUnavailable",
                "activeProfileToken": DiagnosticsTrace.shared.token(activeProfileID),
            ])
            return
        }
        DiagnosticsTrace.shared.record(.profiles, "profileReapplyBegan", fields: [
            "source": ProfileActivationSource.launchReapply.rawValue,
            "profileToken": DiagnosticsTrace.shared.token(profile.id),
            "pinnedItemCount": profile.pinnedItems.count,
            "trailingItemCount": profile.trailingItems.count,
            "revision": revision,
        ])
        preferences?.applyProfile(profile)
        DiagnosticsTrace.shared.record(.profiles, "profileReapplyCompleted", fields: [
            "source": ProfileActivationSource.launchReapply.rawValue,
            "profileToken": DiagnosticsTrace.shared.token(profile.id),
            "revision": revision,
        ])
    }

    /// Apply a mutation to the authoritative active profile. The in-memory
    /// value is published immediately; durable writes are serialized and
    /// coalesced off the UI thread. A failure restores the last durable value.
    @discardableResult
    func updateActiveProfile(_ mutate: (inout DockProfile) -> Void) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
            recordMutationFailure(reason: "activeProfileUnavailable")
            return false
        }

        let before = profiles[index]
        var candidateProfiles = profiles
        mutate(&candidateProfiles[index])
        guard candidateProfiles[index] != before else {
            return true
        }

        guard commit(
            profiles: candidateProfiles,
            reason: "activeProfileMutation"
        ) else {
            return false
        }

        let after = candidateProfiles[index]
        DiagnosticsTrace.shared.record(.profiles, "activeProfileMutated", fields: [
            "profileToken": DiagnosticsTrace.shared.token(activeProfileID),
            "pinnedItemCountBefore": before.pinnedItems.count,
            "pinnedItemCount": after.pinnedItems.count,
            "trailingItemCountBefore": before.trailingItems.count,
            "trailingItemCount": after.trailingItems.count,
            "widgetPlacementCountBefore": before.widgetPlacements.count,
            "widgetPlacementCount": after.widgetPlacements.count,
            "hiddenAppCountBefore": before.hiddenAppBundleIdentifiers.count,
            "hiddenAppCount": after.hiddenAppBundleIdentifiers.count,
            "revision": revision,
        ])
        return true
    }

    /// Commits one complete active-profile mutation guarded by the profile
    /// identity and document revision captured when an interaction began.
    ///
    /// Unlike assigning several `DockyPreferences` properties in sequence,
    /// this publishes one candidate document or nothing. After acceptance the
    /// compatibility preference snapshot is updated from that same committed
    /// profile while `applyProfile` suppresses mirror-back writes.
    @discardableResult
    func applyActiveProfileTransaction(
        expectedProfileID: String,
        expectedRevision: UInt64,
        reason: String,
        mutate: (inout DockProfile) -> Void
    ) -> Bool {
        applyActiveProfileTransaction(
            credentials:
                ProfileMutationCredentials(
                    profileID: expectedProfileID,
                    revision: expectedRevision
                ),
            reason: reason,
            mutate: mutate
        )
    }

    /// Credential-based form used by work that spans an `await`. The
    /// credentials must be captured before the asynchronous operation starts.
    @discardableResult
    func applyActiveProfileTransaction(
        credentials: ProfileMutationCredentials,
        reason: String,
        mutate: (inout DockProfile) -> Void
    ) -> Bool {
        let diagnostics = DiagnosticsTrace.shared
        let expectedProfileID = credentials.profileID
        let expectedRevision = credentials.revision
        switch credentials.validation(
            activeProfileID: activeProfileID,
            currentRevision: revision
        ) {
        case .profileChanged:
            diagnostics.record(.profiles, "activeProfileTransactionRejected", fields: [
                "reason": "profileChanged",
                "expectedProfileToken": diagnostics.token(expectedProfileID),
                "activeProfileToken": diagnostics.token(activeProfileID),
                "expectedRevision": expectedRevision,
                "revision": revision,
            ])
            return false
        case .revisionChanged:
            diagnostics.record(.profiles, "activeProfileTransactionRejected", fields: [
                "reason": "revisionChanged",
                "profileToken": diagnostics.token(activeProfileID),
                "expectedRevision": expectedRevision,
                "revision": revision,
            ])
            return false
        case .current:
            break
        }
        guard let index = profiles.firstIndex(where: { $0.id == expectedProfileID }) else {
            recordMutationFailure(
                reason: "activeProfileUnavailable",
                profileID: expectedProfileID
            )
            return false
        }

        let before = profiles[index]
        var candidateProfiles = profiles
        mutate(&candidateProfiles[index])
        let after = candidateProfiles[index]
        guard after != before else {
            diagnostics.record(.profiles, "activeProfileTransactionNoChange", fields: [
                "reason": reason,
                "profileToken": diagnostics.token(expectedProfileID),
                "revision": revision,
            ])
            return true
        }

        guard commit(
            profiles: candidateProfiles,
            reason: reason
        ) else {
            diagnostics.record(.profiles, "activeProfileTransactionRejected", fields: [
                "reason": "commitFailed",
                "mutationReason": reason,
                "profileToken": diagnostics.token(expectedProfileID),
                "expectedRevision": expectedRevision,
                "revision": revision,
                "error":
                    DiagnosticPrivacy.redactedTextDescriptor(
                        lastPersistenceError
                    ),
            ])
            return false
        }

        preferences?.applyProfile(after)
        diagnostics.record(.profiles, "activeProfileTransactionApplied", fields: [
            "reason": reason,
            "profileToken": diagnostics.token(expectedProfileID),
            "pinnedItemCountBefore": before.pinnedItems.count,
            "pinnedItemCount": after.pinnedItems.count,
            "trailingItemCountBefore": before.trailingItems.count,
            "trailingItemCount": after.trailingItems.count,
            "revision": revision,
        ])
        return true
    }

    @discardableResult
    func createProfile(
        name: String,
        symbolName: String = "circle.grid.3x3.fill",
        basedOn: DockProfile? = nil
    ) -> DockProfile? {
        let canonicalName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let profile = DockProfile(
            name: canonicalName,
            symbolName: symbolName,
            pinnedItems: basedOn?.pinnedItems ?? [],
            trailingItems: basedOn?.trailingItems ?? [],
            widgetPlacements: basedOn?.widgetPlacements ?? [],
            appWidgetDisplays: basedOn?.appWidgetDisplays ?? [],
            hiddenAppBundleIdentifiers: basedOn?.hiddenAppBundleIdentifiers ?? []
        )
        var candidateProfiles = profiles
        candidateProfiles.append(profile)
        guard commit(
            profiles: candidateProfiles,
            reason: "createProfile"
        ) else {
            return nil
        }
        return profile
    }

    @discardableResult
    func renameProfile(id: String, to newName: String) -> Bool {
        let canonicalName = newName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return mutateProfile(id: id, reason: "renameProfile") {
            $0.name = canonicalName
        }
    }

    @discardableResult
    func updateProfileSymbol(id: String, symbolName: String) -> Bool {
        mutateProfile(id: id, reason: "updateProfileSymbol") {
            $0.symbolName = symbolName
        }
    }

    @discardableResult
    func addTrigger(_ trigger: ProfileTrigger, to profileID: String) -> Bool {
        mutateProfile(id: profileID, reason: "addTrigger") {
            $0.triggers.append(trigger)
        }
    }

    func profileIDAssigned(
        to identity: MissionControlSpaceIdentity?
    ) -> String? {
        SpaceProfileAssignmentPolicy.profileID(
            for: identity,
            in: spaceAssignments
        )
    }

    /// Resolves exact ownership only from the document that has actually
    /// reached durable storage. A pending unrelated edit is allowed, but the
    /// current owner and target profile must still match their durable values.
    /// A load/repair or write failure makes the fallback document
    /// non-authoritative and disables immediate activation.
    func durableSpaceAssignmentState(
        for identity: MissionControlSpaceIdentity?
    ) -> ProfileDurableSpaceAssignmentState {
        let durableDocument =
            persistenceCoordinator.durableValueSnapshot
        let assignedProfileID =
            SpaceProfileAssignmentPolicy.profileID(
                for: identity,
                in: durableDocument.spaceAssignments
            )
        let validProfileID = assignedProfileID.flatMap { profileID in
            durableDocument.profiles.contains(where: {
                $0.id == profileID
            })
                ? profileID
                : nil
        }
        let currentAssignedProfileID =
            SpaceProfileAssignmentPolicy.profileID(
                for: identity,
                in: spaceAssignments
            )
        let durableProfile = validProfileID.flatMap { profileID in
            durableDocument.profiles.first(where: {
                $0.id == profileID
            })
        }
        let currentProfile = validProfileID.flatMap { profileID in
            profiles.first(where: {
                $0.id == profileID
            })
        }
        return ProfileDurableSpaceAssignmentState(
            profileID: validProfileID,
            currentOwnerMatchesDurable:
                currentAssignedProfileID == validProfileID,
            targetProfileMatchesDurable:
                durableProfile != nil
                && currentProfile == durableProfile,
            persistenceIsAuthoritative:
                !persistenceIsBlocked,
            currentRevision: revision,
            durableRevision: durableDocument.revision
        )
    }

    func spaceAssignments(
        for profileID: String
    ) -> [SpaceProfileAssignment] {
        spaceAssignments.filter { $0.profileID == profileID }
    }

    /// Assigns only the supplied Space. Existing ownership for that Space is
    /// replaced atomically; every other assignment and all profile content are
    /// preserved byte-for-byte by the candidate model.
    @discardableResult
    func assignSpace(
        _ identity: MissionControlSpaceIdentity,
        to profileID: String
    ) -> Bool {
        guard profiles.contains(where: { $0.id == profileID }) else {
            recordMutationFailure(
                reason: "spaceAssignmentProfileNotFound",
                profileID: profileID
            )
            return false
        }
        let oldProfileID = profileIDAssigned(to: identity)
        guard let candidateDocument =
            ProfileStoreDocumentMutationPolicy.assigningSpace(
                identity,
                to: profileID,
                in: currentDocument
            )
        else {
            return false
        }
        guard candidateDocument.spaceAssignments
                != spaceAssignments
        else {
            return true
        }
        let didCommit = commit(
            profiles: candidateDocument.profiles,
            persistedActiveProfileID:
                candidateDocument.activeProfileID,
            spaceAssignments:
                candidateDocument.spaceAssignments,
            reason: "assignSpace"
        )
        if didCommit {
            postSpaceAssignmentChange(
                identity: identity,
                oldProfileID: oldProfileID,
                newProfileID: profileID
            )
        }
        return didCommit
    }

    @discardableResult
    func removeSpaceAssignment(
        _ identity: MissionControlSpaceIdentity,
        from profileID: String
    ) -> Bool {
        let oldProfileID = profileIDAssigned(to: identity)
        let candidateDocument =
            ProfileStoreDocumentMutationPolicy
            .removingSpaceAssignment(
                identity,
                from: profileID,
                in: currentDocument
            )
        guard candidateDocument.spaceAssignments
                != spaceAssignments
        else {
            return true
        }
        let didCommit = commit(
            profiles: candidateDocument.profiles,
            persistedActiveProfileID:
                candidateDocument.activeProfileID,
            spaceAssignments:
                candidateDocument.spaceAssignments,
            reason: "removeSpaceAssignment"
        )
        if didCommit {
            postSpaceAssignmentChange(
                identity: identity,
                oldProfileID: oldProfileID,
                newProfileID: nil
            )
        }
        return didCommit
    }

    /// Converts one inert legacy exact-Space trigger into global ownership and
    /// removes that trigger in the same document commit. The expected owner is
    /// a compare-and-swap guard captured by the confirmation UI.
    @discardableResult
    func repairLegacyExactSpaceBinding(
        triggerID: String,
        in profileID: String,
        assigning identity: MissionControlSpaceIdentity,
        expectedOwnerProfileID: String?
    ) -> Bool {
        guard let candidateDocument =
            ProfileStoreDocumentMutationPolicy
            .repairingLegacyExactSpaceBinding(
                profileID: profileID,
                triggerID: triggerID,
                assigning: identity,
                expectedOwnerProfileID:
                    expectedOwnerProfileID,
                in: currentDocument
            )
        else {
            recordMutationFailure(
                reason: "legacyExactSpaceRepairRejected",
                profileID: profileID
            )
            return false
        }

        let didCommit = commit(
            profiles: candidateDocument.profiles,
            persistedActiveProfileID:
                candidateDocument.activeProfileID,
            spaceAssignments:
                candidateDocument.spaceAssignments,
            reason: "repairLegacyExactSpaceBinding"
        )
        if didCommit {
            postSpaceAssignmentChange(
                identity: identity,
                oldProfileID: expectedOwnerProfileID,
                newProfileID: profileID
            )
        }
        return didCommit
    }

    @discardableResult
    func updateTrigger(_ trigger: ProfileTrigger, in profileID: String) -> Bool {
        mutateProfile(id: profileID, reason: "updateTrigger") { profile in
            guard let index = profile.triggers.firstIndex(where: { $0.id == trigger.id }) else {
                return
            }
            profile.triggers[index] = trigger
        }
    }

    @discardableResult
    func removeTrigger(_ triggerID: String, from profileID: String) -> Bool {
        mutateProfile(id: profileID, reason: "removeTrigger") {
            $0.triggers.removeAll { $0.id == triggerID }
        }
    }

    @discardableResult
    func deleteProfile(id: String) -> Bool {
        guard let candidateDocument =
            ProfileStoreDocumentMutationPolicy.deletingProfile(
                id,
                from: currentDocument
            )
        else {
            return false
        }

        let previousRuntimeID = activeProfileID
        let wasRuntimeActive = previousRuntimeID == id
        let candidateProfiles = candidateDocument.profiles
        guard let candidateRuntimeID =
            ProfileStoreDocumentMutationPolicy
            .runtimeProfileIDAfterDeleting(
                id,
                previousRuntimeProfileID:
                    previousRuntimeID,
                from: candidateDocument
            )
        else {
            recordMutationFailure(
                reason: "deleteProfileRuntimeFallbackUnavailable",
                profileID: id
            )
            return false
        }
        let removedAssignments = spaceAssignments.filter {
            $0.profileID == id
        }

        guard commit(
            profiles: candidateProfiles,
            persistedActiveProfileID:
                candidateDocument.activeProfileID,
            spaceAssignments:
                candidateDocument.spaceAssignments,
            reason: "deleteProfile"
        ) else {
            return false
        }

        if wasRuntimeActive,
           let fallback = candidateProfiles.first(where: {
               $0.id == candidateRuntimeID
           }) {
            _ = activateRuntimeProfile(
                fallback,
                source: .deleteFallback,
                previousID: previousRuntimeID
            )
        }
        for assignment in removedAssignments {
            postSpaceAssignmentChange(
                identity: assignment.identity,
                oldProfileID: id,
                newProfileID: nil
            )
        }
        return true
    }

    @discardableResult
    private func mutateProfile(
        id: String,
        reason: String,
        mutate: (inout DockProfile) -> Void
    ) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            recordMutationFailure(reason: "profileNotFound", profileID: id)
            return false
        }
        var candidateProfiles = profiles
        let before = candidateProfiles[index]
        mutate(&candidateProfiles[index])
        guard candidateProfiles[index] != before else {
            return true
        }
        return commit(
            profiles: candidateProfiles,
            reason: reason
        )
    }

    private func commit(
        profiles candidateProfiles: [DockProfile],
        persistedActiveProfileID candidatePersistedActiveProfileID:
            String? = nil,
        spaceAssignments candidateSpaceAssignments:
            [SpaceProfileAssignment]? = nil,
        reason: String
    ) -> Bool {
        let diagnostics = DiagnosticsTrace.shared
        guard !persistenceIsBlocked else {
            recordMutationFailure(
                reason: "persistenceBlocked",
                error: lastPersistenceError
            )
            return false
        }
        guard revision < UInt64.max else {
            let error = ProfileStoreValidationError.revisionExhausted
            lastPersistenceError = Self.describe(error)
            recordMutationFailure(reason: reason, error: lastPersistenceError)
            return false
        }

        let resolvedPersistedActiveProfileID =
            candidatePersistedActiveProfileID
            ?? persistedActiveProfileID
        let resolvedSpaceAssignments =
            candidateSpaceAssignments ?? spaceAssignments
        let document = ProfileStoreDocument(
            revision: revision + 1,
            activeProfileID: resolvedPersistedActiveProfileID,
            profiles: candidateProfiles,
            spaceAssignments: resolvedSpaceAssignments
        )

        do {
            try Self.validateDocument(document)
        } catch {
            lastPersistenceError = Self.describe(error)
            recordMutationFailure(reason: reason, error: lastPersistenceError)
            return false
        }

        guard persistenceCoordinator.submit(document) else {
            lastPersistenceError =
                persistenceCoordinator.failureDescription
                ?? "Profile persistence is unavailable."
            recordMutationFailure(reason: reason, error: lastPersistenceError)
            return false
        }

        profiles = candidateProfiles
        persistedActiveProfileID = resolvedPersistedActiveProfileID
        spaceAssignments = resolvedSpaceAssignments
        revision = document.revision
        lastPersistenceError = nil

        diagnostics.record(.profiles, "profilePersistenceScheduled", fields: [
            "reason": reason,
            "profileCount": profiles.count,
            "spaceAssignmentCount": spaceAssignments.count,
            "activeProfileToken":
                diagnostics.token(persistedActiveProfileID),
            "runtimeProfileToken": diagnostics.token(activeProfileID),
            "schemaVersion": document.schemaVersion,
            "revision": revision,
        ])
        return true
    }

    private func persistLegacyCompatibilitySnapshot() {
        persistLegacyCompatibilitySnapshot(document: currentDocument)
    }

    private func persistLegacyCompatibilitySnapshot(
        document: ProfileStoreDocument
    ) {
        guard legacySnapshotCoordinator.submit(document) else {
            let diagnostics = DiagnosticsTrace.shared
            diagnostics.record(
                .profiles,
                "legacyProfileSnapshotPersistSkipped",
                fields: [
                    "profileCount": document.profiles.count,
                    "activeProfileToken": diagnostics.token(
                        document.activeProfileID
                    ),
                    "revision": document.revision,
                    "error":
                        DiagnosticPrivacy.redactedTextDescriptor(
                            legacySnapshotCoordinator.failureDescription
                        ),
                ]
            )
            return
        }
    }

    private func handleLegacySnapshotEvent(
        _ event:
            CoalescingPersistenceCoordinator<ProfileStoreDocument>.Event
    ) {
        guard case .failed(
            let attemptedDocument,
            _,
            let errorDescription
        ) = event else {
            return
        }
        let diagnostics = DiagnosticsTrace.shared
        diagnostics.record(
            .profiles,
            "legacyProfileSnapshotPersistFailed",
            fields: [
                "profileCount": attemptedDocument.profiles.count,
                "activeProfileToken": diagnostics.token(
                    attemptedDocument.activeProfileID
                ),
                "revision": attemptedDocument.revision,
                "error":
                    DiagnosticPrivacy.redactedTextDescriptor(
                        errorDescription
                    ),
            ]
        )
    }

    /// Ensures every accepted profile mutation has reached durable storage
    /// before orderly process termination.
    func flushPersistence() {
        persistenceCoordinator.flush()
        legacySnapshotCoordinator.flush()
    }

    private var currentDocument: ProfileStoreDocument {
        ProfileStoreDocument(
            revision: revision,
            activeProfileID: persistedActiveProfileID,
            profiles: profiles,
            spaceAssignments: spaceAssignments
        )
    }

    private func postActivationChange(
        source: ProfileActivationSource,
        previousProfileID: String,
        newProfileID: String
    ) {
        NotificationCenter.default.post(
            name: .profileActivationDidChange,
            object: ProfileActivationChange(
                source: source,
                previousProfileID: previousProfileID,
                newProfileID: newProfileID
            )
        )
    }

    private func postSpaceAssignmentChange(
        identity: MissionControlSpaceIdentity,
        oldProfileID: String?,
        newProfileID: String?
    ) {
        guard oldProfileID != newProfileID else { return }
        NotificationCenter.default.post(
            name: .profileSpaceAssignmentsDidChange,
            object: ProfileSpaceAssignmentChange(
                identity: identity,
                oldProfileID: oldProfileID,
                newProfileID: newProfileID
            )
        )
    }

    private func postSpaceAssignmentChanges(
        from oldAssignments: [SpaceProfileAssignment],
        to newAssignments: [SpaceProfileAssignment]
    ) {
        let oldOwners = assignmentOwners(in: oldAssignments)
        let newOwners = assignmentOwners(in: newAssignments)
        let identities = Set(oldOwners.keys).union(newOwners.keys)
            .sorted { $0.storageKey < $1.storageKey }

        for identity in identities {
            postSpaceAssignmentChange(
                identity: identity,
                oldProfileID: oldOwners[identity],
                newProfileID: newOwners[identity]
            )
        }
    }

    private func assignmentOwners(
        in assignments: [SpaceProfileAssignment]
    ) -> [MissionControlSpaceIdentity: String] {
        assignments.reduce(into: [:]) { result, assignment in
            // Valid documents contain one owner per identity. Assignment via
            // subscript remains fail-safe if an already-loaded in-memory value
            // is being rolled back after a persistence failure.
            result[assignment.identity] = assignment.profileID
        }
    }

    private func handlePersistenceEvent(
        _ event:
            CoalescingPersistenceCoordinator<ProfileStoreDocument>.Event
    ) {
        let diagnostics = DiagnosticsTrace.shared
        switch event {
        case .persisted(let document, let encodedBytes):
            persistLegacyCompatibilitySnapshot(document: document)
            if document.revision == revision {
                lastPersistenceError = nil
            }
            diagnostics.record(.profiles, "profilesPersisted", fields: [
                "profileCount": document.profiles.count,
                "spaceAssignmentCount":
                    document.spaceAssignments.count,
                "activeProfileToken": diagnostics.token(
                    document.activeProfileID
                ),
                "schemaVersion": document.schemaVersion,
                "revision": document.revision,
                "encodedBytes": encodedBytes,
            ])

        case .failed(
            let attemptedDocument,
            let durableDocument,
            let errorDescription
        ):
            let previousRuntimeProfileID = activeProfileID
            let previousRuntimeSource = runtimeActivationSource
            let previousAssignments = spaceAssignments

            persistenceIsBlocked = true
            lastPersistenceError = errorDescription
            profiles = durableDocument.profiles
            persistedActiveProfileID = durableDocument.activeProfileID
            spaceAssignments = durableDocument.spaceAssignments
            revision = durableDocument.revision

            let preservesDerivedRuntimeProfile =
                previousRuntimeSource == .trigger
                && profiles.contains(where: {
                    $0.id == previousRuntimeProfileID
                })
            let restoredRuntimeProfileID =
                preservesDerivedRuntimeProfile
                ? previousRuntimeProfileID
                : durableDocument.activeProfileID
            activeProfileID = restoredRuntimeProfileID
            runtimeActivationSource =
                preservesDerivedRuntimeProfile ? .trigger : .rollback

            persistLegacyCompatibilitySnapshot(document: durableDocument)
            if let restoredProfile = activeProfile {
                preferences?.applyProfile(restoredProfile)
            }
            postActivationChange(
                source: .rollback,
                previousProfileID: previousRuntimeProfileID,
                newProfileID: restoredRuntimeProfileID
            )
            postSpaceAssignmentChanges(
                from: previousAssignments,
                to: durableDocument.spaceAssignments
            )

            diagnostics.record(.profiles, "profilesPersistFailed", fields: [
                "attemptedProfileCount":
                    attemptedDocument.profiles.count,
                "attemptedProfileToken": diagnostics.token(
                    attemptedDocument.activeProfileID
                ),
                "attemptedRevision": attemptedDocument.revision,
                "durableRevision": durableDocument.revision,
                "error":
                    DiagnosticPrivacy.redactedTextDescriptor(
                        errorDescription
                    ),
                "persistenceBlocked": true,
            ])
        }
    }

    private func recordMutationFailure(
        reason: String,
        profileID: String? = nil,
        error: String? = nil
    ) {
        DiagnosticsTrace.shared.record(.profiles, "profileMutationRejected", fields: [
            "reason": reason,
            "profileToken": DiagnosticsTrace.shared.token(profileID),
            "activeProfileToken": DiagnosticsTrace.shared.token(activeProfileID),
            "revision": revision,
            "error":
                DiagnosticPrivacy.redactedTextDescriptor(error),
        ])
    }

    private static func makeDefaultStore(
        fileManager: FileManager
    ) -> AtomicJSONFileStore<ProfileStoreDocument> {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return AtomicJSONFileStore(
            applicationSupportURL: applicationSupport,
            relativeDirectoryComponents: ["Docky", "Profiles"],
            primaryFileName: "profiles.json",
            backupFileName: "profiles.backup.json"
        )
    }

    /// File-size limits bound decoder allocation; these semantic limits keep
    /// a valid JSON document from creating pathological UI/service workloads.
    private enum DocumentLimits {
        nonisolated static let profiles = 128
        nonisolated static let itemsPerSection = 4_096
        nonisolated static let widgetsPerProfile = 2_048
        nonisolated static let hiddenAppsPerProfile = 4_096
        nonisolated static let triggersPerProfile = 256
        nonisolated static let nestedIdentifiers = 4_096
        nonisolated static let settingsPerWidget = 128
        nonisolated static let settingListValues = 1_024
        nonisolated static let identifierBytes = 4_096
        nonisolated static let profileNameBytes = 512
        nonisolated static let symbolNameBytes = 256
        nonisolated static let folderURLBytes = 16_384
    }

    private nonisolated static func validateDocument(
        _ document: ProfileStoreDocument
    ) throws {
        try ProfileStoreDocument.validate(document)
        try validateDocumentPayload(document)
    }

    private nonisolated static func validateDocumentForLoad(
        _ document: ProfileStoreDocument
    ) throws {
        try ProfileStoreDocument.validateForLoad(document)
        try validateDocumentPayload(document)
    }

    private nonisolated static func validateDocumentPayload(
        _ document: ProfileStoreDocument
    ) throws {
        try ProfileStoreProfileMetadataPolicy.validate(
            document.profiles.map {
                ProfileStoreProfileMetadata(
                    profileID: $0.id,
                    name: $0.name,
                    triggerIDs: $0.triggers.map(\.id)
                )
            }
        )
        for profile in document.profiles {
            try validateString(
                profile.name,
                field: "profileNameBytes",
                maximum: DocumentLimits.profileNameBytes
            )
            try validateString(
                profile.symbolName,
                field: "profileSymbolBytes",
                maximum: DocumentLimits.symbolNameBytes
            )
            guard profile.dateCreated.timeIntervalSinceReferenceDate
                    .isFinite else {
                throw ProfileStoreValidationError.limitExceeded(
                    field: "profileDate",
                    maximum: 0
                )
            }
            try validateCount(
                profile.pinnedItems.count,
                field: "pinnedItems",
                maximum: DocumentLimits.itemsPerSection
            )
            try validateCount(
                profile.trailingItems.count,
                field: "trailingItems",
                maximum: DocumentLimits.itemsPerSection
            )
            try validateCount(
                profile.widgetPlacements.count,
                field: "widgetPlacements",
                maximum: DocumentLimits.widgetsPerProfile
            )
            try validateCount(
                profile.appWidgetDisplays.count,
                field: "appWidgetDisplays",
                maximum: DocumentLimits.widgetsPerProfile
            )
            try validateCount(
                profile.hiddenAppBundleIdentifiers.count,
                field: "hiddenApps",
                maximum: DocumentLimits.hiddenAppsPerProfile
            )
            try validateCount(
                profile.triggers.count,
                field: "profileTriggers",
                maximum: DocumentLimits.triggersPerProfile
            )

            for item in profile.pinnedItems {
                try validateString(item.id, field: "pinnedItemID")
                try validateString(
                    item.bundleIdentifier,
                    field: "pinnedBundleIdentifier"
                )
                try validateString(
                    item.folderDisplayName,
                    field: "appFolderName"
                )
                try validateString(
                    item.widgetOwnerBundleIdentifier,
                    field: "widgetOwner"
                )
                try validateStringArray(
                    item.folderBundleIdentifiers,
                    field: "appFolderIdentifiers"
                )
                try validateStringArray(
                    item.hiddenWidgetOwnerBundleIdentifiers,
                    field: "hiddenWidgetOwners"
                )
                try validateSettings(item.widgetSettings)
            }

            for item in profile.trailingItems {
                try validateString(item.id, field: "trailingItemID")
                try validateString(
                    item.sourceTileID,
                    field: "sourceTileID"
                )
                try validateString(
                    item.folderDisplayName,
                    field: "folderName"
                )
                try validateString(
                    item.widgetOwnerBundleIdentifier,
                    field: "widgetOwner"
                )
                if let url = item.folderURL {
                    try validateString(
                        url.absoluteString,
                        field: "folderURLBytes",
                        maximum: DocumentLimits.folderURLBytes
                    )
                }
                try validateStringArray(
                    item.hiddenWidgetOwnerBundleIdentifiers,
                    field: "hiddenWidgetOwners"
                )
                try validateSettings(item.widgetSettings)
            }

            for placement in profile.widgetPlacements {
                try validateString(
                    placement.ownerBundleIdentifier,
                    field: "widgetOwner"
                )
                try validateString(
                    placement.kind.rawValue,
                    field: "widgetKind"
                )
            }
            for display in profile.appWidgetDisplays {
                try validateString(
                    display.bundleIdentifier,
                    field: "widgetDisplayBundle"
                )
                try validateString(
                    display.kind.rawValue,
                    field: "widgetKind"
                )
            }
            try validateStringArray(
                profile.hiddenAppBundleIdentifiers,
                field: "hiddenApps"
            )
            for trigger in profile.triggers {
                try validateTrigger(trigger)
            }
        }
    }

    private nonisolated static func validateTrigger(
        _ trigger: ProfileTrigger
    ) throws {
        switch trigger {
        case .timeOfDay(let value):
            try validateString(value.id, field: "triggerID")
            guard (0...1_439).contains(value.startMinuteOfDay),
                  (0...1_439).contains(value.endMinuteOfDay),
                  value.weekdays.isSubset(of: Set(1...7)) else {
                throw ProfileStoreValidationError.limitExceeded(
                    field: "timeTriggerRange",
                    maximum: 1_439
                )
            }
        case .frontmostApp(let value):
            try validateString(value.id, field: "triggerID")
            try validateString(
                value.bundleIdentifier,
                field: "triggerBundleIdentifier"
            )
        case .space(let value):
            try validateString(value.id, field: "triggerID")
            try validateString(
                value.bundleIdentifier,
                field: "triggerBundleIdentifier"
            )
        case .exactSpace(let value):
            try validateString(value.id, field: "triggerID")
            try validateString(
                value.displayUUID,
                field: "triggerDisplayUUID"
            )
            try validateString(
                value.spaceUUID,
                field: "triggerSpaceUUID"
            )
        }
    }

    private nonisolated static func validateSettings(
        _ settings: WidgetSettings?
    ) throws {
        guard let settings else { return }
        try validateCount(
            settings.count,
            field: "widgetSettings",
            maximum: DocumentLimits.settingsPerWidget
        )
        for (key, value) in settings {
            try validateString(key, field: "widgetSettingKey")
            switch value {
            case .string(let string):
                try validateString(string, field: "widgetSettingValue")
            case .number(let number):
                guard number.isFinite, abs(number) <= 1_000_000_000 else {
                    throw ProfileStoreValidationError.limitExceeded(
                        field: "widgetSettingNumber",
                        maximum: 1_000_000_000
                    )
                }
            case .bool:
                break
            case .stringList(let strings):
                try validateCount(
                    strings.count,
                    field: "widgetSettingList",
                    maximum: DocumentLimits.settingListValues
                )
                for string in strings {
                    try validateString(
                        string,
                        field: "widgetSettingListValue"
                    )
                }
            }
        }
    }

    private nonisolated static func validateStringArray(
        _ values: [String],
        field: String
    ) throws {
        try validateCount(
            values.count,
            field: field,
            maximum: DocumentLimits.nestedIdentifiers
        )
        for value in values {
            try validateString(value, field: field)
        }
    }

    private nonisolated static func validateString(
        _ value: String?,
        field: String,
        maximum: Int = DocumentLimits.identifierBytes
    ) throws {
        guard let value else { return }
        guard value.utf8.count <= maximum else {
            throw ProfileStoreValidationError.limitExceeded(
                field: field,
                maximum: maximum
            )
        }
    }

    private nonisolated static func validateCount(
        _ count: Int,
        field: String,
        maximum: Int
    ) throws {
        guard count <= maximum else {
            throw ProfileStoreValidationError.limitExceeded(
                field: field,
                maximum: maximum
            )
        }
    }

    /// Schema 1 embedded exact Space ownership inside each profile's generic
    /// trigger list. Schema 2 extracts only unambiguous UUID identities into a
    /// global table. Numeric IDs and cross-profile conflicts remain visible as
    /// inert repair rows; they are never guessed.
    private nonisolated static func migrateSchema1Document(
        _ document: ProfileStoreDocument,
        rootDisplayScopeOverride: String?
    ) throws -> ProfileStoreDocument {
        guard document.schemaVersion == 1 else { return document }
        guard document.revision < UInt64.max else {
            throw ProfileStoreValidationError.revisionExhausted
        }

        let migrationPlan =
            LegacyExactSpaceAssignmentMigrationPolicy.makePlan(
                profiles: document.profiles.map {
                    LegacyExactSpaceMigrationProfileInput(
                        profileID: $0.id,
                        triggers: $0.triggers
                    )
                },
                rootDisplayScopeOverride: rootDisplayScopeOverride
            )
        let mergedAssignments =
            try ProfileStoreSchemaMigrationPolicy
            .mergingSpaceAssignments(
                existing: document.spaceAssignments,
                migrated: migrationPlan.assignments
            )

        let migratedProfiles = document.profiles.map { profile in
            var migrated = profile
            let migratedIdentities = Set(
                migrationPlan.migratedIdentities(for: profile.id)
            )
            migrated.triggers.removeAll { trigger in
                guard case .exactSpace(let exact) = trigger,
                      let identity =
                          LegacyExactSpaceAssignmentMigrationPolicy
                          .migrationIdentity(
                              for: exact,
                              rootDisplayScopeOverride:
                                  rootDisplayScopeOverride
                          )
                else {
                    return false
                }
                return migratedIdentities.contains(identity)
            }
            return migrated
        }

        let migrated = ProfileStoreDocument(
            revision: document.revision + 1,
            activeProfileID: document.activeProfileID,
            profiles: migratedProfiles,
            spaceAssignments: mergedAssignments
        )
        try validateDocument(migrated)
        return migrated
    }

    private static func makeLegacyCandidate(
        preferences: DockyPreferences,
        defaults: UserDefaults,
        decoder: JSONDecoder,
        rootDisplayScopeOverride: String?
    ) -> LegacyCandidate {
        let topLevelProfile = DockProfile(
            name: "Default",
            symbolName: "house.fill",
            pinnedItems: preferences.pinnedItems,
            trailingItems: preferences.trailingItems,
            widgetPlacements: preferences.widgetPlacements,
            appWidgetDisplays: preferences.appWidgetDisplays,
            hiddenAppBundleIdentifiers: preferences.hiddenAppBundleIdentifiers
        )
        let topLevelDocument = ProfileStoreDocument(
            revision: 1,
            activeProfileID: topLevelProfile.id,
            profiles: [topLevelProfile]
        )

        if let fullSnapshotObject = defaults.object(
            forKey: LegacyKeys.fullDocument
        ) {
            guard let fullSnapshotData =
                    fullSnapshotObject as? Data
            else {
                return LegacyCandidate(
                    document: topLevelDocument,
                    source:
                        "topLevelPreferencesAfterFullSnapshotFailure",
                    storedActiveWasValid: false,
                    failure:
                        ProfileStoreValidationError
                        .legacySnapshotDecodeFailed([
                            LegacyKeys.fullDocument,
                        ])
                )
            }
            do {
                let document =
                    try ProfileStoreRecoverySnapshotCodec.decode(
                        fullSnapshotData,
                        as: DockProfile.self
                    )
                try Self.validateDocument(document)
                return LegacyCandidate(
                    document: document,
                    source: "fullDocumentSnapshot",
                    storedActiveWasValid: true,
                    failure: nil
                )
            } catch {
                return LegacyCandidate(
                    document: topLevelDocument,
                    source:
                        "topLevelPreferencesAfterFullSnapshotFailure",
                    storedActiveWasValid: false,
                    failure: error
                )
            }
        }

        guard let legacyData = defaults.data(forKey: LegacyKeys.profiles) else {
            var failures = preferences.legacyProfileSnapshotDecodeFailures
            if defaults.object(forKey: LegacyKeys.profiles) != nil {
                failures.append(LegacyKeys.profiles)
            }
            return LegacyCandidate(
                document: topLevelDocument,
                source: "topLevelPreferences",
                storedActiveWasValid: true,
                failure: failures.isEmpty
                    ? nil
                    : ProfileStoreValidationError.legacySnapshotDecodeFailed(failures)
            )
        }

        do {
            let legacyProfiles = try decoder.decode([DockProfile].self, from: legacyData)
            let selection = try LegacyProfileMigration
                .reconcileActiveProfile(
                    profiles: legacyProfiles,
                    storedActiveProfileID: defaults.string(
                        forKey: LegacyKeys.activeProfileID
                    )
                )
            let legacyDocument = ProfileStoreDocument(
                schemaVersion: 1,
                revision: 1,
                activeProfileID: selection.activeProfileID,
                profiles: legacyProfiles
            )
            try Self.validateDocumentForLoad(legacyDocument)
            // Keep UserDefaults-only recovery on the exact same fail-closed
            // path as a schema-1 profile document: UUID identities migrate,
            // numeric IDs and cross-profile conflicts remain inert repair rows.
            let document = try Self.migrateSchema1Document(
                legacyDocument,
                rootDisplayScopeOverride: rootDisplayScopeOverride
            )
            return LegacyCandidate(
                document: document,
                source: "legacyProfiles",
                storedActiveWasValid: selection.storedActiveWasValid,
                failure: nil
            )
        } catch {
            return LegacyCandidate(
                document: topLevelDocument,
                source: "topLevelPreferencesAfterLegacyFailure",
                storedActiveWasValid: false,
                failure: error
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }
}
