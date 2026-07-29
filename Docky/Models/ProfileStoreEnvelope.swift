//
//  ProfileStoreEnvelope.swift
//  Docky
//
//  Hostless, versioned profile persistence rules. Keeping schema validation
//  and legacy active-profile reconciliation independent from ProfileService
//  makes the failure-sensitive parts directly testable without constructing
//  AppKit or UserDefaults-backed application state.
//

import Foundation

/// Side effects authorized by one explicit manual profile selection.
///
/// Re-selecting the already-visible durable profile is intentionally not a
/// no-op: the user intent must still reach runtime policy so it can reassert a
/// manual override for the current Space residency. Persistence and layout
/// application remain independently idempotent.
nonisolated struct ManualActivationDisposition:
    Equatable,
    Sendable {
    let shouldEmitIntentNotification: Bool
    let shouldPersistDefault: Bool
    let shouldApplyLayout: Bool

    var isVisuallyAndDurablyIdempotent: Bool {
        !shouldPersistDefault && !shouldApplyLayout
    }
}

nonisolated enum ManualActivationDispositionPolicy {
    static func resolve(
        runtimeAlreadyActive: Bool,
        durableAlreadySelected: Bool
    ) -> ManualActivationDisposition {
        ManualActivationDisposition(
            // Every successful explicit manual selection is runtime intent,
            // including repeated selection of the same profile.
            shouldEmitIntentNotification: true,
            shouldPersistDefault: !durableAlreadySelected,
            shouldApplyLayout: !runtimeAlreadyActive
        )
    }
}

nonisolated struct ProfileStoreEnvelope<
    Profile: Codable & Equatable & Identifiable
>: Codable, Equatable where Profile.ID == String {
    static var currentSchemaVersion: Int { 2 }
    static var oldestMigratableSchemaVersion: Int { 1 }
    static var maximumProfileCount: Int { 128 }
    static var maximumSpaceAssignmentCount: Int { 512 }
    static var maximumIdentifierBytes: Int { 1_024 }

    let schemaVersion: Int
    let revision: UInt64
    let activeProfileID: String
    let profiles: [Profile]
    let spaceAssignments: [SpaceProfileAssignment]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: UInt64,
        activeProfileID: String,
        profiles: [Profile],
        spaceAssignments: [SpaceProfileAssignment] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.spaceAssignments = spaceAssignments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )

        // Refuse a future schema before decoding its version-specific payload.
        // An older build must not misclassify a newer document as corruption
        // and replace it with an older backup.
        if schemaVersion > Self.currentSchemaVersion {
            throw ProfileStoreValidationError.unsupportedSchemaVersion(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }

        self.schemaVersion = schemaVersion
        revision = try container.decode(UInt64.self, forKey: .revision)
        activeProfileID = try container.decode(
            String.self,
            forKey: .activeProfileID
        )
        profiles = try container.decode([Profile].self, forKey: .profiles)
        if schemaVersion == 1 {
            // Schema 1 predates the global assignment table.
            spaceAssignments = try container.decodeIfPresent(
                [SpaceProfileAssignment].self,
                forKey: .spaceAssignments
            ) ?? []
        } else {
            // In schema 2 the field is part of the authoritative document.
            // Treat omission as corruption instead of silently erasing every
            // exact-Space assignment.
            spaceAssignments = try container.decode(
                [SpaceProfileAssignment].self,
                forKey: .spaceAssignments
            )
        }
    }

    static func validate(_ document: Self) throws {
        guard document.schemaVersion == currentSchemaVersion else {
            throw ProfileStoreValidationError.unsupportedSchemaVersion(
                found: document.schemaVersion,
                supported: currentSchemaVersion
            )
        }
        try validateCommon(document)
    }

    /// Validation used only at the read boundary. Schema 1 is accepted so the
    /// caller can perform one explicit migration; all writes use `validate`.
    static func validateForLoad(_ document: Self) throws {
        guard document.schemaVersion >= oldestMigratableSchemaVersion,
              document.schemaVersion <= currentSchemaVersion else {
            throw ProfileStoreValidationError.unsupportedSchemaVersion(
                found: document.schemaVersion,
                supported: currentSchemaVersion
            )
        }
        try validateCommon(document)
    }

    private static func validateCommon(_ document: Self) throws {
        guard document.revision > 0 else {
            throw ProfileStoreValidationError.invalidRevision
        }
        guard !document.profiles.isEmpty else {
            throw ProfileStoreValidationError.emptyProfiles
        }
        guard document.profiles.count <= maximumProfileCount else {
            throw ProfileStoreValidationError.limitExceeded(
                field: "profiles",
                maximum: maximumProfileCount
            )
        }
        guard document.activeProfileID.utf8.count
                <= maximumIdentifierBytes
        else {
            throw ProfileStoreValidationError.limitExceeded(
                field: "activeProfileIDBytes",
                maximum: maximumIdentifierBytes
            )
        }

        var profileIDs = Set<String>()
        for (index, profile) in document.profiles.enumerated() {
            guard !profile.id.isEmpty else {
                throw ProfileStoreValidationError.emptyProfileID(index: index)
            }
            guard profile.id.utf8.count <= maximumIdentifierBytes else {
                throw ProfileStoreValidationError.limitExceeded(
                    field: "profileIDBytes",
                    maximum: maximumIdentifierBytes
                )
            }
            guard profileIDs.insert(profile.id).inserted else {
                throw ProfileStoreValidationError.duplicateProfileID(
                    profile.id
                )
            }
        }

        guard profileIDs.contains(document.activeProfileID) else {
            throw ProfileStoreValidationError.activeProfileMissing(
                document.activeProfileID
            )
        }

        guard document.spaceAssignments.count
                <= maximumSpaceAssignmentCount
        else {
            throw ProfileStoreValidationError.limitExceeded(
                field: "spaceAssignments",
                maximum: maximumSpaceAssignmentCount
            )
        }

        var assignedSpaces = Set<MissionControlSpaceIdentity>()
        for assignment in document.spaceAssignments {
            guard assignedSpaces.insert(assignment.identity).inserted else {
                throw ProfileStoreValidationError.duplicateSpaceAssignment(
                    assignment.identity.storageKey
                )
            }
            guard profileIDs.contains(assignment.profileID) else {
                throw ProfileStoreValidationError
                    .spaceAssignmentProfileMissing(assignment.profileID)
            }
            guard assignment.profileID.utf8.count
                    <= maximumIdentifierBytes
            else {
                throw ProfileStoreValidationError.limitExceeded(
                    field: "spaceAssignmentProfileIDBytes",
                    maximum: maximumIdentifierBytes
                )
            }
            guard assignment.identity.spaceUUID.utf8.count
                    <= maximumIdentifierBytes,
                  (assignment.identity.rootDisplayScope?.utf8.count ?? 0)
                    <= maximumIdentifierBytes
            else {
                throw ProfileStoreValidationError.limitExceeded(
                    field: "spaceIdentityBytes",
                    maximum: maximumIdentifierBytes
                )
            }
        }
    }
}

