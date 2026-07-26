import Foundation
import XCTest

final class ExternalWidgetRuntimePolicyTests: XCTestCase {
    func testLegacyRuntimeFailsClosed() {
        XCTAssertFalse(ExternalWidgetRuntimePolicy.allowsInstallation)
        XCTAssertFalse(ExternalWidgetRuntimePolicy.allowsExecution)
        XCTAssertFalse(ExternalWidgetRuntimePolicy.allowsRemoval)
        XCTAssertFalse(
            ExternalWidgetRuntimePolicy.acceptsInstallDeepLink(
                host: "install-widget"
            )
        )
    }

    func testRemovalIsLimitedToDirectNonSymlinkBundleChildren() {
        let directory = URL(
            fileURLWithPath: "/tmp/Docky/Widgets",
            isDirectory: true
        )
        let directBundle = directory.appendingPathComponent(
            "Clock.dockywidget",
            isDirectory: true
        )

        XCTAssertFalse(
            ExternalWidgetRuntimePolicy.mayRemoveBundle(
                candidate: directBundle,
                widgetsDirectory: directory,
                isSymbolicLink: false
            )
        )
        XCTAssertFalse(
            ExternalWidgetRuntimePolicy.mayRemoveBundle(
                candidate: directBundle,
                widgetsDirectory: directory,
                isSymbolicLink: true
            )
        )
        XCTAssertFalse(
            ExternalWidgetRuntimePolicy.mayRemoveBundle(
                candidate: directory.appendingPathComponent("notes.txt"),
                widgetsDirectory: directory,
                isSymbolicLink: false
            )
        )
        XCTAssertFalse(
            ExternalWidgetRuntimePolicy.mayRemoveBundle(
                candidate: directory
                    .appendingPathComponent("Nested", isDirectory: true)
                    .appendingPathComponent(
                        "Clock.dockywidget",
                        isDirectory: true
                    ),
                widgetsDirectory: directory,
                isSymbolicLink: false
            )
        )
        XCTAssertFalse(
            ExternalWidgetRuntimePolicy.mayRemoveBundle(
                candidate: URL(
                    fileURLWithPath: "/tmp/Other/Clock.dockywidget",
                    isDirectory: true
                ),
                widgetsDirectory: directory,
                isSymbolicLink: false
            )
        )
    }

    func testProductionLoaderDoesNotRecursivelyDeleteBundles() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Docky/Services/ExternalWidgetLoader.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("runtimeMutationDisabled"))
        XCTAssertFalse(source.contains("FileManager.default.removeItem"))
        XCTAssertFalse(source.contains("createIfMissing: true"))
    }

    func testDirectoryPreparationRejectsSymlinkedWidgetsDirectory()
        throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "DockyPolicyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: root.appendingPathComponent("Docky", isDirectory: true),
            withIntermediateDirectories: true
        )
        let unrelated = root.appendingPathComponent(
            "Unrelated",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: unrelated,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: root
                .appendingPathComponent("Docky", isDirectory: true)
                .appendingPathComponent("Widgets", isDirectory: true),
            withDestinationURL: unrelated
        )

        XCTAssertThrowsError(
            try ExternalWidgetRuntimePolicy.prepareWidgetsDirectory(
                applicationSupportDirectory: root,
                fileManager: fileManager,
                createIfMissing: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ExternalWidgetDirectoryPolicyError,
                .symbolicLink
            )
        }
    }

    func testDirectoryPreparationCreatesDirectPrivateDirectories()
        throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "DockyPolicyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let directory =
            try ExternalWidgetRuntimePolicy.prepareWidgetsDirectory(
                applicationSupportDirectory: root,
                fileManager: fileManager,
                createIfMissing: true
            )

        XCTAssertEqual(
            directory,
            root
                .appendingPathComponent("Docky", isDirectory: true)
                .appendingPathComponent("Widgets", isDirectory: true)
        )
        let attributes = try fileManager.attributesOfItem(
            atPath: directory.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
    }
}
