import XCTest

final class MediaRemoteProcessLifecycleTests: XCTestCase {
    private let command = MediaRemoteAdapterCommand(
        executablePath: "/usr/bin/perl",
        scriptPath:
            "/Applications/Docky.app/Contents/Resources/mediaremote-adapter.pl",
        frameworkPath:
            "/Applications/Docky.app/Contents/Frameworks/MediaRemoteAdapter.framework"
    )

    func testOrphanMatcherRequiresExactFullCommandAndInitParent() {
        let exact = MediaRemoteProcessSnapshot(
            processIdentifier: 123,
            parentProcessIdentifier: 1,
            executablePath: command.executablePath,
            arguments: command.arguments
        )

        XCTAssertTrue(
            MediaRemoteOrphanProcessPolicy.matchesOrphan(
                exact,
                command: command
            )
        )

        let currentChild = MediaRemoteProcessSnapshot(
            processIdentifier: 123,
            parentProcessIdentifier: 99,
            executablePath: command.executablePath,
            arguments: command.arguments
        )
        XCTAssertFalse(
            MediaRemoteOrphanProcessPolicy.matchesOrphan(
                currentChild,
                command: command
            )
        )

        let otherApplication = MediaRemoteProcessSnapshot(
            processIdentifier: 123,
            parentProcessIdentifier: 1,
            executablePath: command.executablePath,
            arguments: [
                command.executablePath,
                "/Applications/Other.app/Contents/Resources/mediaremote-adapter.pl",
                command.frameworkPath,
                "stream",
            ]
        )
        XCTAssertFalse(
            MediaRemoteOrphanProcessPolicy.matchesOrphan(
                otherApplication,
                command: command
            )
        )

        let extraArgument = MediaRemoteProcessSnapshot(
            processIdentifier: 123,
            parentProcessIdentifier: 1,
            executablePath: command.executablePath,
            arguments: command.arguments + ["--no-diff"]
        )
        XCTAssertFalse(
            MediaRemoteOrphanProcessPolicy.matchesOrphan(
                extraArgument,
                command: command
            )
        )

        let initItself = MediaRemoteProcessSnapshot(
            processIdentifier: 1,
            parentProcessIdentifier: 1,
            executablePath: command.executablePath,
            arguments: command.arguments
        )
        XCTAssertFalse(
            MediaRemoteOrphanProcessPolicy.matchesOrphan(
                initItself,
                command: command
            )
        )
    }

    func testStaleTerminationCannotClearReplacementGeneration() throws {
        var state = MediaRemoteProcessLifecycleState()
        let first = try XCTUnwrap(state.beginLaunch())
        let replacement = try XCTUnwrap(state.beginLaunch())

        XCTAssertFalse(state.acceptTermination(generation: first))
        XCTAssertEqual(state.activeGeneration, replacement)
        XCTAssertTrue(state.acceptTermination(generation: replacement))
        XCTAssertNil(state.activeGeneration)
    }

    func testShutdownIsIdempotentAndPreventsRelaunch() throws {
        var state = MediaRemoteProcessLifecycleState()
        _ = try XCTUnwrap(state.beginLaunch())

        XCTAssertTrue(state.beginShutdown())
        XCTAssertFalse(state.beginShutdown())
        XCTAssertNil(state.beginLaunch())
        XCTAssertNil(state.activeGeneration)
    }

    func testTerminationStopsAndReapsAfterTerm() {
        var running = true
        var termCount = 0
        var killCount = 0
        var reapCount = 0
        var pollCount = 0

        let outcome = MediaRemoteProcessTerminator.terminate(
            using: MediaRemoteTerminationOperations(
                isRunning: { running },
                requestTermination: { termCount += 1 },
                forceTermination: { killCount += 1 },
                reap: { reapCount += 1 },
                pause: { _ in
                    pollCount += 1
                    if pollCount == 2 {
                        running = false
                    }
                }
            ),
            gracefulPollLimit: 3,
            forcedPollLimit: 3
        )

        XCTAssertEqual(outcome, .terminated)
        XCTAssertEqual(termCount, 1)
        XCTAssertEqual(killCount, 0)
        XCTAssertEqual(reapCount, 1)
    }

    func testTerminationEscalatesToKillThenReaps() {
        var running = true
        var termCount = 0
        var killCount = 0
        var reapCount = 0

        let outcome = MediaRemoteProcessTerminator.terminate(
            using: MediaRemoteTerminationOperations(
                isRunning: { running },
                requestTermination: { termCount += 1 },
                forceTermination: {
                    killCount += 1
                    running = false
                },
                reap: { reapCount += 1 },
                pause: { _ in }
            ),
            gracefulPollLimit: 1,
            forcedPollLimit: 1
        )

        XCTAssertEqual(outcome, .forceKilled)
        XCTAssertEqual(termCount, 1)
        XCTAssertEqual(killCount, 1)
        XCTAssertEqual(reapCount, 1)
    }

    func testTerminationNeverReapsAStillRunningProcess() {
        var termCount = 0
        var killCount = 0
        var reapCount = 0

        let outcome = MediaRemoteProcessTerminator.terminate(
            using: MediaRemoteTerminationOperations(
                isRunning: { true },
                requestTermination: { termCount += 1 },
                forceTermination: { killCount += 1 },
                reap: { reapCount += 1 },
                pause: { _ in }
            ),
            gracefulPollLimit: 1,
            forcedPollLimit: 1
        )

        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertEqual(termCount, 1)
        XCTAssertEqual(killCount, 1)
        XCTAssertEqual(reapCount, 0)
    }

    func testAppTerminationDefersForHelperShutdownAndWillTerminateStartsIt()
        throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Docky/AppDelegate.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(
                "guard mediaPlayback.requiresShutdown else {"
            )
        )
        XCTAssertTrue(source.contains("return .terminateLater"))
        XCTAssertTrue(
            source.contains(
                "reply(toApplicationShouldTerminate: true)"
            )
        )

        let willTerminateStart = try XCTUnwrap(
            source.range(
                of:
                    "    func applicationWillTerminate(_ aNotification: Notification) {"
            )
        )
        let willTerminateEnd = try XCTUnwrap(
            source.range(
                of: "\n    }\n\n    func applicationDidBecomeActive",
                range: willTerminateStart.upperBound..<source.endIndex
            )
        )
        let body = source[
            willTerminateStart.upperBound..<willTerminateEnd.lowerBound
        ]
        let shutdown = try XCTUnwrap(
            body.range(
                of: "MediaPlaybackService.shared.shutdown()"
            )
        )
        let persistence = try XCTUnwrap(
            body.range(of: "ProfileService.shared.flushPersistence()")
        )
        XCTAssertLessThan(
            shutdown.lowerBound,
            persistence.lowerBound
        )
    }

    func testProductCleanupUsesExactKernelSnapshotsWithoutBroadProcessKill()
        throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent(
                    "Docky/Services/MediaPlaybackService.swift"
                ),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(
                "MediaRemoteOrphanProcessPolicy.matchesOrphan("
            )
        )
        XCTAssertTrue(source.contains("KERN_PROCARGS2"))
        XCTAssertTrue(source.contains("PROC_PIDTBSDINFO"))
        XCTAssertFalse(source.contains("pkill"))
        XCTAssertFalse(source.contains("killall"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