/// Profile-owned identity metadata validated before any document is accepted.
/// Keeping this pure makes display labels and trigger-row identity safe to test
/// without constructing ProfileService or UserDefaults.
nonisolated struct ProfileStoreProfileMetadata: Equatable, Sendable {
    let profileID: String
    let name: String
    let triggerIDs: [String]
}

nonisolated enum ProfileStoreProfileMetadataPolicy {
    private static let comparisonLocale =
        Locale(identifier: "en_US_POSIX")

    static func validate(
        _ profiles: [ProfileStoreProfileMetadata]
    ) throws {
        var names = Set<String>()
        var triggerIDs = Set<String>()

        for profile in profiles {
            let trimmedName = profile.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedName.isEmpty else {
                throw ProfileStoreValidationError.emptyProfileName(
                    profile.profileID
                )
            }
            guard trimmedName == profile.name else {
                throw ProfileStoreValidationError
                    .profileNameNotTrimmed(profile.profileID)
            }

            let comparisonKey = trimmedName.folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                ],
                locale: comparisonLocale
            )
            guard names.insert(comparisonKey).inserted else {
                throw ProfileStoreValidationError.duplicateProfileName(
                    trimmedName
                )
            }

            for triggerID in profile.triggerIDs {
                guard !triggerID.isEmpty else {
                    throw ProfileStoreValidationError.emptyTriggerID(
                        profile.profileID
                    )
                }
                guard triggerIDs.insert(triggerID).inserted else {
                    throw ProfileStoreValidationError.duplicateTriggerID(
                        triggerID
                    )
                }
            }
        }
    }
}

/// A complete schema-versioned recovery snapshot. UserDefaults stores this
/// payload as one Data value; unlike the older profiles-only compatibility
/// keys, it retains exact-Space assignments and the document revision.
nonisolated enum ProfileStoreRecoverySnapshotCodec {
    static func encode<Profile>(
        _ document: ProfileStoreEnvelope<Profile>
    ) throws -> Data
    where Profile: Codable & Equatable & Identifiable,
          Profile.ID == String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    static func decode<Profile>(
        _ data: Data,
        as profileType: Profile.Type
    ) throws -> ProfileStoreEnvelope<Profile>
    where Profile: Codable & Equatable & Identifiable,
          Profile.ID == String {
        _ = profileType
        return try JSONDecoder().decode(
            ProfileStoreEnvelope<Profile>.self,
            from: data
        )
    }
}

