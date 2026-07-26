//
//  ThemeStorageWorker.swift
//  Docky
//
//  Serialized, non-main-actor read-only catalog scans for themes. The legacy
//  pathname-based mutation implementations are unavailable to every caller
//  and must not be treated as production-safe.
//

import Darwin
import Foundation

nonisolated struct InstalledTheme: Equatable, @unchecked Sendable {
    let manifest: ThemeManifest
    let bundleURL: URL
    let isBundled: Bool
    let coverImageURL: URL?
    let appIconURLsByBundleIdentifier: [String: URL]
    let assetURLsByRelativePath: [String: URL]

    /// Pure cached lookup. Filesystem validation happens while the immutable
    /// catalog snapshot is assembled on ThemeStorageWorker.
    func assetURL(for relativePath: String) -> URL? {
        guard let normalized = ThemeArchivePolicy.normalizedAssetPath(
            relativePath
        ) else {
            return nil
        }
        return assetURLsByRelativePath[normalized]
    }
}

nonisolated struct ThemeCatalogSnapshot: Equatable, Sendable {
    let revision: UInt64
    let installedThemes: [String: InstalledTheme]

    func withRevision(_ revision: UInt64) -> ThemeCatalogSnapshot {
        ThemeCatalogSnapshot(
            revision: revision,
            installedThemes: installedThemes
        )
    }
}

nonisolated struct ThemeImportResult: @unchecked Sendable {
    let manifest: ThemeManifest
    let catalog: ThemeCatalogSnapshot
}

nonisolated struct ThemeExportAsset: Equatable, Sendable {
    let sourceURL: URL
    let relativePath: String
}

nonisolated struct ThemeExportRequest: @unchecked Sendable {
    let manifest: ThemeManifest
    let assets: [ThemeExportAsset]
}

