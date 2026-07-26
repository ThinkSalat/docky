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

struct ProfileStoreDocument: Codable, Equatable {
    nonisolated static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: UInt64
    let activeProfileID: String
    let profiles: [DockProfile]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: UInt64,
        activeProfileID: String,
        profiles: [DockProfile]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)

        // Decode the version before any version-specific payload. An older
        // Docky build must never mistake a newer document for corruption and
        // replace it with an older backup.
        if schemaVersion > Self.currentSchemaVersion {
            throw ProfileStoreValidationError.unsupportedSchemaVersion(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }

        self.schemaVersion = schemaVersion
        revision = try container.decode(UInt64.self, forKey: .revision)
        activeProfileID = try container.decode(String.self, forKey: .activeProfileID)
        profiles = try container.decode([DockProfile].self, forKey: .profiles)
    }

    nonisolated static func validate(_ document: Self) throws {
        guard document.schemaVersion == currentSchemaVersion else {
            throw ProfileStoreValidationError.unsupportedSchemaVersion(
                found: document.schemaVersion,
                supported: currentSchemaVersion
            )
        }
        guard document.revision > 0 else {
            throw ProfileStoreValidationError.invalidRevision
        }
        guard !document.profiles.isEmpty else {
            throw ProfileStoreValidationError.emptyProfiles
        }

        var profileIDs = Set<String>()
        for (index, profile) in document.profiles.enumerated() {
            guard !profile.id.isEmpty else {
                throw ProfileStoreValidationError.emptyProfileID(index: index)
            }
            guard profileIDs.insert(profile.id).inserted else {
                throw ProfileStoreValidationError.duplicateProfileID(profile.id)
            }
        }

        guard profileIDs.contains(document.activeProfileID) else {
            throw ProfileStoreValidationError.activeProfileMissing(document.activeProfileID)
        }
    }
}

enum ProfileStoreValidationError: Error, LocalizedError {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case invalidRevision
    case emptyProfiles
    case emptyProfileID(index: Int)
    case duplicateProfileID(String)
    case activeProfileMissing(String)
    case revisionExhausted
    case legacySnapshotDecodeFailed([String])

    var isForwardIncompatible: Bool {
        if case .unsupportedSchemaVersion(let found, let supported) = self {
            return found > supported
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "Profile schema \(found) is unsupported by schema \(supported)."
        case .invalidRevision:
            return "The profile document revision must be greater than zero."
        case .emptyProfiles:
            return "The profile document contains no profiles."
        case .emptyProfileID(let index):
            return "Profile \(index) has an empty identifier."
        case .duplicateProfileID:
            return "The profile document contains duplicate profile identifiers."
        case .activeProfileMissing:
            return "The active profile identifier is not present in the profile list."
        case .revisionExhausted:
            return "The profile document revision cannot be incremented."
        case .legacySnapshotDecodeFailed(let keys):
            return "Legacy profile-backed preferences could not be decoded for: \(keys.joined(separator: ", "))."
        }
    }
}

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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let store: AtomicJSONFileStore<ProfileStoreDocument>
    private var revision: UInt64
    private var didCompleteBootstrap = false

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
                validate: ProfileStoreDocument.validate,
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
            } else if let legacyFailure = legacy.failure {
                blocked = true
                persistenceError = Self.describe(legacyFailure)
            } else {
                encodedBytes = try store.save(
                    legacy.document,
                    validate: ProfileStoreDocument.validate
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
                "error": persistenceError,
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

        if !persistenceIsBlocked, let profile = activeProfile {
            preferences?.applyProfile(profile)
        } else if persistenceIsBlocked {
            DiagnosticsTrace.shared.record(.profiles, "profileBootstrapApplySkipped", fields: [
                "reason": "persistenceBlocked",
                "activeProfileToken": DiagnosticsTrace.shared.token(activeProfileID),
                "error": lastPersistenceError ?? "unknown",
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
                "error": lastPersistenceError ?? "unknown",
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
                "error": lastPersistenceError ?? "unknown",
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

    /// Apply a mutation to the authoritative active profile. The new document
    /// reaches durable storage before observers see the updated profile.
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
            let encodedBytes = try store.save(
                document,
                validate: ProfileStoreDocument.validate
            )

            profiles = candidateProfiles
            activeProfileID = candidateActiveProfileID
            revision = document.revision
            lastPersistenceError = nil
            persistLegacyCompatibilitySnapshot()

            diagnostics.record(.profiles, "profilesPersisted", fields: [
                "reason": reason,
                "profileCount": profiles.count,
                "activeProfileToken": diagnostics.token(activeProfileID),
                "schemaVersion": document.schemaVersion,
                "revision": revision,
                "encodedBytes": encodedBytes,
            ])
            return true
        } catch {
            lastPersistenceError = Self.describe(error)
            diagnostics.record(.profiles, "profilesPersistFailed", fields: [
                "reason": reason,
                "profileCount": candidateProfiles.count,
                "activeProfileToken": diagnostics.token(candidateActiveProfileID),
                "revision": document.revision,
                "error": lastPersistenceError ?? "unknown",
            ])
            return false
        }
    }

    private func persistLegacyCompatibilitySnapshot() {
        do {
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: LegacyKeys.profiles)
            defaults.set(activeProfileID, forKey: LegacyKeys.activeProfileID)
        } catch {
            DiagnosticsTrace.shared.record(.profiles, "legacyProfileSnapshotPersistFailed", fields: [
                "profileCount": profiles.count,
                "activeProfileToken": DiagnosticsTrace.shared.token(activeProfileID),
                "revision": revision,
                "error": Self.describe(error),
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
            "error": error ?? "none",
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
        let directory = applicationSupport
            .appendingPathComponent("Docky", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
        return AtomicJSONFileStore(
            primaryURL: directory.appendingPathComponent("profiles.json"),
            backupURL: directory.appendingPathComponent("profiles.backup.json"),
            fileManager: fileManager
        )
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
            guard !legacyProfiles.isEmpty else {
                throw ProfileStoreValidationError.emptyProfiles
            }
            let storedActive = defaults.string(forKey: LegacyKeys.activeProfileID) ?? ""
            let storedActiveWasValid = legacyProfiles.contains { $0.id == storedActive }
            let reconciledActiveID = storedActiveWasValid
                ? storedActive
                : legacyProfiles[0].id
            let document = ProfileStoreDocument(
                revision: 1,
                activeProfileID: reconciledActiveID,
                profiles: legacyProfiles
            )
            try ProfileStoreDocument.validate(document)
            return LegacyCandidate(
                document: document,
                source: "legacyProfiles",
                storedActiveWasValid: storedActiveWasValid,
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
