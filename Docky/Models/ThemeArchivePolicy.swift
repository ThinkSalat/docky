//
//  ThemeArchivePolicy.swift
//  Docky
//
//  Pure validation rules for data-only `.dockytheme` archives and bundles.
//  The policy is deliberately independent of AppKit and ThemeManager so the
//  filesystem boundary can be exercised by hostless unit tests.
//

import Foundation

/// Runtime theme mutations remain fail-closed until Docky can perform every
/// tree operation through retained, descriptor-relative storage.
nonisolated enum ThemeRuntimeMutation: String, CaseIterable, Sendable {
    case importTheme
    case exportTheme
    case deleteTheme

    var displayName: String {
        switch self {
        case .importTheme:
            return "Theme import"
        case .exportTheme:
            return "Theme export"
        case .deleteTheme:
            return "Theme deletion"
        }
    }
}

nonisolated enum ThemeRuntimeMutationError: LocalizedError, Equatable {
    case disabled(ThemeRuntimeMutation)

    var errorDescription: String? {
        switch self {
        case .disabled(let operation):
            return "\(operation.displayName) is temporarily unavailable " +
                "while Docky’s theme storage is being secured. Existing " +
                "validated themes can still be activated, revealed, and " +
                "refreshed."
        }
    }
}

nonisolated enum ThemeRuntimeMutationPolicy {
    static let unavailableExplanation =
        "Theme import, export, and deletion are temporarily unavailable " +
        "while Docky’s theme storage is being secured. Existing validated " +
        "themes can still be activated, revealed, and refreshed."

    static func isAllowed(_: ThemeRuntimeMutation) -> Bool {
        return false
    }

    static func reject(
        _ operation: ThemeRuntimeMutation
    ) throws -> Never {
        throw ThemeRuntimeMutationError.disabled(operation)
    }
}

nonisolated struct ThemeArchiveLimits: Equatable, Sendable {
    let maximumArchiveBytes: Int64
    let maximumListingBytes: Int
    let maximumEntryCount: Int
    let maximumExpandedBytes: Int64
    let maximumManifestBytes: Int64

    static let standard = ThemeArchiveLimits(
        maximumArchiveBytes: 512 * 1_024 * 1_024,
        maximumListingBytes: 8 * 1_024 * 1_024,
        maximumEntryCount: 10_000,
        maximumExpandedBytes: 512 * 1_024 * 1_024,
        maximumManifestBytes: 1 * 1_024 * 1_024
    )
}

nonisolated enum ThemeArchivePolicyError: LocalizedError, Equatable {
    case archiveIsNotRegularFile
    case archiveTooLarge
    case invalidArchiveListing
    case tooManyEntries
    case unsafeArchivePath(String)
    case unsafeFilesystemObject(String)
    case expandedContentTooLarge
    case unsafeBundleRoot
    case missingManifest
    case manifestTooLarge

    var errorDescription: String? {
        switch self {
        case .archiveIsNotRegularFile:
            return "The selected theme archive is not a regular file."
        case .archiveTooLarge:
            return "The selected theme archive is larger than the supported limit."
        case .invalidArchiveListing:
            return "The theme archive contains an invalid or unreadable file list."
        case .tooManyEntries:
            return "The theme archive contains too many files."
        case .unsafeArchivePath(let path):
            return "The theme archive contains an unsafe path: \(path)."
        case .unsafeFilesystemObject(let path):
            return "The theme contains an unsafe filesystem object: \(path)."
        case .expandedContentTooLarge:
            return "The expanded theme is larger than the supported limit."
        case .unsafeBundleRoot:
            return "The theme bundle directory is not safe to use."
        case .missingManifest:
            return "The theme bundle does not contain a safe theme.json manifest."
        case .manifestTooLarge:
            return "The theme manifest is larger than the supported limit."
        }
    }
}