actor ThemeStorageWorker {
    private var operationTail = Task<Void, Never> {}
    private let catalogRevisionClock = ThemeCatalogRevisionClock()

    func refreshCatalog(
        bundledDirectoryURL: URL?,
        userDirectoryURL: URL
    ) async throws -> ThemeCatalogSnapshot {
        let revisionClock = catalogRevisionClock
        return try await serialized {
            try Self.refreshCatalogSynchronously(
                bundledDirectoryURL: bundledDirectoryURL,
                userDirectoryURL: userDirectoryURL
            ).withRevision(revisionClock.next())
        }
    }

    @available(
        *,
        unavailable,
        message: "Runtime theme mutation is disabled until fd-relative tree operations are implemented."
    )
    func deleteTheme(
        bundleURL: URL,
        bundledDirectoryURL: URL?,
        userDirectoryURL: URL
    ) async throws -> ThemeCatalogSnapshot {
        let revisionClock = catalogRevisionClock
        return try await serialized {
            let fileManager = FileManager.default
            try Self.prepareUserThemesDirectory(
                userDirectoryURL,
                fileManager: fileManager
            )
            try Task.checkCancellation()
            guard ThemeArchivePolicy.isDirectChild(
                bundleURL,
                of: userDirectoryURL
            ), ThemeArchivePolicy.isDirectDirectory(
                bundleURL,
                fileManager: fileManager
            ) else {
                throw ThemeStorageError.unsafeDeletionTarget
            }
            try fileManager.removeItem(at: bundleURL)
            return try Self.refreshCatalogSynchronously(
                bundledDirectoryURL: bundledDirectoryURL,
                userDirectoryURL: userDirectoryURL
            ).withRevision(revisionClock.next())
        }
    }

    @available(
        *,
        unavailable,
        message: "Runtime theme mutation is disabled until fd-relative tree operations are implemented."
    )
    func importTheme(
        from archiveURL: URL,
        bundledDirectoryURL: URL?,
        userDirectoryURL: URL
    ) async throws -> ThemeImportResult {
        let revisionClock = catalogRevisionClock
        return try await serialized {
            try Task.checkCancellation()
            let fileManager = FileManager.default
            let limits = ThemeArchiveLimits.standard
            try Self.prepareUserThemesDirectory(
                userDirectoryURL,
                fileManager: fileManager
            )

            // Work only from a bounded, immutable private snapshot. Every
            // validation command and the extractor therefore sees identical
            // bytes even if the picker source changes after selection.
            let operationRoot = userDirectoryURL.appendingPathComponent(
                ".docky-import-operation-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: operationRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: operationRoot) }
            let snapshotURL = operationRoot.appendingPathComponent(
                "theme-archive.snapshot",
                isDirectory: false
            )
            try Self.snapshotArchive(
                from: archiveURL,
                to: snapshotURL,
                limits: limits
            )
            try ThemeArchivePolicy.validateArchiveFile(
                at: snapshotURL,
                fileManager: fileManager,
                limits: limits
            )

            // `unzip -t` inflates every member without writing it and verifies
            // CRC/length consistency. Declared totals are trusted only after
            // that full-stream verification succeeds on the same snapshot.
            let integrity = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-t", snapshotURL.path],
                timeout: 60,
                maximumStandardOutputBytes: 128 * 1_024,
                maximumStandardErrorBytes: 128 * 1_024
            )
            guard integrity.terminationStatus == 0 else {
                throw ThemeImportError.listingFailed(
                    status: integrity.terminationStatus,
                    stderr: integrity.standardErrorString
                )
            }

            let totals = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-Z", "-t", snapshotURL.path],
                timeout: 15,
                maximumStandardOutputBytes: 4_096,
                maximumStandardErrorBytes: 128 * 1_024
            )
            guard totals.terminationStatus == 0 else {
                throw ThemeImportError.listingFailed(
                    status: totals.terminationStatus,
                    stderr: totals.standardErrorString
                )
            }
            guard !totals.standardOutputWasTruncated else {
                throw ThemeArchivePolicyError.invalidArchiveListing
            }
            try ThemeArchivePolicy.validateArchiveTotals(
                from: totals.standardOutput,
                limits: limits
            )

            let listing = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-Z1", snapshotURL.path],
                timeout: 15,
                maximumStandardOutputBytes: limits.maximumListingBytes,
                maximumStandardErrorBytes: 128 * 1_024
            )
            guard listing.terminationStatus == 0 else {
                throw ThemeImportError.listingFailed(
                    status: listing.terminationStatus,
                    stderr: listing.standardErrorString
                )
            }
            guard !listing.standardOutputWasTruncated else {
                throw ThemeArchivePolicyError.invalidArchiveListing
            }
            _ = try ThemeArchivePolicy.validatedArchiveEntries(
                from: listing.standardOutput,
                limits: limits
            )

            let extractionRoot = operationRoot.appendingPathComponent(
                "extracted",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: extractionRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let extraction = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [
                    "-xk",
                    "--norsrc",
                    "--noextattr",
                    "--noacl",
                    "--noqtn",
                    snapshotURL.path,
                    extractionRoot.path,
                ],
                timeout: 60,
                maximumStandardOutputBytes: 64 * 1_024,
                maximumStandardErrorBytes: 256 * 1_024
            )
            guard extraction.terminationStatus == 0 else {
                throw ThemeImportError.extractionFailed(
                    status: extraction.terminationStatus,
                    stderr: extraction.standardErrorString
                )
            }
            try Task.checkCancellation()
            try ThemeArchivePolicy.validateExtractedTree(
                at: extractionRoot,
                fileManager: fileManager,
                limits: limits
            )

            let bundleRoot = try Self.locateBundleRoot(
                in: extractionRoot,
                fileManager: fileManager
            )
            let manifest = try Self.decodeManifest(
                in: bundleRoot,
                fileManager: fileManager,
                limits: limits
            )
            guard ThemeArchivePolicy.isValidThemeID(manifest.id) else {
                throw ThemeImportError.invalidID(manifest.id)
            }

            let preparedBundle = userDirectoryURL.appendingPathComponent(
                ".docky-prepared-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: bundleRoot, to: preparedBundle)
            var preparedBundleNeedsCleanup = true
            defer {
                if preparedBundleNeedsCleanup {
                    try? fileManager.removeItem(at: preparedBundle)
                }
            }
            try ThemeArchivePolicy.validateExtractedTree(
                at: preparedBundle,
                fileManager: fileManager,
                limits: limits
            )
            try Self.applyPrivatePermissions(
                toTreeAt: preparedBundle,
                fileManager: fileManager
            )

            let destination = userDirectoryURL.appendingPathComponent(
                manifest.id,
                isDirectory: true
            )
            try Self.transactionallyInstall(
                preparedBundle,
                at: destination,
                within: userDirectoryURL,
                fileManager: fileManager
            )
            preparedBundleNeedsCleanup = false

            let catalog = try Self.refreshCatalogSynchronously(
                bundledDirectoryURL: bundledDirectoryURL,
                userDirectoryURL: userDirectoryURL
            ).withRevision(revisionClock.next())
            return ThemeImportResult(
                manifest: manifest,
                catalog: catalog
            )
        }
    }

    @available(
        *,
        unavailable,
        message: "Runtime theme mutation is disabled until fd-relative tree operations are implemented."
    )
    func exportTheme(
        request: ThemeExportRequest,
        to destinationURL: URL
    ) async throws -> URL {
        try await serialized {
            try Task.checkCancellation()
            guard ThemeArchivePolicy.isValidThemeID(request.manifest.id),
                  destinationURL.isFileURL else {
                throw ThemeExportError.invalidDestination
            }
            try ThemeManifestPolicy.validate(request.manifest)

            let fileManager = FileManager.default
            let staging = fileManager.temporaryDirectory.appendingPathComponent(
                "docky-theme-export-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: staging) }

            let bundleDirectory = staging.appendingPathComponent(
                request.manifest.id,
                isDirectory: true
            )
            let assetsDirectory = bundleDirectory.appendingPathComponent(
                "assets",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var usedRelativePaths = Set<String>()
            for asset in request.assets {
                try Task.checkCancellation()
                guard let normalized =
                        ThemeArchivePolicy.normalizedAssetPath(
                            asset.relativePath
                        ),
                      normalized.hasPrefix("assets/"),
                      usedRelativePaths.insert(normalized).inserted,
                      ThemeArchivePolicy.isDirectRegularFile(
                        asset.sourceURL,
                        fileManager: fileManager
                      ) else {
                    throw ThemeExportError.unsafeAsset(asset.relativePath)
                }
                let destination = bundleDirectory.appendingPathComponent(
                    normalized,
                    isDirectory: false
                ).standardizedFileURL
                let bundlePrefix = bundleDirectory.path.hasSuffix("/")
                    ? bundleDirectory.path
                    : bundleDirectory.path + "/"
                guard destination.path.hasPrefix(bundlePrefix),
                      destination.deletingLastPathComponent()
                        == assetsDirectory.standardizedFileURL else {
                    throw ThemeExportError.unsafeAsset(asset.relativePath)
                }
                do {
                    try fileManager.copyItem(
                        at: asset.sourceURL,
                        to: destination
                    )
                } catch {
                    throw ThemeExportError.assetCopyFailed(
                        asset.sourceURL.lastPathComponent
                    )
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(request.manifest)
            try manifestData.write(
                to: bundleDirectory.appendingPathComponent(
                    "theme.json",
                    isDirectory: false
                ),
                options: [.atomic]
            )
            try Self.applyPrivatePermissions(
                toTreeAt: bundleDirectory,
                fileManager: fileManager
            )

            let stagedArchive = staging.appendingPathComponent(
                "\(request.manifest.id).dockytheme",
                isDirectory: false
            )
            let archive = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [
                    "-c",
                    "-k",
                    "--keepParent",
                    "--norsrc",
                    "--noextattr",
                    "--noacl",
                    "--noqtn",
                    bundleDirectory.path,
                    stagedArchive.path,
                ],
                timeout: 60,
                maximumStandardOutputBytes: 64 * 1_024,
                maximumStandardErrorBytes: 256 * 1_024
            )
            guard archive.terminationStatus == 0 else {
                throw ThemeExportError.archiveFailed(
                    status: archive.terminationStatus,
                    stderr: archive.standardErrorString
                )
            }
            try Task.checkCancellation()
            try Self.installExportedArchive(
                stagedArchive,
                at: destinationURL,
                fileManager: fileManager
            )
            return destinationURL
        }
    }

    private func serialized<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = operationTail
        let task = Task<T, Error> {
            await predecessor.value
            try Task.checkCancellation()
            return try await operation()
        }
        operationTail = Task<Void, Never> {
            _ = try? await task.value
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func refreshCatalogSynchronously(
        bundledDirectoryURL: URL?,
        userDirectoryURL: URL
    ) throws -> ThemeCatalogSnapshot {
        let fileManager = FileManager.default
        var installedThemes: [String: InstalledTheme] = [:]
        if let bundledDirectoryURL,
           ThemeArchivePolicy.isDirectDirectory(
            bundledDirectoryURL,
            fileManager: fileManager
           ) {
            for (id, theme) in try scanInstalledThemes(
                at: bundledDirectoryURL,
                isBundled: true,
                fileManager: fileManager
            ) {
                installedThemes[id] = theme
            }
        }
        for (id, theme) in try scanInstalledThemes(
            at: userDirectoryURL,
            isBundled: false,
            fileManager: fileManager
        ) {
            installedThemes[id] = theme
        }
        return ThemeCatalogSnapshot(
            revision: 0,
            installedThemes: installedThemes
        )
    }

    private nonisolated static func prepareUserThemesDirectory(
        _ directoryURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            guard ThemeArchivePolicy.isDirectDirectory(
                directoryURL,
                fileManager: fileManager
            ) else {
                throw ThemeStorageError.unsafeThemesDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try recoverInterruptedInstallBackups(
            in: directoryURL,
            fileManager: fileManager
        )
    }

    private nonisolated static func recoverInterruptedInstallBackups(
        in themesDirectory: URL,
        fileManager: FileManager
    ) throws {
        let prefix = ".docky-backup-"
        let entries = try fileManager.contentsOfDirectory(
            at: themesDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for backup in entries where backup.lastPathComponent.hasPrefix(prefix) {
            try Task.checkCancellation()
            let themeID = String(
                backup.lastPathComponent.dropFirst(prefix.count)
            )
            guard ThemeArchivePolicy.isValidThemeID(themeID),
                  ThemeArchivePolicy.isDirectChild(
                    backup,
                    of: themesDirectory
                  ),
                  ThemeArchivePolicy.isDirectDirectory(
                    backup,
                    fileManager: fileManager
                  ) else {
                continue
            }
            let destination = themesDirectory.appendingPathComponent(
                themeID,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                guard ThemeArchivePolicy.isDirectDirectory(
                    destination,
                    fileManager: fileManager
                ) else {
                    throw ThemeStorageError.unsafeInstallDestination
                }
                try fileManager.removeItem(at: backup)
            } else {
                try fileManager.moveItem(at: backup, to: destination)
            }
        }
    }

    private nonisolated static func scanInstalledThemes(
        at directoryURL: URL,
        isBundled: Bool,
        fileManager: FileManager
    ) throws -> [String: InstalledTheme] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var result: [String: InstalledTheme] = [:]
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard ThemeArchivePolicy.isDirectChild(
                entry,
                of: directoryURL
            ), ThemeArchivePolicy.isDirectDirectory(
                entry,
                fileManager: fileManager
            ) else {
                continue
            }
            do {
                try ThemeArchivePolicy.validateExtractedTree(
                    at: entry,
                    fileManager: fileManager
                )
                let manifestData = try ThemeArchivePolicy.manifestData(
                    in: entry,
                    fileManager: fileManager
                )
                let manifest = try decoder.decode(
                    ThemeManifest.self,
                    from: manifestData
                )
                try ThemeManifestPolicy.validate(manifest)
                let assetIndex = try regularFileIndex(
                    in: entry,
                    fileManager: fileManager
                )
                result[manifest.id] = InstalledTheme(
                    manifest: manifest,
                    bundleURL: entry.standardizedFileURL,
                    isBundled: isBundled,
                    coverImageURL: coverImageURL(in: assetIndex),
                    appIconURLsByBundleIdentifier: appIconURLs(
                        in: assetIndex
                    ),
                    assetURLsByRelativePath: assetIndex
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return result
    }

    private nonisolated static func regularFileIndex(
        in bundleURL: URL,
        fileManager: FileManager
    ) throws -> [String: URL] {
        let root = bundleURL.standardizedFileURL
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
        var result: [String: URL] = [:]
        while let entry = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard ThemeArchivePolicy.isDirectRegularFile(
                entry,
                fileManager: fileManager
            ) else {
                continue
            }
            let standardized = entry.standardizedFileURL
            guard standardized.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(
                standardized.path.dropFirst(rootPrefix.count)
            )
            guard let normalized =
                    ThemeArchivePolicy.normalizedAssetPath(relative) else {
                continue
            }
            result[normalized] = standardized
        }
        if enumerationError != nil {
            throw ThemeArchivePolicyError.unsafeBundleRoot
        }
        return result
    }

    private nonisolated static func coverImageURL(
        in assetIndex: [String: URL]
    ) -> URL? {
        for name in [
            "cover_image.png",
            "cover_image.jpg",
            "cover_image.jpeg",
        ] {
            if let url = assetIndex[name] { return url }
        }
        return nil
    }

    private nonisolated static func appIconURLs(
        in assetIndex: [String: URL]
    ) -> [String: URL] {
        var result: [String: URL] = [:]
        for (relativePath, url) in assetIndex {
            let components = relativePath.split(separator: "/")
            guard components.count == 2,
                  components[0] == "assets",
                  ["png", "jpg", "jpeg"].contains(
                    url.pathExtension.lowercased()
                  ) else {
                continue
            }
            let bundleIdentifier = url.deletingPathExtension()
                .lastPathComponent
            guard bundleIdentifier.contains(".") else { continue }
            result[bundleIdentifier] = url
        }
        return result
    }

    private nonisolated static func locateBundleRoot(
        in extractionRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        if ThemeArchivePolicy.safeRegularFile(
            atRelativePath: "theme.json",
            within: extractionRoot,
            fileManager: fileManager
        ) != nil {
            return extractionRoot
        }
        let entries = try fileManager.contentsOfDirectory(
            at: extractionRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let directories = entries.filter {
            ThemeArchivePolicy.isDirectDirectory(
                $0,
                fileManager: fileManager
            )
        }
        guard directories.count == 1,
              ThemeArchivePolicy.safeRegularFile(
                atRelativePath: "theme.json",
                within: directories[0],
                fileManager: fileManager
              ) != nil else {
            throw ThemeImportError.missingManifest
        }
        return directories[0]
    }

    private nonisolated static func decodeManifest(
        in bundleURL: URL,
        fileManager: FileManager,
        limits: ThemeArchiveLimits
    ) throws -> ThemeManifest {
        let data: Data
        do {
            data = try ThemeArchivePolicy.manifestData(
                in: bundleURL,
                fileManager: fileManager,
                limits: limits
            )
        } catch ThemeArchivePolicyError.missingManifest {
            throw ThemeImportError.missingManifest
        }
        do {
            let manifest = try JSONDecoder().decode(
                ThemeManifest.self,
                from: data
            )
            try ThemeManifestPolicy.validate(manifest)
            return manifest
        } catch {
            throw ThemeImportError.invalidManifest(error)
        }
    }

    /// Copies a picker-selected archive through no-follow regular-file
    /// descriptors, enforcing both the advertised and actual byte count.
    /// Keeping the snapshot private and immutable also closes validation/use
    /// races between the integrity pass and extraction.
    private nonisolated static func snapshotArchive(
        from sourceURL: URL,
        to destinationURL: URL,
        limits: ThemeArchiveLimits
    ) throws {
        guard sourceURL.isFileURL, destinationURL.isFileURL else {
            throw ThemeArchivePolicyError.archiveIsNotRegularFile
        }

        let sourceDescriptor = sourceURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard sourceDescriptor >= 0 else {
            throw ThemeArchivePolicyError.archiveIsNotRegularFile
        }
        defer { _ = Darwin.close(sourceDescriptor) }

        var sourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
              sourceStatus.st_mode & S_IFMT == S_IFREG else {
            throw ThemeArchivePolicyError.archiveIsNotRegularFile
        }
        guard sourceStatus.st_size >= 0,
              sourceStatus.st_size <= limits.maximumArchiveBytes else {
            throw ThemeArchivePolicyError.archiveTooLarge
        }

        let destinationDescriptor = destinationURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationDescriptor >= 0 else {
            throw ThemeStorageError.unsafeInstallDestination
        }
        var snapshotSucceeded = false
        defer {
            _ = Darwin.close(destinationDescriptor)
            if !snapshotSucceeded {
                _ = destinationURL.path.withCString(Darwin.unlink)
            }
        }

        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    sourceDescriptor,
                    $0.baseAddress,
                    $0.count
                )
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ThemeArchivePolicyError.archiveIsNotRegularFile
            }
            guard totalBytes <= limits.maximumArchiveBytes
                    - Int64(count) else {
                throw ThemeArchivePolicyError.archiveTooLarge
            }
            totalBytes += Int64(count)

            var written = 0
            while written < count {
                try Task.checkCancellation()
                let result = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ThemeStorageError.unsafeInstallDestination
                }
                written += result
            }
        }
        guard totalBytes == sourceStatus.st_size else {
            throw ThemeArchivePolicyError.archiveIsNotRegularFile
        }
        guard Darwin.fchmod(
            destinationDescriptor,
            S_IRUSR | S_IWUSR
        ) == 0 else {
            throw ThemeStorageError.unsafeInstallDestination
        }
        if Darwin.fcntl(destinationDescriptor, F_FULLFSYNC) == -1,
           Darwin.fsync(destinationDescriptor) == -1 {
            throw ThemeStorageError.unsafeInstallDestination
        }
        snapshotSucceeded = true
    }

    private nonisolated static func transactionallyInstall(
        _ preparedBundle: URL,
        at destination: URL,
        within themesDirectory: URL,
        fileManager: FileManager
    ) throws {
        guard ThemeArchivePolicy.isDirectChild(
            destination,
            of: themesDirectory
        ) else {
            throw ThemeStorageError.unsafeInstallDestination
        }

        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: preparedBundle, to: destination)
            return
        }
        guard ThemeArchivePolicy.isDirectDirectory(
            destination,
            fileManager: fileManager
        ) else {
            throw ThemeStorageError.unsafeInstallDestination
        }

        let backup = themesDirectory.appendingPathComponent(
            ".docky-backup-\(destination.lastPathComponent)",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: backup.path) else {
            throw ThemeStorageError.unsafeInstallDestination
        }
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: preparedBundle, to: destination)
        } catch {
            try? fileManager.moveItem(at: backup, to: destination)
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }

    private nonisolated static func installExportedArchive(
        _ stagedArchive: URL,
        at destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let parent = destinationURL.deletingLastPathComponent()
        let replacement = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try fileManager.copyItem(at: stagedArchive, to: replacement)
        var replacementNeedsCleanup = true
        defer {
            if replacementNeedsCleanup {
                try? fileManager.removeItem(at: replacement)
            }
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard ThemeArchivePolicy.isDirectRegularFile(
                destinationURL,
                fileManager: fileManager
            ) else {
                throw ThemeExportError.invalidDestination
            }
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: replacement,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: replacement, to: destinationURL)
        }
        replacementNeedsCleanup = false
    }

    private nonisolated static func applyPrivatePermissions(
        toTreeAt rootURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ThemeArchivePolicyError.unsafeBundleRoot
        }
        while let entry = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let permissions: Int
            if ThemeArchivePolicy.isDirectDirectory(
                entry,
                fileManager: fileManager
            ) {
                permissions = 0o700
            } else if ThemeArchivePolicy.isDirectRegularFile(
                entry,
                fileManager: fileManager
            ) {
                permissions = 0o600
            } else {
                throw ThemeArchivePolicyError.unsafeFilesystemObject(
                    entry.lastPathComponent
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: entry.path
            )
        }
        if enumerationError != nil {
            throw ThemeArchivePolicyError.unsafeBundleRoot
        }
    }
}

