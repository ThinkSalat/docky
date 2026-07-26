import Foundation
import XCTest

final class AXRequestGenerationTests: XCTestCase {
    private enum Scope: Hashable, Sendable {
        case all
        case process(Int32)
    }

    private struct SnapshotValue: Identifiable, Equatable {
        let id: String
        let version: Int
    }

    private struct RegistrationKey: Hashable, Sendable {
        let lifecycle: Int
        let notification: String
    }

    func testNewGenerationMakesOlderResultStale() {
        var tracker = AXRequestGenerationTracker<Scope>()
        let first = tracker.issue(for: .process(42))
        let second = tracker.issue(for: .process(42))

        XCTAssertFalse(tracker.isCurrent(first, for: .process(42)))
        XCTAssertTrue(tracker.isCurrent(second, for: .process(42)))
    }

    func testGenerationsAreIndependentAcrossScopes() {
        var tracker = AXRequestGenerationTracker<Scope>()
        let all = tracker.issue(for: .all)
        let process = tracker.issue(for: .process(42))

        XCTAssertTrue(tracker.isCurrent(all, for: .all))
        XCTAssertTrue(tracker.isCurrent(process, for: .process(42)))

        _ = tracker.issue(for: .process(42))
        XCTAssertTrue(tracker.isCurrent(all, for: .all))
        XCTAssertFalse(tracker.isCurrent(process, for: .process(42)))
    }

    func testQueueKeepsOnlyNewestPendingRequestPerScope() {
        var queue = AXCoalescingRequestQueue<Scope, String>()
        queue.enqueue(
            key: .process(42),
            generation: AXRequestGeneration(rawValue: 1),
            payload: "old"
        )
        queue.enqueue(
            key: .process(42),
            generation: AXRequestGeneration(rawValue: 2),
            payload: "new"
        )

        XCTAssertEqual(queue.count, 1)
        let request = queue.dequeue()
        XCTAssertEqual(request?.generation.rawValue, 2)
        XCTAssertEqual(request?.payload, "new")
        XCTAssertTrue(queue.isEmpty)
    }

    func testQueuePreservesFirstPendingOrderAcrossDifferentScopes() {
        var queue = AXCoalescingRequestQueue<Scope, String>()
        queue.enqueue(
            key: .process(1),
            generation: AXRequestGeneration(rawValue: 1),
            payload: "one"
        )
        queue.enqueue(
            key: .process(2),
            generation: AXRequestGeneration(rawValue: 2),
            payload: "two"
        )
        queue.enqueue(
            key: .process(1),
            generation: AXRequestGeneration(rawValue: 3),
            payload: "one-new"
        )

        XCTAssertEqual(queue.dequeue()?.payload, "one-new")
        XCTAssertEqual(queue.dequeue()?.payload, "two")
    }

