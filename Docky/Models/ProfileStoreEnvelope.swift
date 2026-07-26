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

nonisolated struct ProfileStoreEnvelope<
    Profile: Codable & Equatable & Identifiable
>: Codable, Equatable where Profile.ID == String {
    static var currentSchemaVersion: Int { 1 }
    static var maximumProfileCount: Int { 128 }
    static var maximumIdentifierBytes: Int { 1_024 }

    let schemaVersion: Int
    let revision: UInt64
    let activeProfileID: String
    let profiles: [Profile]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: UInt64,
        activeProfileID: String,
        profiles: [Profile]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.activeProfileID = activeProfileID
        self.profiles = profiles
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
    }

    static func validate(_ document: Self) throws {
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
    case activeProfileMissing(String)
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
        case .activeProfileMissing:
            return "The active profile identifier is not present in the profile list."
        case .limitExceeded(let field, let maximum):
            return "The profile document exceeds the \(field) limit of \(maximum)."
        case .revisionExhausted:
            return "The profile document revision cannot be incremented."
        case .legacySnapshotDecodeFailed(let keys):
            return "Legacy profile-backed preferences could not be decoded for: \(keys.joined(separator: ", "))."
        }
    }
}
