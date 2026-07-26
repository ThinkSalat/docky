import Foundation

/// Identifies the preference slot that owns a pre-managed custom image.
///
/// Associated values are used only to update the exact captured setting after
/// an import succeeds. Diagnostics must use `diagnosticKind`, which never
/// exposes bundle identifiers or user-authored paths.
nonisolated enum LegacyUserAssetTarget: Hashable, Sendable {
    case appIcon(bundleIdentifier: String)
    case trashIcon(state: String)
    case folderIcon(folderPath: String)
    case launchpadIcon
    case startMenuIcon
    case launchpadBackground
    case activeIndicator
    case windowBackground
    case tileActiveBackground
    case tileHoverBackground
    case divider
    case leftDivider
    case rightDivider

    var diagnosticKind: String {
        switch self {
        case .appIcon: "appIcon"
        case .trashIcon: "trashIcon"
        case .folderIcon: "folderIcon"
        case .launchpadIcon: "launchpadIcon"
        case .startMenuIcon: "startMenuIcon"
        case .launchpadBackground: "launchpadBackground"
        case .activeIndicator: "activeIndicator"
        case .windowBackground: "windowBackground"
        case .tileActiveBackground: "tileActiveBackground"
        case .tileHoverBackground: "tileHoverBackground"
        case .divider: "divider"
        case .leftDivider: "leftDivider"
        case .rightDivider: "rightDivider"
        }
    }
}

nonisolated struct LegacyUserAssetReference: Equatable, Sendable {
    let target: LegacyUserAssetTarget
    let sourcePath: String
    let slot: String
}

nonisolated struct LegacyUserAssetCandidate: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let target: LegacyUserAssetTarget
        let sourcePath: String
        let slot: String
    }

    let target: LegacyUserAssetTarget
    let sourcePath: String
    let slot: String

    var id: ID {
        ID(target: target, sourcePath: sourcePath, slot: slot)
    }
}

/// Finds pre-managed paths without asking the file system about those paths.
/// This is safe to run while Settings renders: it performs only lexical URL
/// normalization. Reading a legacy source is reserved for the explicit user
/// recovery action.
nonisolated enum LegacyUserAssetRecoveryPlanner {
    static func candidates(
        from references: [LegacyUserAssetReference],
        managedDirectory: URL
    ) -> [LegacyUserAssetCandidate] {
        references.compactMap { reference in
            guard !reference.sourcePath.isEmpty,
                  (reference.sourcePath as NSString).isAbsolutePath,
                  !isLexicallyManagedDirectChild(
                      path: reference.sourcePath,
                      managedDirectory: managedDirectory
                  ) else {
                return nil
            }
            return LegacyUserAssetCandidate(
                target: reference.target,
                sourcePath: reference.sourcePath,
                slot: reference.slot
            )
        }
    }

    static func isLexicallyManagedDirectChild(
        path: String,
        managedDirectory: URL
    ) -> Bool {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else {
            return false
        }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let root = managedDirectory.standardizedFileURL
        return candidate.deletingLastPathComponent().path == root.path
    }

    static func canReplace(
        currentPath: String?,
        expectedSourcePath: String
    ) -> Bool {
        currentPath == expectedSourcePath
    }
}

nonisolated struct LegacyUserAssetImportResult: Sendable {
    let candidate: LegacyUserAssetCandidate
    let destinationPath: String?
    let errorDomain: String?
    let errorCode: Int?
}

/// Performs only the user-authorized source reads and managed-store writes.
/// No preference objects cross this detached boundary.
nonisolated enum LegacyUserAssetRecoveryWorker {
    static func importCandidates(
        _ candidates: [LegacyUserAssetCandidate],
        into directory: URL = ManagedUserAssetStore.directoryURL
    ) async -> [LegacyUserAssetImportResult] {
        var results: [LegacyUserAssetImportResult] = []
        results.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            let imported = await ManagedUserAssetStore.importAssetOffMain(
                from: URL(fileURLWithPath: candidate.sourcePath),
                slot: candidate.slot,
                into: directory
            )
            results.append(
                LegacyUserAssetImportResult(
                    candidate: candidate,
                    destinationPath: imported.destinationPath,
                    errorDomain: imported.errorDomain,
                    errorCode: imported.errorCode
                )
            )
        }
        return results
    }
}

nonisolated struct LegacyUserAssetRecoverySummary: Equatable, Sendable {
    let attemptedCount: Int
    let recoveredCount: Int
    let failedCount: Int
    let staleCount: Int
}