private nonisolated final class ThemeCatalogRevisionClock:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var revision: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        return revision
    }
}

nonisolated enum ThemeStorageError: LocalizedError {
    case unsafeThemesDirectory
    case unsafeDeletionTarget
    case unsafeInstallDestination

    var errorDescription: String? {
        switch self {
        case .unsafeThemesDirectory:
            return "The Themes directory is not a safe local directory."
        case .unsafeDeletionTarget:
            return "Docky refused to delete an unsafe theme path."
        case .unsafeInstallDestination:
            return "Docky refused to replace an unsafe theme destination."
        }
    }
}

nonisolated enum ThemeExportError: LocalizedError {
    case invalidName(String)
    case invalidDestination
    case unsafeAsset(String)
    case assetCopyFailed(String)
    case archiveFailed(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "The name \"\(name)\" can't be used as a theme identifier."
        case .invalidDestination:
            return "The selected export destination is not a safe file."
        case .unsafeAsset(let path):
            return "The export contains an unsafe asset path: \(path)."
        case .assetCopyFailed(let name):
            return "Docky could not copy the theme asset \"\(name)\"."
        case .archiveFailed(let status, let stderr):
            let detail = stderr.isEmpty
                ? ""
                : " (\(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))"
            return "Failed to write theme archive (exit \(status))\(detail)."
        }
    }
}

nonisolated enum ThemeImportError: LocalizedError {
    case listingFailed(status: Int32, stderr: String)
    case extractionFailed(status: Int32, stderr: String)
    case missingManifest
    case invalidManifest(Error)
    case invalidID(String)

    var errorDescription: String? {
        switch self {
        case .listingFailed(let status, let stderr):
            let detail = stderr.isEmpty
                ? ""
                : " (\(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))"
            return "Failed to inspect theme archive (exit \(status))\(detail)."
        case .extractionFailed(let status, let stderr):
            let detail = stderr.isEmpty
                ? ""
                : " (\(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))"
            return "Failed to extract theme archive (exit \(status))\(detail)."
        case .missingManifest:
            return "The theme archive does not contain a theme.json manifest."
        case .invalidManifest(let underlying):
            return "The theme manifest is invalid: \(underlying.localizedDescription)"
        case .invalidID(let id):
            return "The theme manifest id \"\(id)\" is not a valid identifier."
        }
    }
}
