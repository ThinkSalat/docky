//
//  ProfileService.swift
//  Docky
//
//  Owns Docky's profile state. Profiles and the active profile identifier
//  are persisted as one versioned document. That document is authoritative;
//  the older UserDefaults keys remain compatibility snapshots only.
//

import Foundation
import Observation

enum ProfileActivationSource: String {
    case manual
    case trigger
    case launchReapply
    case deleteFallback
}

typealias ProfileStoreDocument = ProfileStoreEnvelope<DockProfile>

@Observable
final class ProfileService {
    static var shared: ProfileService {
        ProfileStateBootstrap.shared.profileService
    }

    /// All known profiles, in user-defined order.
    private(set) var profiles: [DockProfile]

    /// Identifier of the currently-active profile.
    private(set) var activeProfileID: String

    /// Set when existing persistence material could not be recovered safely.
    /// In this state Docky preserves the files and rejects profile mutations
    /// instead of overwriting potentially newer or recoverable data.
    private(set) var persistenceIsBlocked: Bool

    /// Most recent persistence failure, retained for diagnostics/UI surfacing.
    private(set) var lastPersistenceError: String?

    var activeProfile: DockProfile? {
        profiles.first(where: { $0.id == activeProfileID })
    }

    private weak var preferences: DockyPreferences?
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let store: AtomicJSONFileStore<ProfileStoreDocument>
    private var revision: UInt64
    private var didCompleteBootstrap = false
    @ObservationIgnored
    private lazy var persistenceCoordinator =
        CoalescingPersistenceCoordinator(
            initialDurableValue: currentDocument,
            persist: { [store] document in
                try store.save(
                    document,
                    validate: Self.validateDocument
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
                let data = try encoder.encode(document.profiles)
                defaults.set(data, forKey: LegacyKeys.profiles)
                defaults.set(
                    document.activeProfileID,
                    forKey: LegacyKeys.activeProfileID
                )
                return data.count
            },
            onEvent: { [weak self] event in
                self?.handleLegacySnapshotEvent(event)
            }
        )

    private enum LegacyKeys {
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

        let legacy = Self.makeLegacyCandidate(
            preferences: preferences,
            defaults: defaults,
            decoder: decoder
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
                validate: Self.validateDocument,
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
            } else if let legacyFailure = legacy.failure {
                blocked = true
                persistenceError = Self.describe(legacyFailure)
            } else {
                encodedBytes = try store.save(
                    legacy.document,
                    validate: Self.validateDocument
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
        guard activeProfileID != id else {
            diagnostics.record(.profiles, "profileActivationSkipped", fields: [
                "reason": "alreadyActive",
                "source": source.rawValue,
                "profileToken": diagnostics.token(id),
            ])
            return true
        }
        guard let profile = profiles.first(where: { $0.id == id }) else {
            diagnostics.record(.profiles, "profileActivationSkipped", fields: [
                "reason": "profileNotFound",
                "source": source.rawValue,
                "profileToken": diagnostics.token(id),
            ])
            return false
        }

        let previousID = activeProfileID
        diagnostics.record(.profiles, "profileActivationBegan", fields: [
            "source": source.rawValue,
            "previousProfileToken": diagnostics.token(previousID),
            "profileToken": diagnostics.token(id),
            "pinnedItemCount": profile.pinnedItems.count,
            "trailingItemCount": profile.trailingItems.count,
            "widgetPlacementCount": profile.widgetPlacements.count,
            "hiddenAppCount": profile.hiddenAppBundleIdentifiers.count,
        ])

        guard commit(profiles: profiles, activeProfileID: id, reason: "activation") else {
            diagnostics.record(.profiles, "profileActivationFailed", fields: [
                "source": source.rawValue,
                "previousProfileToken": diagnostics.token(previousID),
                "profileToken": diagnostics.token(id),
                "error":
                    DiagnosticPrivacy.redactedTextDescriptor(
                        lastPersistenceError
                    ),
            ])
            return false
        }

        preferences?.applyProfile(profile)
        diagnostics.record(.profiles, "profileActivationCompleted", fields: [
            "source": source.rawValue,
            "previousProfileToken": diagnostics.token(previousID),
            "profileToken": diagnostics.token(id),
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
            activeProfileID: activeProfileID,
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

    @discardableResult
    func createProfile(
        name: String,
        symbolName: String = "circle.grid.3x3.fill",
        basedOn: DockProfile? = nil
    ) -> DockProfile? {
        let profile = DockProfile(
            name: name,
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
            activeProfileID: activeProfileID,
            reason: "createProfile"
        ) else {
            return nil
        }
        return profile
    }

    @discardableResult
    func renameProfile(id: String, to newName: String) -> Bool {
        mutateProfile(id: id, reason: "renameProfile") {
            $0.name = newName
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
        guard profiles.count > 1 else { return false }
        guard profiles.contains(where: { $0.id == id }) else { return false }

        let wasActive = activeProfileID == id
        let candidateProfiles = profiles.filter { $0.id != id }
        let candidateActiveID = wasActive
            ? candidateProfiles[0].id
            : activeProfileID

        guard commit(
            profiles: candidateProfiles,
            activeProfileID: candidateActiveID,
            reason: "deleteProfile"
        ) else {
            return false
        }

        if wasActive, let fallback = candidateProfiles.first {
            preferences?.applyProfile(fallback)
            DiagnosticsTrace.shared.record(.profiles, "profileActivationCompleted", fields: [
                "source": ProfileActivationSource.deleteFallback.rawValue,
                "profileToken": DiagnosticsTrace.shared.token(fallback.id),
                "revision": revision,
            ])
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
            activeProfileID: activeProfileID,
            reason: reason
        )
    }

    private func commit(
        profiles candidateProfiles: [DockProfile],
        activeProfileID candidateActiveProfileID: String,
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

        let document = ProfileStoreDocument(
            revision: revision + 1,
            activeProfileID: candidateActiveProfileID,
            profiles: candidateProfiles
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
        activeProfileID = candidateActiveProfileID
        revision = document.revision
        lastPersistenceError = nil

        diagnostics.record(.profiles, "profilePersistenceScheduled", fields: [
            "reason": reason,
            "profileCount": profiles.count,
            "activeProfileToken": diagnostics.token(activeProfileID),
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
            activeProfileID: activeProfileID,
            profiles: profiles
        )
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
            persistenceIsBlocked = true
            lastPersistenceError = errorDescription
            profiles = durableDocument.profiles
            activeProfileID = durableDocument.activeProfileID
            revision = durableDocument.revision
            persistLegacyCompatibilitySnapshot(document: durableDocument)
            if let durableProfile = activeProfile {
                preferences?.applyProfile(durableProfile)
            }

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

    private static func makeLegacyCandidate(
        preferences: DockyPreferences,
        defaults: UserDefaults,
        decoder: JSONDecoder
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
            let document = ProfileStoreDocument(
                revision: 1,
                activeProfileID: selection.activeProfileID,
                profiles: legacyProfiles
            )
            try Self.validateDocument(document)
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
