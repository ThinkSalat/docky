import Foundation
import XCTest

final class ThemeManifestPolicyTests: XCTestCase {
    func testMinimalManifestIsAccepted() throws {
        let manifest = try decodeManifest(
            """
            {
              "schemaVersion": 1,
              "id": "example.safe-theme",
              "name": "Safe Theme",
              "appearance": {}
            }
            """
        )

        XCTAssertNoThrow(try ThemeManifestPolicy.validate(manifest))
    }

    func testUnsupportedSchemaAndUnboundedNumbersAreRejected() throws {
        let future = try decodeManifest(
            """
            {
              "schemaVersion": 99,
              "id": "example.future",
              "name": "Future",
              "appearance": {}
            }
            """
        )
        XCTAssertThrowsError(try ThemeManifestPolicy.validate(future)) {
            XCTAssertEqual(
                $0 as? ThemeManifestValidationError,
                .unsupportedSchemaVersion(found: 99, supported: 1)
            )
        }

        let enormous = try decodeManifest(
            """
            {
              "schemaVersion": 1,
              "id": "example.enormous",
              "name": "Enormous",
              "appearance": {
                "window": { "cornerRadius": 1e308 }
              }
            }
            """
        )
        XCTAssertThrowsError(try ThemeManifestPolicy.validate(enormous)) {
            XCTAssertEqual(
                $0 as? ThemeManifestValidationError,
                .invalidNumber(field: "window.cornerRadius")
            )
        }
    }

    func testColorsRequireCompleteBoundedComponents() throws {
        let incomplete = try decodeManifest(
            """
            {
              "schemaVersion": 1,
              "id": "example.incomplete-color",
              "name": "Incomplete",
              "appearance": {
                "window": {
                  "tintColor": { "r": 0.5, "g": 0.5 }
                }
              }
            }
            """
        )

        XCTAssertThrowsError(try ThemeManifestPolicy.validate(incomplete)) {
            XCTAssertEqual(
                $0 as? ThemeManifestValidationError,
                .incompleteColor(field: "window.tintColor")
            )
        }

        let outOfRange = try decodeManifest(
            """
            {
              "schemaVersion": 1,
              "id": "example.bad-color",
              "name": "Bad Color",
              "appearance": {
                "window": {
                  "tintColor": { "r": 2, "g": 0.5, "b": 0.5 }
                }
              }
            }
            """
        )
        XCTAssertThrowsError(try ThemeManifestPolicy.validate(outOfRange)) {
            XCTAssertEqual(
                $0 as? ThemeManifestValidationError,
                .invalidNumber(field: "window.tintColor")
            )
        }
    }

    func testLayoutKindsSpansAndAnchorsAreValidated() throws {
        let unknownKind = try decodeManifest(
            """
            {
              "schemaVersion": 1,
              "id": "example.unknown-kind",
              "name": "Unknown",
              "appearance": {},
              "layout": {
                "insertions": [{ "kind": "executeSomething" }]
              }
            }
            """
        )
        XCTAssertThrowsError(
            try ThemeManifestPolicy.validate(unknownKind)
        )

        let ambiguous = try decodeManifest(
            """
            {
              "schemaVersion": 1,
              "id": "example.ambiguous",
              "name": "Ambiguous",
              "appearance": {},
              "layout": {
                "insertions": [{
                  "kind": "search",
                  "after": "one",
                  "before": "two",
                  "span": 9
                }]
              }
            }
            """
        )
        XCTAssertThrowsError(try ThemeManifestPolicy.validate(ambiguous))
    }

    func testUnsafeAssetPathIsRejected() throws {
        let manifest = try decodeManifest(
            """
            {
              "schemaVersion": 1,
              "id": "example.path",
              "name": "Path",
              "appearance": {
                "window": { "backgroundImage": "../outside.png" }
              }
            }
            """
        )

        XCTAssertThrowsError(try ThemeManifestPolicy.validate(manifest)) {
            XCTAssertEqual(
                $0 as? ThemeManifestValidationError,
                .invalidAssetPath(field: "window.backgroundImage")
            )
        }
    }

    private func decodeManifest(_ source: String) throws -> ThemeManifest {
        try JSONDecoder().decode(
            ThemeManifest.self,
            from: try XCTUnwrap(source.data(using: .utf8))
        )
    }
}
