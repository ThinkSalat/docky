//
//  AtomicJSONFileStore.swift
//  Docky
//
//  Small hostless persistence primitive used for state that must survive a
//  crash without exposing a partially-written document. The primary and
//  backup are complete JSON documents; callers provide semantic validation.
//

import Foundation
import Darwin

struct AtomicJSONFileStore<Value: Codable> {
    enum Source: String, Equatable {
        case primary
        case backup
    }

    struct LoadResult {
        let value: Value
        let source: Source
        let recoveredPrimary: Bool
        let primaryFailureDescription: String?
    }

    enum StoreError: Error, LocalizedError {
        case noValidCopy(primary: String?, backup: String?)
        case primaryRecoveryRejected(String)
        case existingPrimaryInvalid(String)
        case primaryMissingWhileBackupExists
        case encodedValueFailedValidation(String)

        var errorDescription: String? {
            switch self {
            case .noValidCopy(let primary, let backup):
                return [
                    primary.map { "primary: \($0)" },
                    backup.map { "backup: \($0)" },
                ]
                .compactMap { $0 }
                .joined(separator: "; ")
            case .primaryRecoveryRejected(let reason):
                return "The primary document cannot be replaced by its backup: \(reason)"
            case .existingPrimaryInvalid(let reason):
                return "The existing primary document is invalid: \(reason)"
            case .primaryMissingWhileBackupExists:
                return "The primary document is missing while a backup still exists."
            case .encodedValueFailedValidation(let reason):
                return "The encoded document failed its own validation: \(reason)"
            }
        }
    }

    let primaryURL: URL
    let backupURL: URL

    private let fileManager: FileManager

    init(
        primaryURL: URL,
        backupURL: URL,
        fileManager: FileManager = .default
    ) {
        self.primaryURL = primaryURL
        self.backupURL = backupURL
        self.fileManager = fileManager
    }

    func load(
        validate: (Value) throws -> Void,
        canRecoverPrimaryFailure: (Error) -> Bool = { _ in true }
    ) throws -> LoadResult? {
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)
        guard primaryExists || backupExists else {
            return nil
        }

        var primaryFailure: Error?
        if primaryExists {
            do {
                let value = try decodedValue(at: primaryURL, validate: validate)
                return LoadResult(
                    value: value,
                    source: .primary,
                    recoveredPrimary: false,
                    primaryFailureDescription: nil
                )
            } catch {
                guard canRecoverPrimaryFailure(error) else {
                    throw StoreError.primaryRecoveryRejected(Self.describe(error))
                }
                primaryFailure = error
            }
        }

        var backupFailure: Error?
        if backupExists {
            do {
                let backupData = try Data(contentsOf: backupURL)
                let value = try decodedValue(from: backupData, validate: validate)
                try ensureParentDirectory()
                try atomicWrite(backupData, to: primaryURL)
                return LoadResult(
                    value: value,
                    source: .backup,
                    recoveredPrimary: true,
                    primaryFailureDescription: primaryFailure.map(Self.describe)
                )
            } catch {
                backupFailure = error
            }
        }

        throw StoreError.noValidCopy(
            primary: primaryFailure.map(Self.describe),
            backup: backupFailure.map(Self.describe)
        )
    }

    @discardableResult
    func save(
        _ value: Value,
        validate: (Value) throws -> Void
    ) throws -> Int {
        try validate(value)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)

        do {
            let roundTripped = try JSONDecoder().decode(Value.self, from: encoded)
            try validate(roundTripped)
        } catch {
            throw StoreError.encodedValueFailedValidation(Self.describe(error))
        }

        try ensureParentDirectory()

        if fileManager.fileExists(atPath: primaryURL.path) {
            let currentPrimary = try Data(contentsOf: primaryURL)
            do {
                _ = try decodedValue(from: currentPrimary, validate: validate)
            } catch {
                throw StoreError.existingPrimaryInvalid(Self.describe(error))
            }
            try atomicWrite(currentPrimary, to: backupURL)
        } else if fileManager.fileExists(atPath: backupURL.path) {
            // A missing primary with a surviving backup indicates an
            // interrupted or externally-modified store. Preserve it and
            // require an explicit load/recovery before accepting writes.
            throw StoreError.primaryMissingWhileBackupExists
        } else {
            // Seed a complete recovery copy before publishing the first
            // primary. A crash between these two atomic renames is recovered
            // from the backup on the next load.
            try atomicWrite(encoded, to: backupURL)
        }

        try atomicWrite(encoded, to: primaryURL)
        return encoded.count
    }

    private func decodedValue(
        at url: URL,
        validate: (Value) throws -> Void
    ) throws -> Value {
        try decodedValue(from: Data(contentsOf: url), validate: validate)
    }

    private func decodedValue(
        from data: Data,
        validate: (Value) throws -> Void
    ) throws -> Value {
        let value = try JSONDecoder().decode(Value.self, from: data)
        try validate(value)
        return value
    }

    private func ensureParentDirectory() throws {
        let directoryURL = primaryURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        // Prepare and permission the complete replacement before publishing
        // it. This avoids the split-brain case where the rename succeeds, a
        // later chmod fails, and the caller incorrectly believes the old
        // document is still authoritative.
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )

        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }
}
