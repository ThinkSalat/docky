import Foundation
import XCTest

final class CoalescingPersistenceCoordinatorTests: XCTestCase {
    private enum FixtureError: Error {
        case writeFailed
    }

    @MainActor
    func testPendingWritesCoalesceToNewestValue() {
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let allowFirstWrite = DispatchSemaphore(value: 0)
        let state = LockedFixtureState()

        let coordinator = CoalescingPersistenceCoordinator(
            initialDurableValue: 0,
            persist: { value in
                state.appendPersisted(value)
                if value == 1 {
                    firstWriteStarted.signal()
                    _ = allowFirstWrite.wait(timeout: .now() + 2)
                }
                return value
            },
            onEvent: { event in
                MainActor.preconditionIsolated()
                state.appendEvent(event)
            }
        )

        XCTAssertTrue(coordinator.submit(1))
        XCTAssertEqual(firstWriteStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(coordinator.submit(2))
        XCTAssertTrue(coordinator.submit(3))
        allowFirstWrite.signal()

        coordinator.flush()

        XCTAssertEqual(state.persistedValues, [1, 3])
        XCTAssertEqual(state.persistedEventValues, [1, 3])
    }

    @MainActor
    func testFailureDiscardsPendingWritesAndRejectsNewOnes() {
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let allowFailure = DispatchSemaphore(value: 0)
        let state = LockedFixtureState()

        let coordinator = CoalescingPersistenceCoordinator(
            initialDurableValue: 0,
            persist: { value in
                state.appendPersisted(value)
                firstWriteStarted.signal()
                _ = allowFailure.wait(timeout: .now() + 2)
                throw FixtureError.writeFailed
            },
            onEvent: { event in
                MainActor.preconditionIsolated()
                state.appendEvent(event)
            }
        )

        XCTAssertTrue(coordinator.submit(1))
        XCTAssertEqual(firstWriteStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(coordinator.submit(2))
        allowFailure.signal()

        coordinator.flush()

        XCTAssertEqual(state.persistedValues, [1])
        XCTAssertFalse(coordinator.submit(3))
        XCTAssertNotNil(coordinator.failureDescription)
        XCTAssertEqual(state.failedAttempt, 1)
        XCTAssertEqual(state.failedDurableValue, 0)
    }

    @MainActor
    func testFlushDeliversOnceBeforeReturning() {
        let state = LockedFixtureState()

        let coordinator = CoalescingPersistenceCoordinator(
            initialDurableValue: 0,
            persist: { value in
                state.recordPersistRanOnMainThread(Thread.isMainThread)
                return value
            },
            onEvent: { event in
                MainActor.preconditionIsolated()
                state.appendEvent(event)
            }
        )

        XCTAssertTrue(coordinator.submit(1))
        coordinator.flush()
        XCTAssertEqual(state.persistedEventValues, [1])

        // The already-scheduled MainActor delivery uses this same drain after
        // flush returns. It must observe an empty event queue.
        coordinator.deliverPendingEvents()
        XCTAssertEqual(state.persistedEventValues, [1])
        XCTAssertEqual(state.persistedOnMainThread, [false])
    }

    @MainActor
    func testSuccessThenFailureEventsStayInPersistenceOrder() {
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let allowFirstWrite = DispatchSemaphore(value: 0)
        let state = LockedFixtureState()

        let coordinator = CoalescingPersistenceCoordinator(
            initialDurableValue: 0,
            persist: { value in
                state.appendPersisted(value)
                if value == 1 {
                    firstWriteStarted.signal()
                    _ = allowFirstWrite.wait(timeout: .now() + 2)
                    return value
                }
                throw FixtureError.writeFailed
            },
            onEvent: { event in
                MainActor.preconditionIsolated()
                state.appendEvent(event)
            }
        )

        XCTAssertTrue(coordinator.submit(1))
        XCTAssertEqual(firstWriteStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(coordinator.submit(2))
        allowFirstWrite.signal()

        coordinator.flush()

        XCTAssertEqual(state.persistedValues, [1, 2])
        XCTAssertEqual(
            state.eventSummaries,
            ["persisted:1", "failed:2:1"]
        )
    }

    @MainActor
    func testProfileServiceDoesNotAddAnUnstructuredActorHop() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let profileServiceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Docky/Services/ProfileService.swift")
        let source = try String(contentsOf: profileServiceURL)
        let coordinatorStart = try XCTUnwrap(
            source.range(of: "private lazy var persistenceCoordinator")
        )
        let legacyKeysStart = try XCTUnwrap(
            source.range(
                of: "private enum LegacyKeys",
                range: coordinatorStart.upperBound..<source.endIndex
            )
        )
        let integration = source[
            coordinatorStart.lowerBound..<legacyKeysStart.lowerBound
        ]

        XCTAssertTrue(integration.contains("self?.handlePersistenceEvent(event)"))
        XCTAssertFalse(integration.contains("Task { @MainActor"))
    }
}

private final class LockedFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var persisted: [Int] = []
    private var events:
        [CoalescingPersistenceCoordinator<Int>.Event] = []

    var persistedValues: [Int] {
        lock.withFixtureLock { persisted }
    }

    var persistedEventValues: [Int] {
        lock.withFixtureLock {
            events.compactMap { event in
                guard case .persisted(let value, _) = event else {
                    return nil
                }
                return value
            }
        }
    }

    var failedAttempt: Int? {
        lock.withFixtureLock {
            events.compactMap { event in
                guard case .failed(let attempted, _, _) = event else {
                    return nil
                }
                return attempted
            }.last
        }
    }

    var failedDurableValue: Int? {
        lock.withFixtureLock {
            events.compactMap { event in
                guard case .failed(_, let durable, _) = event else {
                    return nil
                }
                return durable
            }.last
        }
    }

    var eventSummaries: [String] {
        lock.withFixtureLock {
            events.map { event in
                switch event {
                case .persisted(let value, _):
                    return "persisted:\(value)"
                case .failed(let attempted, let durable, _):
                    return "failed:\(attempted):\(durable)"
                }
            }
        }
    }

    var persistedOnMainThread: [Bool] {
        lock.withFixtureLock { persistMainThreadChecks }
    }

    func appendPersisted(_ value: Int) {
        lock.withFixtureLock {
            persisted.append(value)
        }
    }

    func appendEvent(
        _ event: CoalescingPersistenceCoordinator<Int>.Event
    ) {
        lock.withFixtureLock {
            events.append(event)
        }
    }

    func recordPersistRanOnMainThread(_ isOnMainThread: Bool) {
        lock.withFixtureLock {
            persistMainThreadChecks.append(isOnMainThread)
        }
    }

    private var persistMainThreadChecks: [Bool] = []
}

private extension NSLock {
    func withFixtureLock<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
