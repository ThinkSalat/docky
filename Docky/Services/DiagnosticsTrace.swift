//
//  DiagnosticsTrace.swift
//  Docky
//
//  A small, always-on flight recorder for intermittent failures that are
//  difficult to reproduce under a debugger. Important transitions are
//  mirrored to Apple Unified Logging and to a bounded JSON Lines history.
//
//  The file trace is deliberately structural: callers provide state,
//  decisions, counts, and geometry, never window titles, file paths, or
//  profile names. Identifiers that may reveal installed apps or user-created
//  objects are represented by per-launch tokens.
//

import AppKit
import CryptoKit
import Foundation
import OSLog

nonisolated private enum DiagnosticTraceValue: Sendable {
    case string(String)
    case bool(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case double(Double)
    case strings([String])
    case signedIntegers([Int64])

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .bool(let value):
            return value
        case .signed(let value):
            return value
        case .unsigned(let value):
            // JSONSerialization cannot represent the full UInt64 range.
            return String(value)
        case .double(let value):
            return value
        case .strings(let value):
            return value
        case .signedIntegers(let value):
            return value
        }
    }

}

nonisolated private struct DiagnosticTraceEvent: Sendable {
    let timestamp: Date
    let uptimeSeconds: TimeInterval
    let sessionID: String
    let sequence: UInt64
    let processIdentifier: Int32
    let category: String
    let event: String
    let fields: [String: DiagnosticTraceValue]
}

/// A Sendable export capability captured from DiagnosticsTrace on MainActor.
/// Feedback preparation invokes it on its own worker; the underlying writer
/// still serializes the copy behind all previously-enqueued trace writes.
nonisolated struct DiagnosticsTraceExportSource: Sendable {
    private let copyAction: @Sendable (URL) throws -> Void

    fileprivate init(
        copyAction: @escaping @Sendable (URL) throws -> Void
    ) {
        self.copyAction = copyAction
    }

    func copyRetainedLogs(to destinationDirectory: URL) throws {
        try copyAction(destinationDirectory)
    }
}