nonisolated enum ThemeArchivePolicy {
    static func isValidThemeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.hasPrefix(".") else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func slugifyThemeID(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9") {
                result.append(Character(scalar))
                lastWasDash = false
            } else if scalar == "_" || scalar == "." || scalar == "-" {
                result.append(Character(scalar))
                lastWasDash = scalar == "-"
            } else if scalar == " " || scalar == "\t" {
                if !lastWasDash {
                    result.append("-")
                    lastWasDash = true
                }
            }
        }
        let trimmed = result.trimmingCharacters(
            in: CharacterSet(charactersIn: "-._")
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses `unzip -Z1` output and validates every member before extraction.
    /// Newlines, carriage returns, backslashes, absolute paths, drive-letter
    /// paths, and dot components are rejected so the listing is unambiguous
    /// and portable across ZIP extractors.
    static func validatedArchiveEntries(
        from listingData: Data,
        limits: ThemeArchiveLimits = .standard
    ) throws -> [String] {
        guard listingData.count <= limits.maximumListingBytes,
              let listing = String(data: listingData, encoding: .utf8) else {
            throw ThemeArchivePolicyError.invalidArchiveListing
        }

        var lines = listing.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            throw ThemeArchivePolicyError.invalidArchiveListing
        }
        guard lines.count <= limits.maximumEntryCount else {
            throw ThemeArchivePolicyError.tooManyEntries
        }

        var collisionKeys = Set<String>()
        var nonDirectoryKeys = Set<String>()
        var normalizedEntries: [String] = []
        for line in lines {
            try validateArchiveEntryPath(line)
            let path = line.hasSuffix("/")
                ? String(line.dropLast())
                : line
            let key = filesystemCollisionKey(path)
            guard collisionKeys.insert(key).inserted else {
                throw ThemeArchivePolicyError.invalidArchiveListing
            }
            if !line.hasSuffix("/") {
                nonDirectoryKeys.insert(key)
            }
            normalizedEntries.append(path)
        }

        // A regular-file entry must never also act as an ancestor of another
        // member. Some extractors resolve this conflict differently, and a
        // symlink encoded as such a file is especially dangerous.
        for entry in normalizedEntries {
            var components = entry.split(separator: "/").map(String.init)
            components.removeLast()
            var ancestor = ""
            for component in components {
                ancestor = ancestor.isEmpty
                    ? component
                    : "\(ancestor)/\(component)"
                guard !nonDirectoryKeys.contains(
                    filesystemCollisionKey(ancestor)
                ) else {
                    throw ThemeArchivePolicyError.invalidArchiveListing
                }
            }
        }
        return lines
    }

    /// Validates the locale-stabilized `unzip -Z -t` summary before
    /// extraction. This rejects declared ZIP bombs before `ditto` can write
    /// their expanded bytes to disk; the extracted-tree pass remains the
    /// second line of defense against dishonest metadata.
    static func validateArchiveTotals(
        from totalsData: Data,
        limits: ThemeArchiveLimits = .standard
    ) throws {
        guard totalsData.count <= 4_096,
              let output = String(data: totalsData, encoding: .utf8),
              let line = output.split(
                separator: "\n",
                omittingEmptySubsequences: true
              ).last else {
            throw ThemeArchivePolicyError.invalidArchiveListing
        }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 5,
              fields[1] == "file," || fields[1] == "files,",
              fields[3] == "byte" || fields[3] == "bytes",
              fields[4] == "uncompressed,",
              let entryCount = Int(fields[0]),
              let expandedBytes = Int64(fields[2]),
              entryCount >= 0,
              expandedBytes >= 0 else {
            throw ThemeArchivePolicyError.invalidArchiveListing
        }
        guard entryCount <= limits.maximumEntryCount else {
            throw ThemeArchivePolicyError.tooManyEntries
        }
        guard expandedBytes <= limits.maximumExpandedBytes else {
            throw ThemeArchivePolicyError.expandedContentTooLarge
        }
    }

    static func validateArchiveEntryPath(_ path: String) throws {
        let displayPath = String(path.prefix(256))
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r") else {
            throw ThemeArchivePolicyError.unsafeArchivePath(displayPath)
        }

        var components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        if components.last?.isEmpty == true {
            components.removeLast()
        }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !looksLikeWindowsDrive(components[0]) else {
            throw ThemeArchivePolicyError.unsafeArchivePath(displayPath)
        }
    }

    /// Returns a canonical relative path suitable for an asset index, without
    /// touching the filesystem.
    static func normalizedAssetPath(_ relativePath: String) -> String? {
        guard !relativePath.hasSuffix("/") else { return nil }
        do {
            try validateArchiveEntryPath(relativePath)
        } catch {
            return nil
        }
        return relativePath.split(separator: "/").map(String.init).joined(
            separator: "/"
        )
    }

    /// Checks the selected input without following a final symlink.
    static func validateArchiveFile(
        at url: URL,
        fileManager: FileManager = .default,
        limits: ThemeArchiveLimits = .standard
    ) throws {
        guard url.isFileURL,
              let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
              ),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ThemeArchivePolicyError.archiveIsNotRegularFile
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= limits.maximumArchiveBytes else {
            throw ThemeArchivePolicyError.archiveTooLarge
        }
    }

    /// Defense in depth after extraction. No symlinks, sockets, devices, or
    /// other special objects are accepted, and total expanded size/count are
    /// bounded. The worker extracts only inside a private staging directory,
    /// then calls this before reading the manifest or moving any content.
    static func validateExtractedTree(
        at rootURL: URL,
        fileManager: FileManager = .default,
        limits: ThemeArchiveLimits = .standard
    ) throws {
        guard isDirectDirectory(rootURL, fileManager: fileManager) else {
            throw ThemeArchivePolicyError.unsafeBundleRoot
        }

        let root = rootURL.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ThemeArchivePolicyError.unsafeBundleRoot
        }

        var entryCount = 0
        var expandedBytes: Int64 = 0
        while let entry = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let candidate = entry.standardizedFileURL
            guard candidate.path.hasPrefix(rootPrefix) else {
                throw ThemeArchivePolicyError.unsafeFilesystemObject(
                    safeDisplayPath(entry.path)
                )
            }

            let relativePath = String(candidate.path.dropFirst(rootPrefix.count))
            do {
                try validateArchiveEntryPath(relativePath)
            } catch {
                throw ThemeArchivePolicyError.unsafeFilesystemObject(
                    safeDisplayPath(relativePath)
                )
            }

            guard let attributes = try? fileManager.attributesOfItem(
                atPath: entry.path
            ), let type = attributes[.type] as? FileAttributeType else {
                throw ThemeArchivePolicyError.unsafeFilesystemObject(
                    safeDisplayPath(relativePath)
                )
            }

            switch type {
            case .typeDirectory:
                break
            case .typeRegular:
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard size >= 0,
                      expandedBytes <= limits.maximumExpandedBytes - size else {
                    throw ThemeArchivePolicyError.expandedContentTooLarge
                }
                expandedBytes += size
            default:
                throw ThemeArchivePolicyError.unsafeFilesystemObject(
                    safeDisplayPath(relativePath)
                )
            }

            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw ThemeArchivePolicyError.tooManyEntries
            }
        }

        if enumerationError != nil {
            throw ThemeArchivePolicyError.unsafeBundleRoot
        }
    }

    /// Resolves an asset only when every directory component is a real
    /// directory and the final object is a regular file. The returned URL is
    /// always lexically contained within `rootURL`.
    static func safeRegularFile(
        atRelativePath relativePath: String,
        within rootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let normalized = normalizedAssetPath(relativePath),
              isDirectDirectory(rootURL, fileManager: fileManager) else {
            return nil
        }

        let root = rootURL.standardizedFileURL
        let components = normalized.split(separator: "/").map(String.init)
        var candidate = root
        for (index, component) in components.enumerated() {
            candidate.appendPathComponent(
                component,
                isDirectory: index < components.count - 1
            )
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: candidate.path
            ), let type = attributes[.type] as? FileAttributeType else {
                return nil
            }
            let expected: FileAttributeType =
                index == components.count - 1 ? .typeRegular : .typeDirectory
            guard type == expected else { return nil }
        }

        let standardized = candidate.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return standardized.path.hasPrefix(rootPrefix) ? standardized : nil
    }

    static func isDirectDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard url.isFileURL,
              let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
              ) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    static func isDirectRegularFile(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard url.isFileURL,
              let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
              ) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    static func isDirectChild(
        _ candidateURL: URL,
        of directoryURL: URL
    ) -> Bool {
        let candidate = candidateURL.standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        return candidate.deletingLastPathComponent() == directory
            && candidate != directory
    }

    static func manifestData(
        in bundleURL: URL,
        fileManager: FileManager = .default,
        limits: ThemeArchiveLimits = .standard
    ) throws -> Data {
        guard let manifestURL = safeRegularFile(
            atRelativePath: "theme.json",
            within: bundleURL,
            fileManager: fileManager
        ) else {
            throw ThemeArchivePolicyError.missingManifest
        }
        let attributes = try fileManager.attributesOfItem(
            atPath: manifestURL.path
        )
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= limits.maximumManifestBytes else {
            throw ThemeArchivePolicyError.manifestTooLarge
        }
        return try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
    }

    private static func looksLikeWindowsDrive(_ component: String) -> Bool {
        guard component.count >= 2 else { return false }
        let scalars = Array(component.unicodeScalars)
        guard scalars[1] == ":" else { return false }
        return CharacterSet.letters.contains(scalars[0])
    }

    private static func filesystemCollisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func safeDisplayPath(_ path: String) -> String {
        String(path.prefix(256))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