nonisolated protocol ProfileStoreLegacyExactSpaceRepairable:
    Codable,
    Equatable,
    Identifiable
where ID == String {
    var triggers: [ProfileTrigger] { get set }
}

/// Pure candidate construction for the mutations that previously mixed
/// Space ownership with profile state. Production uses this policy before its
/// atomic commit, and host tests can prove every unrelated profile value and
/// assignment is preserved exactly.
nonisolated enum ProfileStoreDocumentMutationPolicy {
    static func assigningSpace<Profile>(
        _ identity: MissionControlSpaceIdentity,
        to profileID: String,
        in document: ProfileStoreEnvelope<Profile>
    ) -> ProfileStoreEnvelope<Profile>?
    where Profile: Codable & Equatable & Identifiable,
          Profile.ID == String {
        guard document.profiles.contains(where: {
            $0.id == profileID
        }) else {
            return nil
        }
        let assignments = SpaceProfileAssignmentPolicy.assigning(
            identity,
            to: profileID,
            in: document.spaceAssignments
        )
        return replacing(
            document,
            spaceAssignments: assignments
        )
    }

    static func removingSpaceAssignment<Profile>(
        _ identity: MissionControlSpaceIdentity,
        from profileID: String,
        in document: ProfileStoreEnvelope<Profile>
    ) -> ProfileStoreEnvelope<Profile>
    where Profile: Codable & Equatable & Identifiable,
          Profile.ID == String {
        replacing(
            document,
            spaceAssignments:
                document.spaceAssignments.filter {
                    !(
                        $0.identity == identity
                        && $0.profileID == profileID
                    )
                }
        )
    }

    static func deletingProfile<Profile>(
        _ profileID: String,
        from document: ProfileStoreEnvelope<Profile>
    ) -> ProfileStoreEnvelope<Profile>?
    where Profile: Codable & Equatable & Identifiable,
          Profile.ID == String {
        guard document.profiles.count > 1,
              document.profiles.contains(where: {
                  $0.id == profileID
              })
        else {
            return nil
        }
        let remainingProfiles = document.profiles.filter {
            $0.id != profileID
        }
        let activeProfileID =
            document.activeProfileID == profileID
            ? remainingProfiles[0].id
            : document.activeProfileID
        return ProfileStoreEnvelope(
            schemaVersion: document.schemaVersion,
            revision: document.revision,
            activeProfileID: activeProfileID,
            profiles: remainingProfiles,
            spaceAssignments:
                document.spaceAssignments.filter {
                    $0.profileID != profileID
                }
        )
    }

    /// Resolves one inert legacy exact-Space row and its global assignment as
    /// one document mutation. Expected-owner comparison prevents a stale
    /// confirmation from moving an assignment that changed during review.
    static func repairingLegacyExactSpaceBinding<Profile>(
        profileID: String,
        triggerID: String,
        assigning identity: MissionControlSpaceIdentity,
        expectedOwnerProfileID: String?,
        in document: ProfileStoreEnvelope<Profile>
    ) -> ProfileStoreEnvelope<Profile>?
    where Profile: ProfileStoreLegacyExactSpaceRepairable {
        let owners = document.spaceAssignments.filter {
            $0.identity == identity
        }
        guard owners.count <= 1,
              owners.first?.profileID == expectedOwnerProfileID
        else {
            return nil
        }

        var matchedLocation: (
            profileIndex: Int,
            triggerIndex: Int,
            exact: ExactSpaceTrigger
        )?
        for (profileIndex, profile) in
            document.profiles.enumerated() {
            for (triggerIndex, trigger) in
                profile.triggers.enumerated()
            where trigger.id == triggerID {
                guard matchedLocation == nil,
                      profile.id == profileID,
                      case .exactSpace(let exact) = trigger
                else {
                    return nil
                }
                matchedLocation = (
                    profileIndex,
                    triggerIndex,
                    exact
                )
            }
        }

        guard let matchedLocation,
              matchedLocation.exact.identity != nil
                || matchedLocation.exact.spaceID != nil
        else {
            return nil
        }
        if let savedIdentity = matchedLocation.exact.identity,
           savedIdentity != identity {
            return nil
        }

        var profiles = document.profiles
        profiles[matchedLocation.profileIndex].triggers.remove(
            at: matchedLocation.triggerIndex
        )
        let assignments = SpaceProfileAssignmentPolicy.assigning(
            identity,
            to: profileID,
            in: document.spaceAssignments
        )
        return ProfileStoreEnvelope(
            schemaVersion: document.schemaVersion,
            revision: document.revision,
            activeProfileID: document.activeProfileID,
            profiles: profiles,
            spaceAssignments: assignments
        )
    }

    /// Runtime fallback follows the document's durable/default selection, not
    /// profile-array order, when the visible profile is deleted.
    static func runtimeProfileIDAfterDeleting<Profile>(
        _ deletedProfileID: String,
        previousRuntimeProfileID: String,
        from candidateDocument: ProfileStoreEnvelope<Profile>
    ) -> String?
    where Profile: Codable & Equatable & Identifiable,
          Profile.ID == String {
        if previousRuntimeProfileID == deletedProfileID {
            return candidateDocument.activeProfileID
        }
        return candidateDocument.profiles.contains {
            $0.id == previousRuntimeProfileID
        }
            ? previousRuntimeProfileID
            : nil
    }

    private static func replacing<Profile>(
        _ document: ProfileStoreEnvelope<Profile>,
        spaceAssignments: [SpaceProfileAssignment]
    ) -> ProfileStoreEnvelope<Profile>
    where Profile: Codable & Equatable & Identifiable,
          Profile.ID == String {
        ProfileStoreEnvelope(
            schemaVersion: document.schemaVersion,
            revision: document.revision,
            activeProfileID: document.activeProfileID,
            profiles: document.profiles,
            spaceAssignments: spaceAssignments
        )
    }
}