/// Owns all potentially blocking work. Events reach this object only after
/// the main-actor caller has captured a small, Sendable value snapshot.
nonisolated private final class DiagnosticTraceWriter: @unchecked Sendable {
    private static let maximumFileBytes = 2 * 1_024 * 1_024
    private static let subsystem = "gt.quintero.Docky"

    private let queue = DispatchQueue(
        label: "gt.quintero.Docky.DiagnosticsTrace",
        qos: .utility
    )
    private let logStore: SecureBoundedLogStore
    private let timestampFormatter = ISO8601DateFormatter()
    private var lastWriteErrorType: String?
    private var lastWriteErrorUptime: TimeInterval = 0

    init(applicationSupportURL: URL) {
        logStore = SecureBoundedLogStore.applicationSupport(
            at: applicationSupportURL,
            descending: ["Docky", "Diagnostics"],
            currentName: "docky-events.jsonl",
            previousName: "docky-events.previous.jsonl",
            maximumFileBytes: Self.maximumFileBytes
        )
    }

    func enqueue(_ event: DiagnosticTraceEvent) {
        queue.async { [self] in
            write(event)
        }
    }

    func copyRetainedLogs(to destinationDirectory: URL) throws {
        try queue.sync {
            try logStore.copyRetainedLogs(to: destinationDirectory)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func write(_ event: DiagnosticTraceEvent) {
        var payload: [String: Any] = [
            "timestamp": timestampFormatter.string(from: event.timestamp),
            "uptimeSeconds": event.uptimeSeconds,
            "session": event.sessionID,
            "sequence": String(event.sequence),
            "pid": Int(event.processIdentifier),
            "category": event.category,
            "event": event.event,
        ]
        for (key, value) in event.fields {
            payload[key] = value.jsonObject
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                  withJSONObject: payload,
                  options: [.sortedKeys]
              )
        else {
            Logger(
                subsystem: Self.subsystem,
                category: "Diagnostics"
            ).error("Could not encode diagnostics event \(event.event, privacy: .public)")
            return
        }

        Logger(
            subsystem: Self.subsystem,
            category: event.category
        ).notice(
            "\(event.event, privacy: .public) sequence=\(event.sequence, privacy: .public)"
        )

        var line = data
        line.append(0x0A)
        append(line)
    }

    private func append(_ data: Data) {
        do {
            try logStore.append(data)
        } catch {
            let errorType = String(describing: type(of: error))
            let now = ProcessInfo.processInfo.systemUptime
            if errorType != lastWriteErrorType
                || now - lastWriteErrorUptime >= 60 {
                lastWriteErrorType = errorType
                lastWriteErrorUptime = now
                Logger(
                    subsystem: Self.subsystem,
                    category: "Diagnostics"
                ).error(
                    "Diagnostics trace write failed: \(errorType, privacy: .public)"
                )
            }
        }
    }
}

@MainActor
final class DiagnosticsTrace {
    static let shared = DiagnosticsTrace()

    enum Category: String {
        case lifecycle
        case input
        case actions
        case windows
        case profiles
        case spaces
        case visibility
        case preferences
        case systemDock
        case widgets
    }

    private let writer: DiagnosticTraceWriter
    private let sessionID = UUID().uuidString
    private let tokenKey = SymmetricKey(size: .bits256)
    private var sequence: UInt64 = 0
    private var defaultsObserver: NSObjectProtocol?
    private var defaultsAuditTimer: Timer?
    private var defaultsSnapshot: [String: Any] = [:]
    private var hasStarted = false

    nonisolated private static let auditedPreferenceKeys = [
        "docky.activeProfileID",
        "docky.appTileFrontmostClickBehavior",
        "docky.autohidesWindow",
        "docky.enablesShelveMode",
        "docky.hidesDuringFullscreen",
        "docky.hidesProfileStrip",
        "docky.hidesSystemDock",
        "docky.maximizedWindowBehavior",
        "docky.profiles",
        "docky.windowSpaceBehavior",
    ]

    private init() {
        let fileManager = FileManager.default
        let applicationSupport = (
            try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        ) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        writer = DiagnosticTraceWriter(
            applicationSupportURL: applicationSupport
        )
    }

    /// Starts preference auditing and records one launch boundary. Safe to
    /// call more than once; the first call owns the process session.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        defaultsSnapshot = Self.auditedDefaultsSnapshot()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordPreferenceChanges(source: "inProcessNotification")
            }
        }
        let auditTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // didChangeNotification is process-local. This periodic read
                // also catches writes made by another Docky copy or process.
                self?.recordPreferenceChanges(source: "periodicExternalAudit")
            }
        }
        auditTimer.tolerance = 1
        // Do not run preference auditing inside menu/mouse-tracking modes.
        // It can wait until the default run loop resumes after interaction.
        RunLoop.main.add(auditTimer, forMode: .default)
        defaultsAuditTimer = auditTimer

        record(.lifecycle, "launch", fields: [
            "version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "?",
            "build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "?",
            "defaultsKeyCount": Self.allDockyDefaultsKeyCount(),
            "auditedDefaultsKeyCount": defaultsSnapshot.count,
            "screenCount": NSScreen.screens.count,
        ])
    }

    /// Enqueues an event for Unified Logging and the bounded file history.
    /// The caller only captures small value snapshots; formatting, encoding,
    /// logging, rotation, and file I/O all happen off the main actor.
    func record(
        _ category: Category,
        _ event: String,
        fields: [String: Any] = [:]
    ) {
        sequence &+= 1
        writer.enqueue(
            DiagnosticTraceEvent(
                timestamp: Date(),
                uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                sessionID: sessionID,
                sequence: sequence,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                category: category.rawValue,
                event: event,
                fields: Dictionary(
                    uniqueKeysWithValues: fields.map { key, value in
                        (
                            key,
                            Self.traceValue(field: key, value: value)
                        )
                    }
                )
            )
        )
    }

    /// Per-launch pseudonym for bundle IDs, tile IDs, profile IDs, and other
    /// identifiers that need correlation without being written verbatim.
    func token(_ rawValue: String?) -> String {
        guard let rawValue, !rawValue.isEmpty else { return "none" }
        return token(Data(rawValue.utf8))
    }

    /// Copies a consistent snapshot of both retained generations into an
    /// existing diagnostic-bundle directory. The writer opens and closes each
    /// append, so draining the serial queue is sufficient for consistency.
    func copyRetainedLogs(to destinationDirectory: URL) throws {
        try writer.copyRetainedLogs(to: destinationDirectory)
    }

    /// Captures only a Sendable copy capability. Calling it later does not
    /// touch DiagnosticsTrace's MainActor state; file I/O remains serialized
    /// by the writer queue.
    func makeExportSource() -> DiagnosticsTraceExportSource {
        let writer = writer
        return DiagnosticsTraceExportSource { destinationDirectory in
            try writer.copyRetainedLogs(to: destinationDirectory)
        }
    }

    /// Drains queued writes. Used only during orderly termination and export;
    /// ordinary events remain fully asynchronous.
    func flush() {
        writer.flush()
    }

    private func recordPreferenceChanges(source: String) {
        let next = Self.auditedDefaultsSnapshot()
        let changedKeys = Set(defaultsSnapshot.keys)
            .union(next.keys)
            .filter { key in
                !Self.valuesEqual(defaultsSnapshot[key], next[key])
            }
            .sorted()

        for key in changedKeys {
            record(.preferences, "changed", fields: [
                "source": source,
                "key": key,
                "old": safePreferenceSummary(defaultsSnapshot[key]),
                "new": safePreferenceSummary(next[key]),
            ])
        }
        defaultsSnapshot = next
    }

    private func safePreferenceSummary(_ value: Any?) -> String {
        guard let value else { return "absent" }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }

        if let string = value as? String {
            // UserDefaults strings can contain user-authored labels or paths
            // even when the key name does not make that obvious. Preserve
            // change correlation without ever recording the raw value.
            return "string:\(string.count):token:\(token(string))"
        }

        if let data = value as? Data {
            return "data:\(data.count):token:\(token(data))"
        }

        if let array = value as? [Any] {
            return "array:\(array.count):token:\(token(String(describing: array)))"
        }

        if let dictionary = value as? [String: Any] {
            return "dictionary:\(dictionary.count):token:\(token(String(describing: dictionary)))"
        }

        return "\(String(describing: type(of: value))):token:\(token(String(describing: value)))"
    }

    private func token(_ data: Data) -> String {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: data,
            using: tokenKey
        )
        return authenticationCode
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func auditedDefaultsSnapshot() -> [String: Any] {
        let defaults = UserDefaults.standard
        return Dictionary(
            uniqueKeysWithValues: auditedPreferenceKeys.compactMap { key in
                defaults.object(forKey: key).map { (key, $0) }
            }
        )
    }

    nonisolated private static func allDockyDefaultsKeyCount() -> Int {
        UserDefaults.standard.dictionaryRepresentation().reduce(into: 0) {
            if $1.key.hasPrefix("docky.") {
                $0 += 1
            }
        }
    }

    nonisolated private static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        case let (lhs as NSObject, rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return String(describing: lhs) == String(describing: rhs)
        }
    }

    nonisolated private static func traceValue(
        field: String,
        value: Any
    ) -> DiagnosticTraceValue {
        switch value {
        case let value as String:
            return .string(
                DiagnosticPrivacy.sanitizeTraceString(
                    field: field,
                    value: value
                )
            )
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .signed(Int64(value))
        case let value as Int8:
            return .signed(Int64(value))
        case let value as Int16:
            return .signed(Int64(value))
        case let value as Int32:
            return .signed(Int64(value))
        case let value as Int64:
            return .signed(value)
        case let value as UInt:
            return .unsigned(UInt64(value))
        case let value as UInt8:
            return .unsigned(UInt64(value))
        case let value as UInt16:
            return .unsigned(UInt64(value))
        case let value as UInt32:
            return .unsigned(UInt64(value))
        case let value as UInt64:
            return .unsigned(value)
        case let value as Double:
            return .double(value)
        case let value as Float:
            return .double(Double(value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .double(value.doubleValue)
        case let value as [String]:
            return .strings(
                value.map {
                    DiagnosticPrivacy.sanitizeTraceString(
                        field: field,
                        value: $0
                    )
                }
            )
        case let value as [Int]:
            return .signedIntegers(value.map(Int64.init))
        default:
            // Callers should pass only the supported scalar/array shapes.
            // Preserve the unexpected type for diagnosis without serializing
            // its potentially sensitive value description.
            return .string("unsupported:\(String(describing: type(of: value)))")
        }
    }
}
