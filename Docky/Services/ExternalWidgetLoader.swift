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

    /// Runtime recursive deletion remains fail-closed until it can use an
    /// fd-relative tree walker. Reveal the inert bundle so the user can
    /// inspect or remove it explicitly in Finder.
    func uninstallBundle(at url: URL) throws {
        DiagnosticsTrace.shared.record(
            .widgets,
            "bundleRemovalRejected",
            fields: ["reason": "runtimeMutationDisabled"]
        )
        throw ExternalWidgetStorageError.mutationDisabled
    }

    func validatedWidgetsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")

        return try ExternalWidgetRuntimePolicy.prepareWidgetsDirectory(
            applicationSupportDirectory: appSupport,
            createIfMissing: false
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
    case mutationDisabled
    case outsideWidgetsDirectory
    case unsafePath
    case unsafeDirectory

    var errorDescription: String? {
        switch self {
        case .mutationDisabled:
            "Docky leaves inactive widget bundles untouched. Reveal the bundle and remove it explicitly in Finder."
        case .outsideWidgetsDirectory:
            "Docky refused to remove a file outside its Widgets folder."
        case .unsafePath:
            "Docky refused to remove an unsafe widget-bundle path."
        case .unsafeDirectory:
            "Docky's Widgets folder is missing or has an unsafe path."
        }
    }
}
