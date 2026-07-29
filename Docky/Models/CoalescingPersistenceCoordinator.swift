import Foundation

/// Serializes durable writes away from the caller and keeps at most the newest
/// value waiting behind an in-flight write. Every queued replacement is based
/// on the caller's current in-memory state, so the newest value subsumes the
/// intermediate ones.
nonisolated final class CoalescingPersistenceCoordinator<Value>:
    @unchecked Sendable {
    nonisolated enum Event: @unchecked Sendable {
        case persisted(value: Value, encodedBytes: Int)
        case failed(
            attemptedValue: Value,
            durableValue: Value,
            errorDescription: String
        )
    }

    private let lock = NSLock()
    private let workerQueue = DispatchQueue(
        label: "com.docky.profile-persistence",
        qos: .utility
    )
    private let persist: (Value, Value) throws -> Int
    private let onEvent: @MainActor (Event) -> Void

    private var durableValue: Value
    private var pendingValue: Value?
    private var pendingEvents: [Event] = []
    private var workerIsScheduled = false
    private var eventDeliveryIsScheduled = false
    private var terminalFailureDescription: String?

    init(
        initialDurableValue: Value,
        persist: @escaping (
            _ value: Value,
            _ durablePredecessor: Value
        ) throws -> Int,
        onEvent: @MainActor @escaping (Event) -> Void
    ) {
        durableValue = initialDurableValue
        self.persist = persist
        self.onEvent = onEvent
    }

    convenience init(
        initialDurableValue: Value,
        persist: @escaping (Value) throws -> Int,
        onEvent: @MainActor @escaping (Event) -> Void
    ) {
        self.init(
            initialDurableValue: initialDurableValue,
            persist: { value, _ in
                try persist(value)
            },
            onEvent: onEvent
        )
    }

    /// Returns false after the first durable-write failure. Callers can then
    /// reject new mutations until the owner reconciles to `durableValue`.
    @discardableResult
    func submit(_ value: Value) -> Bool {
        lock.lock()
        guard terminalFailureDescription == nil else {
            lock.unlock()
            return false
        }

        pendingValue = value
        let shouldScheduleWorker = !workerIsScheduled
        if shouldScheduleWorker {
            workerIsScheduled = true
        }
        lock.unlock()

        if shouldScheduleWorker {
            workerQueue.async { [weak self] in
                self?.drain()
            }
        }
        return true
    }

    var failureDescription: String? {
        lock.withLock { terminalFailureDescription }
    }

    /// The newest value that has actually reached durable storage.
    ///
    /// Runtime policies that need a persisted fact must not infer durability
    /// from the owner's newer optimistic in-memory value.
    var durableValueSnapshot: Value {
        lock.withLock { durableValue }
    }

    /// Waits for the in-flight write and the newest coalesced value, then
    /// synchronously delivers every resulting event. This is intended for
    /// orderly process termination, not interactive code paths.
    @MainActor
    func flush() {
        repeat {
            workerQueue.sync {}
            deliverPendingEvents()
        } while hasPendingWork
    }

    private func drain() {
        while let value = takePendingValue() {
            let durablePredecessor = lock.withLock { durableValue }
            do {
                let encodedBytes = try persist(
                    value,
                    durablePredecessor
                )
                lock.withLock {
                    durableValue = value
                }
                publish(.persisted(
                    value: value,
                    encodedBytes: encodedBytes
                ))
            } catch {
                let failure = String(describing: error)
                let durable = lock.withLock { () -> Value in
                    terminalFailureDescription = failure
                    pendingValue = nil
                    workerIsScheduled = false
                    return durableValue
                }
                publish(.failed(
                    attemptedValue: value,
                    durableValue: durable,
                    errorDescription: failure
                ))
                return
            }
        }
    }

    private func takePendingValue() -> Value? {
        lock.withLock {
            guard let pendingValue else {
                workerIsScheduled = false
                return nil
            }
            self.pendingValue = nil
            return pendingValue
        }
    }

    private func publish(_ event: Event) {
        let shouldScheduleDelivery = lock.withLock {
            pendingEvents.append(event)
            guard !eventDeliveryIsScheduled else {
                return false
            }
            eventDeliveryIsScheduled = true
            return true
        }

        guard shouldScheduleDelivery else {
            return
        }
        Task { @MainActor [weak self] in
            self?.deliverPendingEvents()
        }
    }

    private var hasPendingWork: Bool {
        lock.withLock {
            workerIsScheduled
                || pendingValue != nil
                || !pendingEvents.isEmpty
        }
    }

    /// Internal so hostless tests can deterministically exercise the harmless
    /// queued-delivery path after a synchronous flush.
    @MainActor
    func deliverPendingEvents() {
        while let event = takePendingEvent() {
            onEvent(event)
        }
    }

    private func takePendingEvent() -> Event? {
        lock.withLock {
            guard !pendingEvents.isEmpty else {
                eventDeliveryIsScheduled = false
                return nil
            }
            return pendingEvents.removeFirst()
        }
    }
}

private extension NSLock {
    nonisolated func withLock<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
