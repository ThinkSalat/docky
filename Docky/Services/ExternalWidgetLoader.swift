//
//  ExternalWidgetLoader.swift
//  Docky
//
//  Inventory and removal support for legacy third-party widget bundles.
//
//  External bundles are deliberately inert. Loading executable code from a
//  user-writable directory in Docky's process required disabling hardened
//  runtime protections and gave that code all of Docky's permissions. A
//  future extension system must validate a trusted manifest and notarized
//  signature, retain quarantine, and execute the extension out of process.
//

import Foundation
import os.log

@MainActor
final class ExternalWidgetLoader {
    static let shared = ExternalWidgetLoader()

    private let log = Logger(
        subsystem: "gt.quintero.Docky",
        category: "ExternalWidgetLoader"
    )
    static let bundleExtension = "dockywidget"

    private init() {}

    /// Lists direct `*.dockywidget` children without parsing their metadata
    /// or loading executable code.
    func installedBundleURLs() -> [URL] {
        let directory: URL
        do {
            directory = try validatedWidgetsDirectory()
        } catch {
            recordDirectoryRejection()
            return []
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter {
                $0.pathExtension.caseInsensitiveCompare(Self.bundleExtension)
                    == .orderedSame
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }
    }

    /// Removes one direct child of Docky's Widgets directory. Rejecting
    /// arbitrary paths keeps this destructive operation scoped to the item
    /// selected from `installedBundleURLs()`.
    func uninstallBundle(at url: URL) throws {
        let candidate = url.standardizedFileURL
        let directory: URL
        do {
            directory = try validatedWidgetsDirectory()
        } catch {
            recordDirectoryRejection()
            throw ExternalWidgetStorageError.unsafeDirectory
        }
        let candidateParent = candidate.deletingLastPathComponent()

        guard
            candidateParent == directory,
            candidate.pathExtension.caseInsensitiveCompare(
                Self.bundleExtension
            ) == .orderedSame
        else {
            DiagnosticsTrace.shared.record(
                .widgets,
                "bundleRemovalRejected",
                fields: ["reason": "outsideWidgetsDirectory"]
            )
            throw ExternalWidgetStorageError.outsideWidgetsDirectory
        }

        let values = try candidate.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard ExternalWidgetRuntimePolicy.mayRemoveBundle(
            candidate: candidate,
            widgetsDirectory: directory,
            isSymbolicLink: values.isSymbolicLink == true
        ) else {
            DiagnosticsTrace.shared.record(
                .widgets,
                "bundleRemovalRejected",
                fields: ["reason": "unsafePath"]
            )
            throw ExternalWidgetStorageError.unsafePath
        }

        try FileManager.default.removeItem(at: candidate)
        DiagnosticsTrace.shared.record(
            .widgets,
            "bundleRemoved"
        )
        log.info(
            "Removed inert external widget bundle \(candidate.lastPathComponent, privacy: .private)"
        )
    }

    func validatedWidgetsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")

        return try ExternalWidgetRuntimePolicy.prepareWidgetsDirectory(
            applicationSupportDirectory: appSupport,
            createIfMissing: true
        )
    }

    private func recordDirectoryRejection() {
        DiagnosticsTrace.shared.record(
            .widgets,
            "inventoryDirectoryRejected",
            fields: ["reason": "unsafePath"]
        )
        log.error("Rejected unsafe external widget inventory directory")
    }
}

enum ExternalWidgetStorageError: LocalizedError {
    case outsideWidgetsDirectory
    case unsafePath
    case unsafeDirectory

    var errorDescription: String? {
        switch self {
        case .outsideWidgetsDirectory:
            "Docky refused to remove a file outside its Widgets folder."
        case .unsafePath:
            "Docky refused to remove an unsafe widget-bundle path."
        case .unsafeDirectory:
            "Docky's Widgets folder is missing or has an unsafe path."
        }
    }
}