    func testCancelDropsOnlyTargetScope() {
        var queue = AXCoalescingRequestQueue<Scope, String>()
        queue.enqueue(
            key: .process(1),
            generation: AXRequestGeneration(rawValue: 1),
            payload: "one"
        )
        queue.enqueue(
            key: .process(2),
            generation: AXRequestGeneration(rawValue: 2),
            payload: "two"
        )

        queue.cancel(.process(1))

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.dequeue()?.payload, "two")
    }

    func testNotificationRegistrationTerminalOutcomesDoNotRetry() throws {
        let key = RegistrationKey(
            lifecycle: 1,
            notification: "created"
        )
        let outcomes: [
            (
                AXNotificationRegistrationOutcome,
                AXNotificationRegistrationRetryState<
                    RegistrationKey
                >.Resolution
            )
        ] = [
            (.registered, .completed),
            (.alreadyRegistered, .completed),
            (.unsupported, .unsupported),
            (.terminalFailure, .terminalFailure),
        ]

        for (outcome, expectedResolution) in outcomes {
            var state =
                AXNotificationRegistrationRetryState<RegistrationKey>(
                    retryDelays: [0.1]
                )
            state.enqueue(key, now: 0)
            let attempt = try XCTUnwrap(state.nextReady(now: 0))

            XCTAssertEqual(
                state.resolve(attempt, outcome: outcome, now: 0),
                expectedResolution
            )
            XCTAssertTrue(state.isEmpty)
            XCTAssertNil(state.nextDeadline)
        }
    }

    func testNotificationRegistrationBackoffIsNonzeroBoundedAndExhausts()
        throws {
        let key = RegistrationKey(
            lifecycle: 1,
            notification: "moved"
        )
        var state =
            AXNotificationRegistrationRetryState<RegistrationKey>(
                retryDelays: [0.1, 0.25]
            )
        state.enqueue(key, now: 10)

        let first = try XCTUnwrap(state.nextReady(now: 10))
        XCTAssertEqual(
            state.resolve(
                first,
                outcome: .cannotComplete,
                now: 10
            ),
            .retryScheduled(deadline: 10.1)
        )
        XCTAssertNil(state.nextReady(now: 10.099))

        let second = try XCTUnwrap(state.nextReady(now: 10.1))
        XCTAssertEqual(second.attemptIndex, 1)
        XCTAssertEqual(
            state.resolve(
                second,
                outcome: .cannotComplete,
                now: 10.1
            ),
            .retryScheduled(deadline: 10.35)
        )
        XCTAssertNil(state.nextReady(now: 10.349))

        let third = try XCTUnwrap(state.nextReady(now: 10.35))
        XCTAssertEqual(third.attemptIndex, 2)
        XCTAssertEqual(
            state.resolve(
                third,
                outcome: .cannotComplete,
                now: 10.35
            ),
            .exhausted
        )
        XCTAssertTrue(state.isEmpty)
    }

    func testNotificationRegistrationGenerationCancellationAndDeadlineOrder()
        throws {
        let oldKey = RegistrationKey(
            lifecycle: 1,
            notification: "created"
        )
        let siblingKey = RegistrationKey(
            lifecycle: 1,
            notification: "destroyed"
        )
        let otherLifecycleKey = RegistrationKey(
            lifecycle: 2,
            notification: "created"
        )
        var state =
            AXNotificationRegistrationRetryState<RegistrationKey>(
                retryDelays: [1]
            )

        state.enqueue(oldKey, now: 0)
        let staleAttempt = try XCTUnwrap(state.nextReady(now: 0))
        let replacementGeneration = state.enqueue(oldKey, now: 0.2)
        XCTAssertEqual(
            state.resolve(
                staleAttempt,
                outcome: .registered,
                now: 0.2
            ),
            .stale
        )
        XCTAssertEqual(
            try XCTUnwrap(state.nextReady(now: 0.2)).generation,
            replacementGeneration
        )

        // Rebuild a delayed queue to prove the earliest wake wins and a
        // lifecycle cancellation removes only its own registrations.
        state.cancelAll()
        state.enqueue(oldKey, now: 0)
        let delayed = try XCTUnwrap(state.nextReady(now: 0))
        XCTAssertEqual(
            state.resolve(
                delayed,
                outcome: .cannotComplete,
                now: 0
            ),
            .retryScheduled(deadline: 1)
        )
        state.enqueue(siblingKey, now: 0.5)
        state.enqueue(otherLifecycleKey, now: 0.75)
        XCTAssertEqual(state.nextDeadline, 0.5)

        state.cancel { $0.lifecycle == 1 }
        XCTAssertEqual(state.nextDeadline, 0.75)
        XCTAssertEqual(
            try XCTUnwrap(state.nextReady(now: 0.75)).key,
            otherLifecycleKey
        )
    }

    func testWorkerRetriesOnlyCannotCompleteWithOneDelayedWake()
        throws {
        let source = try sourceFile(
            "Docky/Services/AXWindowWorker.swift"
        )
        let drain = try sourceSection(
            in: source,
            startingAt: "    private func drainOneObserverRegistration()",
            endingAt: "    private func removeObserver(for pid:"
        )
        XCTAssertTrue(
            drain.contains(
                "let status = AXObserverAddNotification("
            )
        )
        XCTAssertTrue(
            drain.contains(
                "notificationRegistrationOutcome(for: status)"
            )
        )
        XCTAssertFalse(
            drain.contains("_ = AXObserverAddNotification(")
        )

        let scheduling = try sourceSection(
            in: source,
            startingAt:
                "    private func notificationRegistrationOutcome(",
            endingAt: "    private func pid(for observer:"
        )
        XCTAssertTrue(scheduling.contains("case .cannotComplete:"))
        XCTAssertTrue(scheduling.contains("case .notificationUnsupported:"))
        XCTAssertTrue(
            scheduling.contains("CFRunLoopTimerCreateWithHandler(")
        )
        XCTAssertTrue(
            scheduling.contains(
                "observerRegistrationWakeDeadline"
            )
        )
    }

    func testInterruptedRequestCanRestartWithoutLosingOriginalInputs() {
        var state = AXRestartableRequestState<String, Int>()
        state.begin(
            generation: AXRequestGeneration(rawValue: 1),
            payload: "global-request",
            units: [1, 2, 3]
        )

        let restarted = state.restart(
            generation: AXRequestGeneration(rawValue: 2)
        )

        XCTAssertEqual(restarted?.payload, "global-request")
        XCTAssertEqual(restarted?.units, [1, 2, 3])
        XCTAssertEqual(state.current?.generation.rawValue, 2)
    }

    func testAbandonedCompletionCannotClearRestartedRequest() {
        var state = AXRestartableRequestState<String, Int>()
        state.begin(
            generation: AXRequestGeneration(rawValue: 1),
            payload: "global-request",
            units: [1, 2]
        )
        _ = state.restart(
            generation: AXRequestGeneration(rawValue: 2),
            units: [2]
        )

        state.complete(generation: AXRequestGeneration(rawValue: 1))
        XCTAssertEqual(state.current?.generation.rawValue, 2)
        XCTAssertEqual(state.current?.units, [2])

        state.complete(generation: AXRequestGeneration(rawValue: 2))
        XCTAssertNil(state.current)
    }

    func testRetiringOneProcessRestartsGlobalRequestForRemainingUnits() {
        var state = AXRestartableRequestState<String, Int>()
        state.begin(
            generation: AXRequestGeneration(rawValue: 1),
            payload: "global-request",
            units: [41, 42, 43]
        )

        let remaining = state.current?.units.filter { $0 != 42 } ?? []
        let restarted = state.restart(
            generation: AXRequestGeneration(rawValue: 2),
            units: remaining
        )

        XCTAssertEqual(restarted?.payload, "global-request")
        XCTAssertEqual(restarted?.units, [41, 43])
        state.complete(generation: AXRequestGeneration(rawValue: 1))
        XCTAssertEqual(state.current?.generation.rawValue, 2)
    }

    func testTargetedAndLifecycleInvalidationsRestartGlobalWorkerScan()
        throws {
        let source = try sourceFile(
            "Docky/Services/AXWindowWorker.swift"
        )
        let enqueueSnapshot = try sourceSection(
            in: source,
            startingAt: "    private func enqueueSnapshot(",
            endingAt:
                "    @discardableResult\n"
                + "    private func cancelGlobalPlanPreservingRestartRequest"
        )
        XCTAssertTrue(
            enqueueSnapshot.contains(
                "cancelGlobalPlanPreservingRestartRequest()"
            )
        )
        XCTAssertTrue(
            enqueueSnapshot.contains("enqueueRestartedGlobalSnapshot()")
        )

        let cancellation = try sourceSection(
            in: source,
            startingAt: "    private func cancelSnapshotWork(",
            endingAt: "    private func discoverWindowElements("
        )
        XCTAssertTrue(
            cancellation.contains(
                "cancelGlobalPlanPreservingRestartRequest()"
            )
        )
        XCTAssertTrue(
            cancellation.contains("enqueueRestartedGlobalSnapshot(")
        )
        XCTAssertFalse(
            cancellation.contains("restartableGlobalSnapshot.cancel()")
        )
    }

    func testLifecycleChangesIssueAReplacementFullSnapshot() throws {
        let source = try sourceFile(
            "Docky/Services/WindowRegistry.swift"
        )
        let boundaries = [
            (
                "    private func handleAppLaunched(",
                "    private func handleAppTerminated("
            ),
            (
                "    private func handleAppTerminated(",
                "    private func handleAppHidden("
            ),
            (
                "    private func handleAppHidden(",
                "    private func handleAppUnhidden("
            ),
            (
                "    private func handleAppUnhidden(",
                "    private func requestFullSnapshot()"
            ),
        ]

        for (start, end) in boundaries {
            let section = try sourceSection(
                in: source,
                startingAt: start,
                endingAt: end
            )
            XCTAssertTrue(
                section.contains("requestFullSnapshot()"),
                "Lifecycle handler \(start) can invalidate a Space scan only if it schedules its replacement."
            )
        }
    }

    func testEveryWindowMutationChecksCancellationAndLifecycleAfterAwait()
        throws {
        let source = try sourceFile(
            "Docky/Services/WindowRegistry.swift"
        )
        let sections = [
            try sourceSection(
                in: source,
                startingAt:
                    "    func minimize(_ window: AppWindow) async -> Bool {",
                endingAt:
                    "    @discardableResult\n"
                    + "    func close(_ window: AppWindow) async -> Bool {"
            ),
            try sourceSection(
                in: source,
                startingAt:
                    "    func close(_ window: AppWindow) async -> Bool {",
                endingAt:
                    "    @discardableResult\n"
                    + "    func zoom(_ window: AppWindow) async -> Bool {"
            ),
            try sourceSection(
                in: source,
                startingAt:
                    "    func zoom(_ window: AppWindow) async -> Bool {",
                endingAt:
                    "    @discardableResult\n"
                    + "    func resize("
            ),
            try sourceSection(
                in: source,
                startingAt:
                    "    func resize(",
                endingAt: "    private func scheduleResizePostCheck("
            ),
        ]

        for section in sections {
            let awaitRange = try XCTUnwrap(
                section.range(of: "await axWorker.perform")
            )
            let completionPath = section[awaitRange.upperBound...]
            XCTAssertTrue(
                completionPath.contains(
                    "AXActionExecutionPolicy.shouldProceed"
                )
            )
            XCTAssertTrue(completionPath.contains("Task.isCancelled"))
            XCTAssertTrue(
                completionPath.contains(
                    "applicationLifecycles.isCurrent(window.lifecycle)"
                )
            )
        }
    }

    func testUserCommandOutranksEarlierBackgroundCommand() {
        var queue = AXPriorityCommandQueue<String>()
        queue.enqueue("snapshot", priority: .background)
        queue.enqueue("focus-click", priority: .user)

        XCTAssertEqual(queue.dequeue(), "focus-click")
        XCTAssertEqual(queue.dequeue(), "snapshot")
        XCTAssertTrue(queue.isEmpty)
    }

    func testCooperativeSchedulerYieldsOneUnitAtATime() {
        var scheduler = AXCooperativeWorkScheduler<Scope, Int, String>()
        let generation = AXRequestGeneration(rawValue: 1)
        scheduler.enqueue(
            key: .all,
            generation: generation,
            payload: "scan",
            units: [1, 2, 3]
        )

        let first = scheduler.nextSlice()
        XCTAssertEqual(first?.unit, 1)
        XCTAssertEqual(first?.isLast, false)

        // The caller returns to its executor here, giving a queued user action
        // a chance to run before explicitly requesting the next scan slice.
        let second = scheduler.nextSlice()
        XCTAssertEqual(second?.unit, 2)
        XCTAssertEqual(second?.isLast, false)
        XCTAssertEqual(scheduler.nextSlice()?.unit, 3)
    }

    func testReplacingActivePlanStopsItsRemainingUnits() {
        var scheduler = AXCooperativeWorkScheduler<Scope, Int, String>()
        let oldGeneration = AXRequestGeneration(rawValue: 1)
        scheduler.enqueue(
            key: .all,
            generation: oldGeneration,
            payload: "old",
            units: [1, 2, 3]
        )
        let oldSlice = scheduler.nextSlice()!

        let newGeneration = AXRequestGeneration(rawValue: 2)
        scheduler.enqueue(
            key: .all,
            generation: newGeneration,
            payload: "new",
            units: [9]
        )

        XCTAssertFalse(scheduler.isCurrent(oldSlice))
        let replacement = scheduler.nextSlice()
        XCTAssertEqual(replacement?.payload, "new")
        XCTAssertEqual(replacement?.unit, 9)
        XCTAssertEqual(replacement?.isLast, true)
    }

    func testDiscoverySliceCanExpandIntoYieldedChildUnits() {
        var scheduler = AXCooperativeWorkScheduler<Scope, Int, String>()
        let generation = AXRequestGeneration(rawValue: 1)
        scheduler.enqueue(
            key: .all,
            generation: generation,
            payload: "scan",
            units: [1, 99]
        )

        let discovery = scheduler.nextSlice()!
        XCTAssertTrue(
            scheduler.insertAfterCurrentSlice(
                [2, 3],
                for: discovery
            )
        )
        XCTAssertFalse(scheduler.isComplete(after: discovery))
        XCTAssertEqual(scheduler.nextSlice()?.unit, 2)
        XCTAssertEqual(scheduler.nextSlice()?.unit, 3)
        XCTAssertEqual(scheduler.nextSlice()?.unit, 99)
    }

    func testWindowIdentityStringUsesUniqueWorkerToken() {
        let first = AXWindowIdentityString.make(
            processIdentifier: 42,
            token: 1,
            cgWindowID: 900
        )
        let second = AXWindowIdentityString.make(
            processIdentifier: 42,
            token: 2,
            cgWindowID: 900
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, "ax:42:1:cg:900")
    }

    func testMatchingCGWindowIDAloneCannotRebindStaleWindow() {
        let previous = rebindEvidence(cgWindowID: 900)
        let soleCandidate = rebindEvidence(cgWindowID: 900)

        XCTAssertNil(
            AXWindowRebindMatcher.uniqueCandidateIndex(
                previous: previous,
                candidates: [soleCandidate]
            )
        )
    }

    func testSoleReplacementNeedsTwoCorroboratingStableAttributes() {
        let previous = rebindEvidence(
            cgWindowID: 900,
            title: "Document",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600)
        )
        let titleOnly = rebindEvidence(
            cgWindowID: 900,
            title: "Document"
        )

        XCTAssertNil(
            AXWindowRebindMatcher.uniqueCandidateIndex(
                previous: previous,
                candidates: [titleOnly]
            )
        )
    }

    func testTitleAndFrameAloneCannotRebindReplacementProxy() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let previous = rebindEvidence(
            cgWindowID: 900,
            title: "Document",
            frame: frame
        )
        let replacement = rebindEvidence(
            cgWindowID: 900,
            title: "Document",
            frame: frame
        )

        XCTAssertFalse(
            AXWindowRebindMatcher.isCorroboratedMatch(
                previous: previous,
                candidate: replacement
            )
        )
    }

    func testUniqueCandidateWithThreeStableCorroboratorsCanRebind() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let previous = rebindEvidence(
            cgWindowID: 900,
            windowNumber: 77,
            title: "Document",
            frame: frame
        )
        let unrelated = rebindEvidence(
            cgWindowID: 901,
            windowNumber: 77,
            title: "Document",
            frame: frame
        )
        let corroborated = rebindEvidence(
            cgWindowID: 900,
            windowNumber: 77,
            title: "Document",
            frame: frame.offsetBy(dx: 1, dy: -1)
        )

        XCTAssertEqual(
            AXWindowRebindMatcher.uniqueCandidateIndex(
                previous: previous,
                candidates: [unrelated, corroborated]
            ),
            1
        )
    }

    func testConflictingStableEvidenceRejectsReusedCGWindowID() {
        let previous = rebindEvidence(
            cgWindowID: 900,
            windowNumber: 77,
            title: "Original",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600)
        )
        let reused = rebindEvidence(
            cgWindowID: 900,
            windowNumber: 77,
            title: "Replacement",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600)
        )

        XCTAssertFalse(
            AXWindowRebindMatcher.isCorroboratedMatch(
                previous: previous,
                candidate: reused
            )
        )
    }

    func testAmbiguousCorroboratedCandidatesFailClosed() {
        let previous = rebindEvidence(
            windowNumber: 77,
            title: "Untitled",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let candidate = rebindEvidence(
            windowNumber: 77,
            title: "Untitled",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertNil(
            AXWindowRebindMatcher.uniqueCandidateIndex(
                previous: previous,
                candidates: [candidate, candidate]
            )
        )
    }

    func testGlobalAssignmentNeverLetsDuplicateCandidatesReusePriorID() {
        let previous = rebindEvidence(
            windowNumber: 77,
            title: "Untitled",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let duplicate = rebindEvidence(
            windowNumber: 77,
            title: "Untitled",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertTrue(
            AXWindowRebindMatcher.globallyUniqueAssignments(
                previous: [previous],
                candidates: [duplicate, duplicate]
            ).isEmpty
        )
    }

    func testGlobalAssignmentAcceptsOnlyUniqueOneToOneComponents() {
        let first = rebindEvidence(
            windowNumber: 11,
            title: "First",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let second = rebindEvidence(
            windowNumber: 22,
            title: "Second",
            frame: CGRect(x: 50, y: 50, width: 900, height: 700)
        )

        XCTAssertEqual(
            AXWindowRebindMatcher.globallyUniqueAssignments(
                previous: [first, second],
                candidates: [second, first]
            ),
            [0: 1, 1: 0]
        )
    }

    func testAlternativeGlobalPerfectMatchingsFailClosed() {
        let evidence = rebindEvidence(
            windowNumber: 77,
            title: "Same",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertTrue(
            AXWindowRebindMatcher.globallyUniqueAssignments(
                previous: [evidence, evidence],
                candidates: [evidence, evidence]
            ).isEmpty
        )
    }

    func testLifecycleTerminationRejectsAlreadyEmittedResult() {
        var tracker = AXApplicationLifecycleTracker()
        let lifecycle = tracker.beginLifecycle(for: 42)
        let emitted = AXApplicationLifecycleValue(
            lifecycle: lifecycle,
            value: "stale"
        )

        tracker.endLifecycle(for: 42)

        XCTAssertFalse(tracker.isCurrent(lifecycle))
        XCTAssertTrue(tracker.filteringCurrent([emitted]).isEmpty)
    }

    func testPIDReuseIssuesNewEpochAndRejectsOldIncarnation() {
        var tracker = AXApplicationLifecycleTracker()
        let original = tracker.beginLifecycle(for: 42)
        let replacement = tracker.beginLifecycle(for: 42)

        XCTAssertNotEqual(original.epoch, replacement.epoch)
        XCTAssertFalse(tracker.isCurrent(original))
        XCTAssertTrue(tracker.isCurrent(replacement))
    }

    func testOrdinaryScanRetainsCurrentApplicationEpoch() {
        var tracker = AXApplicationLifecycleTracker()
        let launched = tracker.beginLifecycle(for: 42)
        let scanned = tracker.currentOrBeginLifecycle(for: 42)

        XCTAssertEqual(launched, scanned)
        XCTAssertTrue(tracker.isCurrent(scanned))
    }

    func testFullSnapshotFilterKeepsOnlyCurrentPIDIncarnations() {
        var tracker = AXApplicationLifecycleTracker()
        let stalePID = tracker.beginLifecycle(for: 42)
        let currentOtherPID = tracker.beginLifecycle(for: 84)
        tracker.endLifecycle(for: 42)
        let reusedPID = tracker.beginLifecycle(for: 42)

        let filtered = tracker.filteringCurrent([
            AXApplicationLifecycleValue(
                lifecycle: stalePID,
                value: "old-42"
            ),
            AXApplicationLifecycleValue(
                lifecycle: currentOtherPID,
                value: "current-84"
            ),
            AXApplicationLifecycleValue(
                lifecycle: reusedPID,
                value: "current-42"
            ),
        ])

        XCTAssertEqual(
            filtered.map(\.value),
            ["current-84", "current-42"]
        )
    }

    func testOptionalUnsupportedAttributeDoesNotInvalidateSnapshot() {
        XCTAssertFalse(
            AXAttributeReadPreservationPolicy.shouldPreserveLastKnown(
                statusRawValue: -25205,
                required: false
            )
        )
        XCTAssertFalse(
            AXAttributeReadPreservationPolicy.shouldPreserveLastKnown(
                statusRawValue: -25212,
                required: false
            )
        )
    }

    func testRequiredOrTransportAttributeFailurePreservesSnapshot() {
        XCTAssertTrue(
            AXAttributeReadPreservationPolicy.shouldPreserveLastKnown(
                statusRawValue: -25205,
                required: true
            )
        )
        XCTAssertTrue(
            AXAttributeReadPreservationPolicy.shouldPreserveLastKnown(
                statusRawValue: -25204,
                required: false
            )
        )
        XCTAssertTrue(
            AXAttributeReadPreservationPolicy.shouldPreserveLastKnown(
                statusRawValue: -25202,
                required: false
            )
        )
    }

    func testInconclusiveDecodeCannotCommitDTOOrActionHandle() {
        XCTAssertFalse(
            AXWindowDecodeCommitPolicy.shouldCommit(
                decodeIsConclusive: false,
                candidateIsAccepted: true
            )
        )
        XCTAssertFalse(
            AXWindowDecodeCommitPolicy.shouldCommit(
                decodeIsConclusive: true,
                candidateIsAccepted: false
            )
        )
        XCTAssertTrue(
            AXWindowDecodeCommitPolicy.shouldCommit(
                decodeIsConclusive: true,
                candidateIsAccepted: true
            )
        )
    }

    func testInconclusiveProcessSnapshotCannotHeuristicallyRebindHandle() {
        XCTAssertFalse(
            AXWindowDecodeCommitPolicy.allowsHeuristicRebinding(
                processSnapshotIsConclusive: false
            )
        )
        XCTAssertTrue(
            AXWindowDecodeCommitPolicy.allowsHeuristicRebinding(
                processSnapshotIsConclusive: true
            )
        )
    }

    func testEnumerationSentinelDetectsTruncation() {
        XCTAssertTrue(
            AXBoundedEnumerationPolicy.isComplete(
                returnedCount: 256,
                publishedLimit: 256
            )
        )
        XCTAssertFalse(
            AXBoundedEnumerationPolicy.isComplete(
                returnedCount: 257,
                publishedLimit: 256
            )
        )
    }

    func testActionRetryRequiresFirstInvalidElementFailure() {
        XCTAssertTrue(
            AXActionRetryPolicy.shouldRefreshAndRetry(
                statusRawValue: -25202,
                alreadyRetried: false
            )
        )
        XCTAssertFalse(
            AXActionRetryPolicy.shouldRefreshAndRetry(
                statusRawValue: -25204,
                alreadyRetried: false
            )
        )
        XCTAssertFalse(
            AXActionRetryPolicy.shouldRefreshAndRetry(
                statusRawValue: -25202,
                alreadyRetried: true
            )
        )
    }

    func testActionRecoveryAllowsOneEnumerationAndNoCandidateReads() {
        var budget = AXActionRecoveryBudget()

        XCTAssertTrue(budget.consumeSynchronousEnumeration())
        XCTAssertFalse(budget.consumeSynchronousEnumeration())
        XCTAssertEqual(budget.remainingSynchronousEnumerations, 0)
        XCTAssertEqual(
            AXActionRecoveryBudget.maximumCandidateAttributeReads,
            0
        )
    }

    func testCancelledOrStaleActionCannotProceed() {
        XCTAssertFalse(
            AXActionExecutionPolicy.shouldProceed(
                isCancelled: true,
                lifecycleIsCurrent: true
            )
        )
        XCTAssertFalse(
            AXActionExecutionPolicy.shouldProceed(
                isCancelled: false,
                lifecycleIsCurrent: false
            )
        )
        XCTAssertTrue(
            AXActionExecutionPolicy.shouldProceed(
                isCancelled: false,
                lifecycleIsCurrent: true
            )
        )
    }

    func testCloseButtonFallbackRequiresExplicitUnsupportedStatus() {
        XCTAssertTrue(
            AXCloseFallbackPolicy.shouldAttemptButton(
                directStatusRawValue: -25206
            )
        )
        XCTAssertFalse(
            AXCloseFallbackPolicy.shouldAttemptButton(
                directStatusRawValue: -25204
            )
        )
        XCTAssertFalse(
            AXCloseFallbackPolicy.shouldAttemptButton(
                directStatusRawValue: -25200
            )
        )
    }

    func testInconclusiveSnapshotRetainsLastKnownIdentities() {
        let retained = AXSnapshotIdentityReducer.retainedIDs(
            previous: Set(["old", "still"]),
            discovered: Set(["still", "new"]),
            preserveUnseen: true
        )

        XCTAssertEqual(retained, Set(["old", "still", "new"]))
    }

    func testSuccessfulEmptySnapshotProvesPriorWindowsAreGone() {
        let retained = AXSnapshotIdentityReducer.retainedIDs(
            previous: Set(["old"]),
            discovered: Set<String>(),
            preserveUnseen: false
        )

        XCTAssertTrue(retained.isEmpty)
    }

    func testFreshSnapshotReplacesRetainedValueWithoutDuplicateIdentity() {
        var values = [
            SnapshotValue(id: "a", version: 1),
            SnapshotValue(id: "b", version: 1),
        ]

        AXSnapshotValueReducer.upsert(
            SnapshotValue(id: "b", version: 2),
            into: &values
        )

        XCTAssertEqual(
            values,
            [
                SnapshotValue(id: "a", version: 1),
                SnapshotValue(id: "b", version: 2),
            ]
        )
    }

    func testPublishedSnapshotDefensivelyDeduplicatesNewestValueInPlace() {
        let values = AXSnapshotValueReducer.deduplicated([
            SnapshotValue(id: "a", version: 1),
            SnapshotValue(id: "b", version: 1),
            SnapshotValue(id: "b", version: 2),
        ])

        XCTAssertEqual(
            values,
            [
                SnapshotValue(id: "a", version: 1),
                SnapshotValue(id: "b", version: 2),
            ]
        )
    }

    func testAXWorkerInitNeverWaitsForRunLoopReadiness() throws {
        let source = try sourceFile(
            "Docky/Services/AXWindowWorker.swift"
        )
        let initialization = try sourceSection(
            in: source,
            startingAt: "    init() {",
            endingAt: "    func setEventSink("
        )
        XCTAssertFalse(initialization.contains(".wait()"))
        XCTAssertFalse(initialization.contains("DispatchSemaphore"))

        let threadStartup = try sourceSection(
            in: source,
            startingAt: "    private func threadMain() {",
            endingAt:
                "    /// User/lifecycle commands always outrank"
        )
        XCTAssertTrue(
            threadStartup.contains("!commandQueue.isEmpty")
        )
        XCTAssertTrue(
            threadStartup.contains(
                "scheduleCommandPump(on: currentRunLoop)"
            )
        )
    }

    func testAppleScriptNeverCompilesOrExecutesInMainActorService()
        throws {
        let service = try sourceFile(
            "Docky/Services/AppleScriptService.swift"
        )
        XCTAssertTrue(service.contains("@MainActor"))
        XCTAssertFalse(service.contains("NSAppleScript"))
        XCTAssertFalse(service.contains("executeDescriptor"))
        XCTAssertFalse(service.contains("MainActor.run"))

        let worker = try sourceFile(
            "Docky/Services/AppleScriptExecutionWorker.swift"
        )
        XCTAssertTrue(
            worker.contains(
                "nonisolated final class AppleScriptExecutionWorker"
            )
        )
        XCTAssertTrue(worker.contains("executionQueue.async"))
        XCTAssertTrue(
            worker.contains("guard !Thread.isMainThread else")
        )
        XCTAssertFalse(worker.contains("DispatchQueue.main"))
    }

    func testNSAppleScriptIsConfinedToDedicatedWorkerFile() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Docky")
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: resourceKeys
            )
        )
        var offenders: [String] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift",
                  fileURL.lastPathComponent
                    != "AppleScriptExecutionWorker.swift",
                  let source = try? String(
                    contentsOf: fileURL,
                    encoding: .utf8
                  ),
                  source.contains("NSAppleScript")
                    || source.contains("executeDescriptor") else {
                continue
            }
            offenders.append(
                fileURL.path.replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                )
            )
        }

        XCTAssertEqual(offenders, [])
    }

    func testAppleScriptTimeoutAndCancellationAbandonLateResults()
        throws {
        let worker = try sourceFile(
            "Docky/Services/AppleScriptExecutionWorker.swift"
        )
        let request = try sourceSection(
            in: worker,
            startingAt:
                "private nonisolated final class AppleScriptExecutionRequest",
            endingAt:
                "/// `nonisolated` is required because the project defaults"
        )
        XCTAssertTrue(request.contains("guard !isFinished else"))
        XCTAssertTrue(request.contains("isFinished = true"))

        let submission = try sourceSection(
            in: worker,
            startingAt: "    private func submit(",
            endingAt:
                "    private static func executeSynchronously("
        )
        XCTAssertTrue(
            submission.contains("withTaskCancellationHandler")
        )
        XCTAssertTrue(
            submission.contains(
                "request.finish(.failure(.timedOut))"
            )
        )
        XCTAssertTrue(
            submission.contains(
                "request.finish(.failure(.cancelled))"
            )
        )
    }

    func testAllAppleScriptConsumersAwaitWorkerSafeValues() throws {
        let media = try sourceFile(
            "Docky/Services/MediaPlaybackService.swift"
        )
        XCTAssertFalse(media.contains("executeDescriptor"))
        XCTAssertTrue(
            media.contains(
                "await AppleScriptService.shared.executeBoolean("
            )
        )
        XCTAssertFalse(
            media.contains(
                "await AppleScriptService.shared.execute("
            ),
            "Favorite reads and writes must both use the typed Boolean result."
        )
    }

    private func rebindEvidence(
        cgWindowID: UInt32? = nil,
        windowNumber: Int? = nil,
        title: String? = nil,
        frame: CGRect? = nil
    ) -> AXWindowRebindEvidence {
        AXWindowRebindEvidence(
            cgWindowID: cgWindowID,
            windowNumber: windowNumber,
            title: title,
            frame: frame
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

    private func sourceSection(
        in source: String,
        startingAt startMarker: String,
        endingAt endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
            )
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
