//
//  ExternalWidgetRuntimePolicy.swift
//  Docky
//
//  Pure, hostless-testable policy for the legacy executable-widget surface.
//

import Foundation

nonisolated enum ExternalWidgetRuntimePolicy {
    /// The legacy ABI executes plugin code in Docky's unsandboxed process.
    /// Keep both capabilities fail-closed until an isolated v2 exists.
    static let allowsInstallation = false
    static let allowsExecution = false
    static let allowsRemoval = false

    static func acceptsInstallDeepLink(host: String) -> Bool {
        false
    }

    static func mayRemoveBundle(
        candidate: URL,
        widgetsDirectory: URL,
        isSymbolicLink: Bool
    ) -> Bool {
        guard allowsRemoval else { return false }
        guard !isSymbolicLink else { return false }

        let standardizedCandidate = candidate.standardizedFileURL
        let standardizedDirectory = widgetsDirectory.standardizedFileURL
        return standardizedCandidate.deletingLastPathComponent()
                == standardizedDirectory
            && standardizedCandidate.pathExtension.caseInsensitiveCompare(
                "dockywidget"
            ) == .orderedSame
    }

    /// Creates and validates Docky's inventory directory without following a
    /// user-created symlink in either the `Docky` or `Widgets` path component.
    /// The Application Support URL itself is a system-provided trust anchor.
    static func prepareWidgetsDirectory(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default,
        createIfMissing: Bool
    ) throws -> URL {
        let applicationSupport =
            applicationSupportDirectory.standardizedFileURL
        let dockyDirectory = applicationSupport.appendingPathComponent(
            "Docky",
            isDirectory: true
        )
        let widgetsDirectory = dockyDirectory.appendingPathComponent(
            "Widgets",
            isDirectory: true
        )

        for directory in [dockyDirectory, widgetsDirectory] {
            try validateDirectoryComponent(
                directory,
                fileManager: fileManager,
                createIfMissing: createIfMissing
            )
        }

        let resolvedApplicationSupport =
            applicationSupport.resolvingSymlinksInPath().standardizedFileURL
        let expectedResolvedDirectory = resolvedApplicationSupport
            .appendingPathComponent("Docky", isDirectory: true)
            .appendingPathComponent("Widgets", isDirectory: true)
            .standardizedFileURL
        guard
            widgetsDirectory.resolvingSymlinksInPath().standardizedFileURL
                == expectedResolvedDirectory
        else {
            throw ExternalWidgetDirectoryPolicyError.symbolicLink
        }

        if createIfMissing {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: widgetsDirectory.path
            )
        }
        return widgetsDirectory
    }

    private static func validateDirectoryComponent(
        _ directory: URL,
        fileManager: FileManager,
        createIfMissing: Bool
    ) throws {
        if let attributes = try? fileManager.attributesOfItem(
            atPath: directory.path
        ), let type = attributes[.type] as? FileAttributeType {
            guard type != .typeSymbolicLink else {
                throw ExternalWidgetDirectoryPolicyError.symbolicLink
            }
            guard type == .typeDirectory else {
                throw ExternalWidgetDirectoryPolicyError.notDirectory
            }
            return
        }

        guard createIfMissing else {
            throw ExternalWidgetDirectoryPolicyError.missing
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ExternalWidgetDirectoryPolicyError.couldNotCreate
        }

        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: directory.path
            ),
            attributes[.type] as? FileAttributeType == .typeDirectory
        else {
            throw ExternalWidgetDirectoryPolicyError.notDirectory
        }
    }
}

nonisolated enum ExternalWidgetDirectoryPolicyError: Error, Equatable {
    case missing
    case notDirectory
    case symbolicLink
    case couldNotCreate
}