nonisolated enum ProfileStoreSchemaMigrationPolicy {
    /// Preserves a schema-1 assignment table and appends only new, compatible
    /// trigger-derived assignments. Conflicting owners abort migration rather
    /// than silently choosing one source or erasing either.
    static func mergingSpaceAssignments(
        existing: [SpaceProfileAssignment],
        migrated: [SpaceProfileAssignment]
    ) throws -> [SpaceProfileAssignment] {
        var merged: [SpaceProfileAssignment] = []
        var owners:
            [MissionControlSpaceIdentity: String] = [:]

        for assignment in existing + migrated {
            if let owner = owners[assignment.identity] {
                guard owner == assignment.profileID else {
                    throw ProfileStoreValidationError
                        .conflictingSpaceAssignmentMigration(
                            assignment.identity.storageKey
                        )
                }
                continue
            }
            owners[assignment.identity] = assignment.profileID
            merged.append(assignment)
        }
        return merged
    }
}

nonisolated struct LegacyProfileActiveSelection: Equatable {
    let activeProfileID: String
    let storedActiveWasValid: Bool
}

nonisolated enum LegacyProfileMigration {
    static func reconcileActiveProfile<
        Profile: Identifiable
    >(
        profiles: [Profile],
        storedActiveProfileID: String?
    ) throws -> LegacyProfileActiveSelection where Profile.ID == String {
        guard let firstProfileID = profiles.first?.id else {
            throw ProfileStoreValidationError.emptyProfiles
        }

        let storedID = storedActiveProfileID ?? ""
        let storedActiveWasValid = profiles.contains {
            $0.id == storedID
        }
        return LegacyProfileActiveSelection(
            activeProfileID: storedActiveWasValid
                ? storedID
                : firstProfileID,
            storedActiveWasValid: storedActiveWasValid
        )
    }
}

nonisolated enum ProfileStoreValidationError:
    Error,
    Equatable,
    LocalizedError {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case invalidRevision
    case emptyProfiles
    case emptyProfileID(index: Int)
    case duplicateProfileID(String)
    case emptyProfileName(String)
    case profileNameNotTrimmed(String)
    case duplicateProfileName(String)
    case emptyTriggerID(String)
    case duplicateTriggerID(String)
    case activeProfileMissing(String)
    case duplicateSpaceAssignment(String)
    case spaceAssignmentProfileMissing(String)
    case conflictingSpaceAssignmentMigration(String)
    case limitExceeded(field: String, maximum: Int)
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
        case .emptyProfileName:
            return "Every profile must have a non-empty name."
        case .profileNameNotTrimmed:
            return "Profile names cannot begin or end with whitespace."
        case .duplicateProfileName:
            return "Profile names must be unique."
        case .emptyTriggerID:
            return "Every profile trigger must have a non-empty identifier."
        case .duplicateTriggerID:
            return "Profile trigger identifiers must be unique."
        case .activeProfileMissing:
            return "The active profile identifier is not present in the profile list."
        case .duplicateSpaceAssignment:
            return "The profile document assigns one Space more than once."
        case .spaceAssignmentProfileMissing:
            return "A Space assignment refers to a missing profile."
        case .conflictingSpaceAssignmentMigration:
            return "Schema migration found conflicting owners for one Space assignment."
        case .limitExceeded(let field, let maximum):
            return "The profile document exceeds the \(field) limit of \(maximum)."
        case .revisionExhausted:
            return "The profile document revision cannot be incremented."
        case .legacySnapshotDecodeFailed(let keys):
            return "Legacy profile-backed preferences could not be decoded for: \(keys.joined(separator: ", "))."
        }
    }
}
