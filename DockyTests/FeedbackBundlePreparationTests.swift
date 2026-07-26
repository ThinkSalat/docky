import Darwin
import Foundation
import XCTest

final class FeedbackBundlePreparationTests: XCTestCase {
    func testNewPreparationGenerationInvalidatesOlderCompletion() {
        var generation = FeedbackPreparationGeneration()
        let first = generation.advance()
        let second = generation.advance()

        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testCancellationInvalidatesCurrentPreparationGeneration() {
        var generation = FeedbackPreparationGeneration()
        let request = generation.advance()

        generation.invalidate()

        XCTAssertFalse(generation.isCurrent(request))
    }

    func testPrivacyFilterIncludesOnlyDockyDefaults() {
        let filtered = FeedbackBundlePrivacy.dockyDefaults(from: [
            "docky.theme": "dark",
            "docky.profile": "work",
            "NSNavLastRootDirectory": "/Users/example/Private",
            "AppleLanguages": ["en"],
        ])

        XCTAssertEqual(Set(filtered.keys), ["docky.theme", "docky.profile"])
        XCTAssertEqual(filtered["docky.theme"] as? String, "dark")
    }

    func testTemporaryBundlePolicyRejectsNestedAndUnrelatedFiles() {
        let temporaryDirectory = URL(
            fileURLWithPath: "/tmp/docky-feedback-policy-tests",
            isDirectory: true
        )
        let container = FeedbackTemporaryArtifactPolicy.containerURL(
            temporaryDirectory: temporaryDirectory
        )
        let bundle = container.appendingPathComponent(
            "docky-feedback-123.zip"
        )
        let stagingDirectory = container.appendingPathComponent(
            "docky-feedback-123",
            isDirectory: true
        )
        let nested = container
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("docky-feedback-123.zip")
        let unrelated = container.appendingPathComponent(
            "someone-else.zip"
        )
        let legacyBundle = temporaryDirectory.appendingPathComponent(
            "docky-feedback-legacy.zip"
        )

        XCTAssertTrue(
            FeedbackTemporaryArtifactPolicy.isOwnedBundle(
                bundle,
                temporaryDirectory: temporaryDirectory
            )
        )
        XCTAssertTrue(
            FeedbackTemporaryArtifactPolicy.isDirectTemporaryArtifact(
                stagingDirectory,
                temporaryDirectory: temporaryDirectory
            )
        )
        XCTAssertFalse(
            FeedbackTemporaryArtifactPolicy.isOwnedBundle(
                stagingDirectory,
                temporaryDirectory: temporaryDirectory
            )
        )
        XCTAssertFalse(
            FeedbackTemporaryArtifactPolicy.isOwnedBundle(
                nested,
                temporaryDirectory: temporaryDirectory
            )
        )
        XCTAssertFalse(
            FeedbackTemporaryArtifactPolicy.isOwnedBundle(
                unrelated,
                temporaryDirectory: temporaryDirectory
            )
        )
        XCTAssertTrue(
            FeedbackTemporaryArtifactPolicy.isOwnedBundle(
                legacyBundle,
                temporaryDirectory: temporaryDirectory
            )
        )
    }

    func testStaleCleanupScansOwnedContainerAndPreservesFreshFiles() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let container = FeedbackTemporaryArtifactPolicy.containerURL(
            temporaryDirectory: fixture
        )
        let staleBundle = container.appendingPathComponent(
            "docky-feedback-stale.zip"
        )
        let staleStaging = container.appendingPathComponent(
            "docky-feedback-stale",
            isDirectory: true
        )
        let freshBundle = container.appendingPathComponent(
            "docky-feedback-fresh.zip"
        )
        let legacyStaleBundle = fixture.appendingPathComponent(
            "docky-feedback-legacy.zip"
        )
        try FileManager.default.createDirectory(
            at: staleStaging,
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: staleBundle)
        try Data("nested".utf8).write(
            to: staleStaging.appendingPathComponent("nested.txt")
        )
        try Data("fresh".utf8).write(to: freshBundle)
        try Data("legacy".utf8).write(to: legacyStaleBundle)
        let staleDate = Date().addingTimeInterval(-90_000)
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: staleBundle.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: staleStaging.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: legacyStaleBundle.path
        )

