import Foundation
import XCTest

final class DiagnosticPrivacyTests: XCTestCase {
    func testErrorDescriptorOmitsPathsAndUserInfoValues() {
        let secretPath = "/Users/example/Secret Project/private.json"
        let error = NSError(
            domain: "TestDomain",
            code: 73,
            userInfo: [
                NSFilePathErrorKey: secretPath,
                NSLocalizedDescriptionKey:
                    "Could not replace \(secretPath)",
            ]
        )

        let descriptor = DiagnosticPrivacy.errorDescriptor(error)

        XCTAssertFalse(descriptor.contains("TestDomain"))
        XCTAssertTrue(descriptor.contains("73"))
        XCTAssertTrue(descriptor.hasPrefix("error:"))
        XCTAssertFalse(descriptor.contains(secretPath))
        XCTAssertFalse(descriptor.contains("Secret Project"))
        XCTAssertFalse(descriptor.contains("Could not replace"))
    }

    func testRedactedTextDescriptorKeepsOnlyByteCount() {
        let secret = "/Users/example/Confidential"

        let descriptor = DiagnosticPrivacy.redactedTextDescriptor(secret)

        XCTAssertEqual(
            descriptor,
            "redacted:utf8Bytes:\(secret.utf8.count)"
        )
        XCTAssertFalse(descriptor.contains("example"))
        XCTAssertFalse(descriptor.contains("Confidential"))
    }

    func testErrorFieldSanitizerRejectsAnAccidentalLocalizedDescription() {
        let secret = "Write failed at /Users/example/Secret/file.json"

        let sanitized = DiagnosticPrivacy.sanitizeErrorField(secret)

        XCTAssertEqual(
            sanitized,
            "redacted:utf8Bytes:\(secret.utf8.count)"
        )
        XCTAssertFalse(sanitized.contains("/Users/"))
    }

    func testTraceBoundarySanitizesEveryStringErrorField() {
        let secret = "/Users/example/Secret/file.json"

        XCTAssertEqual(
            DiagnosticPrivacy.sanitizeTraceString(
                field: "primaryErrorDescription",
                value: secret
            ),
            "redacted:utf8Bytes:\(secret.utf8.count)"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizeTraceString(
                field: "ordinaryDecision",
                value: secret
            ),
            secret
        )
        XCTAssertEqual(
            [
                secret,
                "another private description",
            ].map {
                DiagnosticPrivacy.sanitizeTraceString(
                    field: "nestedErrors",
                    value: $0
                )
            },
            [
                "redacted:utf8Bytes:\(secret.utf8.count)",
                "redacted:utf8Bytes:27",
            ]
        )
    }
}
