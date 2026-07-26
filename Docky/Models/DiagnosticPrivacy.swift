//
//  DiagnosticPrivacy.swift
//  Docky
//
//  Privacy-preserving descriptions for failures recorded in feedback traces.
//

import Foundation

nonisolated enum DiagnosticPrivacy {
    /// Returns enough structure to group failures without serializing
    /// localized descriptions, paths, URLs, user names, or other values from
    /// an NSError's userInfo dictionary.
    static func errorDescriptor(_ error: Error) -> String {
        let nsError = error as NSError
        return "error:type:\(String(reflecting: type(of: error))):" +
            "code:\(nsError.code)"
    }

    /// Describes an already-flattened private string without preserving its
    /// contents. Prefer `errorDescriptor(_:)` while the Error still exists.
    static func redactedTextDescriptor(_ text: String?) -> String {
        guard let text else { return "none" }
        return "redacted:utf8Bytes:\(text.utf8.count)"
    }

    /// Error fields in the trace accept only values created by this type.
    /// This is the final defense when a future call site accidentally passes
    /// a localized error string directly to `DiagnosticsTrace.record`.
    static func sanitizeErrorField(_ value: String) -> String {
        guard value.hasPrefix("error:")
                || value.hasPrefix("redacted:")
                || value == "none"
        else {
            return redactedTextDescriptor(value)
        }
        return value
    }

    static func sanitizeTraceString(
        field: String,
        value: String
    ) -> String {
        guard field.range(
            of: "error",
            options: [.caseInsensitive]
        ) != nil else {
            return value
        }
        return sanitizeErrorField(value)
    }
}