        FeedbackBundleWorker.cleanupStaleTemporaryArtifacts(
            temporaryDirectory: fixture
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleBundle.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleStaging.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshBundle.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyStaleBundle.path)
        )
    }

    func testBundlePreparationFailsClosedWithoutLaunchingArchiver() async {
        let snapshot = FeedbackBundleSnapshot(
            feedbackText: "feedback",
            dockyDefaultsPlist: Data(),
            dockPlist: nil,
            systemJSON: Data(),
            attachmentURL: nil,
            diagnostics: FeedbackDiagnosticsSnapshot { _ in }
        )

        do {
            _ = try await FeedbackBundleWorker.shared.prepare(snapshot)
            XCTFail("Expected secure archive fail-closed error")
        } catch let error as FeedbackBundleWorkerError {
            guard case .secureArchiveUnavailable = error else {
                return XCTFail("Unexpected worker error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAttachmentCopyUsesFixedNameAndPreservesBytes() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let staging = fixture.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let source = fixture.appendingPathComponent(
            "private customer filename.txt"
        )
        let expected = Data("attachment".utf8)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try expected.write(to: source)

        let destination =
            try FeedbackBundleWorker.stageAttachmentSynchronously(
                from: source,
                in: staging,
                cancellation: FeedbackProcessCancellation()
            )

        XCTAssertEqual(
            destination.lastPathComponent,
            FeedbackBundleWorker.attachmentFileName
        )
        XCTAssertFalse(
            destination.lastPathComponent.contains(
                source.deletingPathExtension().lastPathComponent
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), expected)
    }

    func testAttachmentCopyRejectsOversizeInputWithoutPartialFile() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let staging = fixture.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let source = fixture.appendingPathComponent("attachment.bin")
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 9).write(to: source)

        XCTAssertThrowsError(
            try FeedbackBundleWorker.stageAttachmentSynchronously(
                from: source,
                in: staging,
                maximumBytes: 8,
                cancellation: FeedbackProcessCancellation()
            )
        ) { error in
            guard let workerError = error as? FeedbackBundleWorkerError,
                  case .attachmentTooLarge(let maximumBytes) = workerError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maximumBytes, 8)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staging.appendingPathComponent(
                    FeedbackBundleWorker.attachmentFileName
                ).path
            )
        )
    }

    func testAttachmentCopyRejectsSymlinkFIFODeviceAndDirectory() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let staging = fixture.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let regular = fixture.appendingPathComponent("regular.bin")
        let symlink = fixture.appendingPathComponent("symlink.bin")
        let fifo = fixture.appendingPathComponent("named-pipe.bin")
        let directory = fixture.appendingPathComponent(
            "directory.bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("attachment".utf8).write(to: regular)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: regular
        )
        XCTAssertEqual(
            fifo.path.withCString { Darwin.mkfifo($0, 0o600) },
            0
        )

        for source in [
            symlink,
            fifo,
            URL(fileURLWithPath: "/dev/null"),
            directory,
        ] {
            XCTAssertThrowsError(
                try FeedbackBundleWorker.stageAttachmentSynchronously(
                    from: source,
                    in: staging,
                    cancellation: FeedbackProcessCancellation()
                ),
                "Expected to reject \(source.path)"
            ) { error in
                guard let workerError =
                    error as? FeedbackBundleWorkerError,
                    case .invalidAttachment = workerError
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testCancelledAttachmentCopyRemovesPartialFile() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let staging = fixture.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let source = fixture.appendingPathComponent("attachment.bin")
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 128 * 1_024).write(to: source)
        let cancellation = FeedbackProcessCancellation()

        XCTAssertThrowsError(
            try FeedbackBundleWorker.stageAttachmentSynchronously(
                from: source,
                in: staging,
                cancellation: cancellation
            ) { _ in
                cancellation.cancel()
            }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staging.appendingPathComponent(
                    FeedbackBundleWorker.attachmentFileName
                ).path
            )
        )
    }

    func testProcessRunnerDrainsAndBoundsStandardError() async throws {
        let cancellation = FeedbackProcessCancellation()
        let script = #"""
        i=0
        while [ "$i" -lt 4096 ]; do
            printf '0123456789abcdef0123456789abcdef\n' >&2
            i=$((i + 1))
        done
        """#
        let result = try await Task.detached(priority: .utility) {
            try FeedbackBoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                timeout: 5,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 4_096,
                cancellation: cancellation
            )
        }.value

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardError.count, 4_096)
        XCTAssertTrue(result.standardErrorWasTruncated)
    }

    func testProcessRunnerTimesOutWithoutWaitingForNaturalExit() async {
        let started = Date()
        do {
            _ = try await Task.detached(priority: .utility) {
                try FeedbackBoundedProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"],
                    timeout: 0.1,
                    maximumStandardOutputBytes: 1_024,
                    maximumStandardErrorBytes: 1_024,
                    cancellation: FeedbackProcessCancellation()
                )
            }.value
            XCTFail("Expected the process to time out")
        } catch let error as FeedbackProcessError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testProcessRunnerRespondsToCooperativeCancellation() async {
        let cancellation = FeedbackProcessCancellation()
        let task = Task.detached(priority: .utility) {
            try FeedbackBoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 10,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024,
                cancellation: cancellation
            )
        }

        try? await Task.sleep(for: .milliseconds(100))
        cancellation.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFeedbackUIFailsClosedWithoutBreakingTextOnlyFeedback() throws {
        let viewSource = try sourceFile(
            "Docky/Views/SettingsWindow/FeedbackSettingsView.swift"
        )
        let workerSource = try sourceFile(
            "Docky/Services/FeedbackBundleWorker.swift"
        )
        let processSource = try sourceFile(
            "Docky/Services/FeedbackBoundedProcessRunner.swift"
        )

        XCTAssertTrue(
            viewSource.contains(
                "@MainActor\nprivate enum FeedbackBundleCapture"
            )
        )
        XCTAssertFalse(
            viewSource.contains(
                "try await FeedbackBundleCaptureBuilder.snapshot("
            ),
            "Fail-closed UI must not stage private diagnostics before rejecting export."
        )
        XCTAssertTrue(
            viewSource.contains(
                "Task<FeedbackBundleSnapshot, Error> = Task.detached("
            )
        )
        XCTAssertFalse(
            viewSource.contains(
                "snapshot = try FeedbackBundleCapture.snapshot("
            )
        )
        XCTAssertFalse(viewSource.contains("await worker.prepare(snapshot)"))
        XCTAssertFalse(viewSource.contains("await worker.prepareAndSave("))
        XCTAssertTrue(viewSource.contains("Save Diagnostic Bundle…"))
        XCTAssertTrue(viewSource.contains(".disabled(true)"))
        XCTAssertTrue(viewSource.contains("present(items: items)"))
        XCTAssertTrue(viewSource.contains("items.append(attachmentURL as NSURL)"))
        XCTAssertTrue(viewSource.contains("makeExportSource()"))

        XCTAssertTrue(workerSource.contains("workerQueue.async {"))
        XCTAssertTrue(
            workerSource.contains("guard !Thread.isMainThread else")
        )
        XCTAssertTrue(workerSource.contains("secureArchiveUnavailable"))
        XCTAssertTrue(
            workerSource.contains(
                "Fail closed until an"
            )
        )
        XCTAssertFalse(workerSource.contains("/usr/bin/ditto"))
        XCTAssertFalse(
            workerSource.contains("snapshot.diagnostics.copy(")
        )
        XCTAssertFalse(workerSource.contains("secureFile(at:"))
        XCTAssertFalse(workerSource.contains("copyItem(at:"))
        XCTAssertFalse(workerSource.contains("NSScreen.screens"))
        XCTAssertTrue(processSource.contains("outputDrain.start(in: drainGroup)"))
        XCTAssertTrue(processSource.contains("errorDrain.start(in: drainGroup)"))
        XCTAssertTrue(processSource.contains("FeedbackProcessError.timedOut"))
        XCTAssertTrue(processSource.contains("Darwin.kill("))
        XCTAssertTrue(
            processSource.contains(
                "drainGroup.wait(timeout: .now() + 2)"
            )
        )
        XCTAssertFalse(viewSource.contains("waitUntilExit()"))
        XCTAssertFalse(workerSource.contains("waitUntilExit()"))
        XCTAssertFalse(processSource.contains("waitUntilExit()"))

        let stopDrains = try XCTUnwrap(
            processSource.range(of: "stopDrains(\n")
        )
        let wouldNotTerminate = try XCTUnwrap(
            processSource.range(
                of: "throw FeedbackProcessError.wouldNotTerminate"
            )
        )
        XCTAssertLessThan(
            stopDrains.lowerBound,
            wouldNotTerminate.lowerBound,
            "Pipe readers must be stopped before this terminal error escapes."
        )

        let outputDrain = try XCTUnwrap(
            processSource.range(of: "outputDrain.start(in: drainGroup)")
        )
        let processRun = try XCTUnwrap(
            processSource.range(of: "try process.run()")
        )
        XCTAssertLessThan(
            outputDrain.lowerBound,
            processRun.lowerBound,
            "Pipe readers must start before the child can fill either pipe."
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DockyFeedbackBundleTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
