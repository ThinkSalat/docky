import Foundation
import XCTest

final class NormalizedPreferenceMutationTests: XCTestCase {
    func testClampedSemanticChangeStillRequiresPersistence() {
        let mutation = NormalizedPreferenceMutation(
            oldValue: 0.5,
            proposedValue: -4.0,
            normalize: { max(0, $0) }
        )

        XCTAssertEqual(mutation.normalizedValue, 0)
        XCTAssertTrue(mutation.shouldPersist)
    }

    func testClampedAssignmentMatchingOldValueDoesNotRewriteStorage() {
        let mutation = NormalizedPreferenceMutation(
            oldValue: 0.0,
            proposedValue: -4.0,
            normalize: { max(0, $0) }
        )

        XCTAssertEqual(mutation.normalizedValue, 0)
        XCTAssertFalse(mutation.shouldPersist)
    }

    func testCanonicalizedCollectionChangeRequiresPersistence() {
        let mutation = NormalizedPreferenceMutation(
            oldValue: ["com.example.alpha"],
            proposedValue: [
                "com.example.beta",
                "",
                "com.example.alpha",
                "com.example.beta",
            ],
            normalize: normalizedBundleIdentifiers
        )

        XCTAssertEqual(
            mutation.normalizedValue,
            ["com.example.alpha", "com.example.beta"]
        )
        XCTAssertTrue(mutation.shouldPersist)
    }

    func testEquivalentCanonicalizedCollectionDoesNotRewriteStorage() {
        let mutation = NormalizedPreferenceMutation(
            oldValue: ["com.example.alpha", "com.example.beta"],
            proposedValue: [
                "com.example.beta",
                "com.example.alpha",
                "com.example.beta",
                "",
            ],
            normalize: normalizedBundleIdentifiers
        )

        XCTAssertEqual(
            mutation.normalizedValue,
            ["com.example.alpha", "com.example.beta"]
        )
        XCTAssertFalse(mutation.shouldPersist)
    }

    func testEveryNormalizedPreferenceObserverPersistsAfterCorrection()
        throws {
        let source = try dockyPreferencesSource()
        let scalarProperties = [
            "autohideWindowDelay",
            "autohideAnimationDuration",
            "fullscreenRevealDelay",
            "windowPreviewHoverDelay",
            "widgetHoverPreviewDelay",
            "launchpadOverlayTransparency",
            "launchpadGridColumnCount",
            "launchpadGridRowCount",
            "launchpadBaseIconSize",
            "launchpadColumnSpacing",
        ]

        for property in scalarProperties {
            let observer = try didSetBody(
                for: property,
                in: source
            )
            assertNormalizationPipeline(
                in: observer,
                property: property,
                persistedKey: property
            )
        }
    }

    func testHiddenAppNormalizationCompletesProfileTransactionBeforeMirror()
        throws {
        let source = try dockyPreferencesSource()
        let observer = try didSetBody(
            for: "hiddenAppBundleIdentifiers",
            in: source
        )

        assertNormalizationPipeline(
            in: observer,
            property: "hiddenAppBundleIdentifiers",
            persistedKey: "hiddenAppBundleIdentifiers"
        )
        XCTAssertTrue(
            observer.contains(
                "$0.hiddenAppBundleIdentifiers = "
                    + "mutation.normalizedValue"
            )
        )
        XCTAssertTrue(
            observer.contains(
                "defaults.set(\n"
                    + "                mutation.normalizedValue,\n"
                    + "                forKey: "
                    + "Keys.hiddenAppBundleIdentifiers\n"
                    + "            )"
            )
        )
        assertAppearsInOrder(
            [
                "guard mutation.shouldPersist else { return }",
                "guard mirrorToActiveProfile({",
                "defaults.set(",
            ],
            in: observer
        )
    }

    private func assertNormalizationPipeline(
        in observer: String,
        property: String,
        persistedKey: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            observer.contains("NormalizedPreferenceMutation("),
            "\(property) must use the tested normalization plan",
            file: file,
            line: line
        )
        XCTAssertTrue(
            observer.contains("oldValue: oldValue"),
            "\(property) must compare against its previous semantic value",
            file: file,
            line: line
        )
        XCTAssertTrue(
            observer.contains("proposedValue: \(property)"),
            "\(property) must normalize the proposed assignment",
            file: file,
            line: line
        )
        assertAppearsInOrder(
            [
                "if \(property) != mutation.normalizedValue {",
                "\(property) = mutation.normalizedValue",
                "guard mutation.shouldPersist else { return }",
                "forKey: Keys.\(persistedKey)",
            ],
            in: observer,
            file: file,
            line: line
        )
    }

    private func assertAppearsInOrder(
        _ fragments: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = source.startIndex
        for fragment in fragments {
            guard let range = source.range(
                of: fragment,
                range: searchStart..<source.endIndex
            ) else {
                XCTFail(
                    "Expected source fragment after previous fragment: "
                        + fragment,
                    file: file,
                    line: line
                )
                return
            }
            searchStart = range.upperBound
        }
    }

    private func dockyPreferencesSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Docky")
            .appendingPathComponent("Services")
            .appendingPathComponent("DockyPreferences.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func didSetBody(
        for property: String,
        in source: String
    ) throws -> String {
        let signature = "    var \(property):"
        let signatureRange = try XCTUnwrap(
            source.range(of: signature),
            "Missing preference property \(property)"
        )
        let observerRange = try XCTUnwrap(
            source.range(
                of: "        didSet {",
                range: signatureRange.lowerBound..<source.endIndex
            ),
            "Missing didSet for \(property)"
        )
        let openingBrace = try XCTUnwrap(
            source[observerRange.lowerBound...].firstIndex(of: "{")
        )

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(
                        source[
                            source.index(after: openingBrace)..<index
                        ]
                    )
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        XCTFail("Could not find didSet end for \(property)")
        return ""
    }

    private func normalizedBundleIdentifiers(
        _ identifiers: [String]
    ) -> [String] {
        Array(Set(identifiers.filter { !$0.isEmpty })).sorted()
    }
}
