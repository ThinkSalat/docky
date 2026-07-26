//
//  AXRequestGeneration.swift
//  Docky
//
//  Pure request-generation primitives shared by the AX worker and its
//  MainActor facade. Kept free of AppKit/ApplicationServices so stale-result
//  suppression and queue coalescing can be tested without an application host
//  or Accessibility permission.
//

import Foundation
import CoreGraphics

nonisolated struct AXRequestGeneration: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: AXRequestGeneration, rhs: AXRequestGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Issues monotonically increasing generations and remembers the newest one
/// for each logical request scope. Cancellation is cooperative: an AX message
/// already waiting on another process cannot be interrupted safely, but its
/// result is discarded when a newer generation exists.
nonisolated struct AXRequestGenerationTracker<Key: Hashable & Sendable>: Sendable {
    private var nextRawValue: UInt64 = 0
    private var latestByKey: [Key: AXRequestGeneration] = [:]

    mutating func issue(for key: Key) -> AXRequestGeneration {
        nextRawValue &+= 1
        // Reserve zero as the uninitialized value even after an astronomically
        // unlikely integer wrap.
        if nextRawValue == 0 {
            nextRawValue = 1
        }
        let generation = AXRequestGeneration(rawValue: nextRawValue)
        latestByKey[key] = generation
        return generation
    }

    func isCurrent(_ generation: AXRequestGeneration, for key: Key) -> Bool {
        latestByKey[key] == generation
    }

    mutating func invalidate(_ key: Key) {
        _ = issue(for: key)
    }

    mutating func invalidateAll() {
        let keys = Array(latestByKey.keys)
        for key in keys {
            invalidate(key)
        }
    }
}

nonisolated struct AXCoalescedRequest<
    Key: Hashable & Sendable,
    Payload: Sendable
>: Sendable {
    let key: Key
    let generation: AXRequestGeneration
    let payload: Payload
}

/// A small FIFO-by-key queue. Repeated requests for a key replace its pending
/// payload and generation without adding more work; different keys retain the
/// order in which they first became pending.
nonisolated struct AXCoalescingRequestQueue<
    Key: Hashable & Sendable,
    Payload: Sendable
>: Sendable {
    private var keyOrder: [Key] = []
    private var pendingByKey: [Key: AXCoalescedRequest<Key, Payload>] = [:]

    var isEmpty: Bool { pendingByKey.isEmpty }
    var count: Int { pendingByKey.count }

    mutating func enqueue(
        key: Key,
        generation: AXRequestGeneration,
        payload: Payload
    ) {
        if pendingByKey[key] == nil {
            keyOrder.append(key)
        }
        pendingByKey[key] = AXCoalescedRequest(
            key: key,
            generation: generation,
            payload: payload
        )
    }

    mutating func dequeue() -> AXCoalescedRequest<Key, Payload>? {
        while !keyOrder.isEmpty {
            let key = keyOrder.removeFirst()
            if let request = pendingByKey.removeValue(forKey: key) {
                return request
            }
        }
        return nil
    }

    mutating func cancel(_ key: Key) {
        pendingByKey.removeValue(forKey: key)
        keyOrder.removeAll { $0 == key }
    }

    mutating func cancelAll() {
        keyOrder.removeAll(keepingCapacity: true)
        pendingByKey.removeAll(keepingCapacity: true)
    }
}

/// Result categories for a single `AXObserverAddNotification` attempt.
///
/// The worker maps Accessibility error codes into these pure values so retry
/// timing can be tested without an application host or Accessibility access.
nonisolated enum AXNotificationRegistrationOutcome:
    Equatable,
    Sendable {
    case registered
    case alreadyRegistered
    case cannotComplete
    case unsupported
    case terminalFailure
}

/// Bounded retry queue for Accessibility notification registrations.
///
/// A key represents one application-lifecycle/notification pair. Re-enqueuing
/// the same key supersedes the old generation, so a late result can never
/// mutate newer state. Transient messaging failures use nonzero backoff
/// delays; unsupported and structural failures terminate immediately.
nonisolated struct AXNotificationRegistrationRetryState<
    Key: Hashable & Sendable
>: Sendable {
    struct Generation: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    struct Attempt: Hashable, Sendable {
        let key: Key
        let generation: Generation
        let attemptIndex: Int
    }

    enum Resolution: Equatable, Sendable {
        case completed
        case unsupported
        case terminalFailure
        case retryScheduled(deadline: TimeInterval)
        case exhausted
        case stale
    }

    private struct Entry: Sendable {
        let generation: Generation
        var attemptIndex: Int
        var readyAt: TimeInterval
    }

    private let retryDelays: [TimeInterval]
    private var nextGenerationRawValue: UInt64 = 0
    private var order: [Key] = []
    private var entries: [Key: Entry] = [:]

    init(
        retryDelays: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2]
    ) {
        // Invalid or zero delays could turn a transient remote failure into a
        // hot retry loop. Discard them at the pure-state boundary.
        self.retryDelays = retryDelays.filter {
            $0.isFinite && $0 > 0
        }
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    var nextDeadline: TimeInterval? {
        entries.values.map(\.readyAt).min()
    }

    @discardableResult
    mutating func enqueue(
        _ key: Key,
        now: TimeInterval
    ) -> Generation {
        nextGenerationRawValue &+= 1
        if nextGenerationRawValue == 0 {
            nextGenerationRawValue = 1
        }
        let generation = Generation(rawValue: nextGenerationRawValue)
        if !order.contains(key) {
            order.append(key)
        }
        entries[key] = Entry(
            generation: generation,
            attemptIndex: 0,
            readyAt: now
        )
        return generation
    }

    /// Removes and returns one ready attempt. The key is put back into FIFO
    /// order only if `resolve` schedules a retry.
    mutating func nextReady(now: TimeInterval) -> Attempt? {
        var inspected = 0
        while inspected < order.count {
            let key = order.removeFirst()
            guard let entry = entries[key] else {
                continue
            }
            if entry.readyAt <= now {
                return Attempt(
                    key: key,
                    generation: entry.generation,
                    attemptIndex: entry.attemptIndex
                )
            }
            order.append(key)
            inspected += 1
        }
        return nil
    }

    mutating func resolve(
        _ attempt: Attempt,
        outcome: AXNotificationRegistrationOutcome,
        now: TimeInterval
    ) -> Resolution {
        guard let entry = entries[attempt.key],
              entry.generation == attempt.generation,
              entry.attemptIndex == attempt.attemptIndex else {
            return .stale
        }

        switch outcome {
        case .registered, .alreadyRegistered:
            entries.removeValue(forKey: attempt.key)
            return .completed

        case .unsupported:
            entries.removeValue(forKey: attempt.key)
            return .unsupported

        case .terminalFailure:
            entries.removeValue(forKey: attempt.key)
            return .terminalFailure

        case .cannotComplete:
            guard attempt.attemptIndex < retryDelays.count else {
                entries.removeValue(forKey: attempt.key)
                return .exhausted
            }
            let deadline = now + retryDelays[attempt.attemptIndex]
            entries[attempt.key] = Entry(
                generation: attempt.generation,
                attemptIndex: attempt.attemptIndex + 1,
                readyAt: deadline
            )
            order.append(attempt.key)
            return .retryScheduled(deadline: deadline)
        }
    }

    mutating func cancel(_ key: Key) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    mutating func cancel(
        where shouldCancel: (Key) -> Bool
    ) {
        let keys = entries.keys.filter(shouldCancel)
        for key in keys {
            cancel(key)
        }
    }

    mutating func cancelAll() {
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

/// Retains the complete inputs needed to restart cooperative work after an
/// urgent request interrupts it. Completion is generation-checked so a late
/// completion from the abandoned plan cannot clear its replacement.
nonisolated struct AXRestartableRequestState<
    Payload: Sendable,
    Unit: Sendable
>: Sendable {
    struct Request: Sendable {
        let generation: AXRequestGeneration
        let payload: Payload
        let units: [Unit]
    }

    private(set) var current: Request?

    mutating func begin(
        generation: AXRequestGeneration,
        payload: Payload,
        units: [Unit]
    ) {
        current = Request(
            generation: generation,
            payload: payload,
            units: units
        )
    }

    @discardableResult
    mutating func restart(
        generation: AXRequestGeneration,
        units: [Unit]? = nil
    ) -> Request? {
        guard let current else { return nil }
        let replacement = Request(
            generation: generation,
            payload: current.payload,
            units: units ?? current.units
        )
        self.current = replacement
        return replacement
    }

    mutating func complete(generation: AXRequestGeneration) {
        guard current?.generation == generation else { return }
        current = nil
    }

    mutating func cancel() {
        current = nil
    }
}

nonisolated enum AXCommandPriority: Sendable {
    case user
    case background
}

/// Strict two-level queue used by the AX run-loop pump. It intentionally does
/// not provide fairness between levels: interaction work must always run
/// before another observer-registration or snapshot slice.
nonisolated struct AXPriorityCommandQueue<Value: Sendable>: Sendable {
    private var userValues: [Value] = []
    private var backgroundValues: [Value] = []

    var isEmpty: Bool {
        userValues.isEmpty && backgroundValues.isEmpty
    }

    mutating func enqueue(_ value: Value, priority: AXCommandPriority) {
        switch priority {
        case .user:
            userValues.append(value)
        case .background:
            backgroundValues.append(value)
        }
    }

    mutating func dequeue() -> Value? {
        if !userValues.isEmpty {
            return userValues.removeFirst()
        }
        if !backgroundValues.isEmpty {
            return backgroundValues.removeFirst()
        }
        return nil
    }
}

/// One bounded unit from a cooperatively scheduled request. Consumers execute
/// exactly one slice, then yield back to their serial executor before asking
/// for another. That yield is what lets latency-sensitive commands already
/// waiting on the executor run ahead of the next scan unit.
nonisolated struct AXCooperativeWorkSlice<
    Key: Hashable & Sendable,
    Unit: Sendable,
    Payload: Sendable
>: Sendable {
    let key: Key
    let generation: AXRequestGeneration
    let payload: Payload
    let unit: Unit?
    let isLast: Bool
}

/// Pure state machine for incremental, coalesced background work. Replacing a
/// request invalidates the active plan immediately; its already-running slice
/// may finish, but `isCurrent(_:)` rejects the result and no remaining slices
/// from that plan are issued.
nonisolated struct AXCooperativeWorkScheduler<
    Key: Hashable & Sendable,
    Unit: Sendable,
    Payload: Sendable
>: Sendable {
    private struct Plan: Sendable {
        let key: Key
        let generation: AXRequestGeneration
        let payload: Payload
        var units: [Unit]
        var nextIndex: Int

        var sliceCount: Int {
            max(units.count, 1)
        }
    }

    private var keyOrder: [Key] = []
    private var pendingByKey: [Key: Plan] = [:]
    private var latestByKey: [Key: AXRequestGeneration] = [:]
    private var active: Plan?

    var isEmpty: Bool {
        active == nil && pendingByKey.isEmpty
    }

    mutating func enqueue(
        key: Key,
        generation: AXRequestGeneration,
        payload: Payload,
        units: [Unit]
    ) {
        latestByKey[key] = generation
        if pendingByKey[key] == nil {
            keyOrder.append(key)
        }
        pendingByKey[key] = Plan(
            key: key,
            generation: generation,
            payload: payload,
            units: units,
            nextIndex: 0
        )
    }

    mutating func nextSlice()
        -> AXCooperativeWorkSlice<Key, Unit, Payload>? {
        discardFinishedOrStaleActivePlan()

        if active == nil {
            while !keyOrder.isEmpty {
                let key = keyOrder.removeFirst()
                guard let candidate = pendingByKey.removeValue(forKey: key),
                      latestByKey[key] == candidate.generation else {
                    continue
                }
                active = candidate
                break
            }
        }

        guard var plan = active,
              latestByKey[plan.key] == plan.generation,
              plan.nextIndex < plan.sliceCount else {
            active = nil
            return nil
        }

        let index = plan.nextIndex
        plan.nextIndex += 1
        active = plan
        return AXCooperativeWorkSlice(
            key: plan.key,
            generation: plan.generation,
            payload: plan.payload,
            unit: plan.units.isEmpty ? nil : plan.units[index],
            isLast: plan.nextIndex == plan.sliceCount
        )
    }

    func isCurrent(
        _ slice: AXCooperativeWorkSlice<Key, Unit, Payload>
    ) -> Bool {
        latestByKey[slice.key] == slice.generation
    }

    /// Expands the active plan after a discovery slice (for example, one
    /// application-list request discovering individual windows). New units
    /// run immediately after the current slice, before later original units.
    @discardableResult
    mutating func insertAfterCurrentSlice(
        _ units: [Unit],
        for slice: AXCooperativeWorkSlice<Key, Unit, Payload>
    ) -> Bool {
        guard !units.isEmpty,
              var plan = active,
              plan.key == slice.key,
              plan.generation == slice.generation,
              latestByKey[plan.key] == plan.generation else {
            return false
        }
        plan.units.insert(contentsOf: units, at: plan.nextIndex)
        active = plan
        return true
    }

    func isComplete(
        after slice: AXCooperativeWorkSlice<Key, Unit, Payload>
    ) -> Bool {
        guard let active,
              active.key == slice.key,
              active.generation == slice.generation,
              latestByKey[active.key] == active.generation else {
            return false
        }
        return active.nextIndex >= active.sliceCount
    }

    mutating func cancel(_ key: Key) {
        latestByKey.removeValue(forKey: key)
        pendingByKey.removeValue(forKey: key)
        keyOrder.removeAll { $0 == key }
        if active?.key == key {
            active = nil
        }
    }

    mutating func cancelAll() {
        active = nil
        latestByKey.removeAll(keepingCapacity: true)
        pendingByKey.removeAll(keepingCapacity: true)
        keyOrder.removeAll(keepingCapacity: true)
    }

    private mutating func discardFinishedOrStaleActivePlan() {
        guard let active else { return }
        if latestByKey[active.key] != active.generation
            || active.nextIndex >= active.sliceCount {
            self.active = nil
        }
    }
}

/// Produces collision-free process-local cache keys from the worker's unique
/// token. A CGWindowID is descriptive only; identity remains the allocated
/// token so ID reuse by WindowServer cannot alias a live cache entry.
nonisolated enum AXWindowIdentityString {
    static func make(
        processIdentifier: Int32,
        token: UInt64,
        cgWindowID: UInt32?
    ) -> String {
        if let cgWindowID {
            return "ax:\(processIdentifier):\(token):cg:\(cgWindowID)"
        }
        return "ax:\(processIdentifier):\(token)"
    }
}

/// Immutable evidence that can be copied from an AX window into a Sendable
/// value before any cached AX proxy is rebound. A WindowServer ID is carried
/// for rejection and narrowing, but deliberately does not count as
/// corroboration because WindowServer can reuse it after a window closes.
nonisolated struct AXWindowRebindEvidence: Equatable, Sendable {
    let cgWindowID: UInt32?
    let windowNumber: Int?
    let title: String?
    let frame: CGRect?
}

/// Fails closed when trying to associate a stale window DTO with a newly
/// enumerated AX proxy. Non-exact rebinding requires title, frame, and window
/// number to agree. A matching CGWindowID, title/frame alone, or the fact that
/// the application exposes only one window is never sufficient by itself.
nonisolated enum AXWindowRebindMatcher {
    static func isCorroboratedMatch(
        previous: AXWindowRebindEvidence,
        candidate: AXWindowRebindEvidence,
        frameTolerance: CGFloat = 2
    ) -> Bool {
        let previousCGWindowID = usableCGWindowID(previous.cgWindowID)
        let candidateCGWindowID = usableCGWindowID(candidate.cgWindowID)
        if let previousCGWindowID,
           candidateCGWindowID != previousCGWindowID {
            return false
        }

        guard let previousTitle = normalizedTitle(previous.title),
              let candidateTitle = normalizedTitle(candidate.title),
              previousTitle == candidateTitle,
              let previousFrame = usableFrame(previous.frame),
              let candidateFrame = usableFrame(candidate.frame),
              framesMatch(
                  previousFrame,
                  candidateFrame,
                  tolerance: max(frameTolerance, 0)
              ),
              let previousWindowNumber = usableWindowNumber(
                  previous.windowNumber
              ),
              let candidateWindowNumber = usableWindowNumber(
                  candidate.windowNumber
              ),
              previousWindowNumber == candidateWindowNumber else {
            return false
        }
        return true
    }

    /// Returns an index only when exactly one candidate is independently
    /// corroborated. This lets the AX worker retain its non-Sendable handles in
    /// a parallel array while the pure matcher operates on value evidence.
    static func uniqueCandidateIndex(
        previous: AXWindowRebindEvidence,
        candidates: [AXWindowRebindEvidence],
        frameTolerance: CGFloat = 2
    ) -> Int? {
        var match: Int?
        for index in candidates.indices where isCorroboratedMatch(
            previous: previous,
            candidate: candidates[index],
            frameTolerance: frameTolerance
        ) {
            guard match == nil else { return nil }
            match = index
        }
        return match
    }

    /// Resolves all non-exact candidates together. A connected evidence graph
    /// is accepted only when it has one unique perfect matching; components
    /// with competing candidates, extra candidates, or alternative matchings
    /// are left unassigned. The worker can then allocate new identities without
    /// ever letting two current AX proxies claim one prior identity.
    ///
    /// The returned dictionary is keyed by candidate index and contains the
    /// corresponding previous-value index.
    static func globallyUniqueAssignments(
        previous: [AXWindowRebindEvidence],
        candidates: [AXWindowRebindEvidence],
        frameTolerance: CGFloat = 2
    ) -> [Int: Int] {
        guard !previous.isEmpty, !candidates.isEmpty else { return [:] }

        let adjacency = candidates.map { candidate in
            previous.indices.filter {
                isCorroboratedMatch(
                    previous: previous[$0],
                    candidate: candidate,
                    frameTolerance: frameTolerance
                )
            }
        }
        var previousToCandidates =
            Array(repeating: [Int](), count: previous.count)
        for candidateIndex in adjacency.indices {
            for previousIndex in adjacency[candidateIndex] {
                previousToCandidates[previousIndex].append(candidateIndex)
            }
        }

        var visitedCandidates = Set<Int>()
        var visitedPrevious = Set<Int>()
        var assignments: [Int: Int] = [:]

        for seed in candidates.indices
        where !visitedCandidates.contains(seed) && !adjacency[seed].isEmpty {
            var componentCandidates = Set<Int>()
            var componentPrevious = Set<Int>()
            var pendingCandidates = [seed]

            while let candidateIndex = pendingCandidates.popLast() {
                guard componentCandidates.insert(candidateIndex).inserted else {
                    continue
                }
                visitedCandidates.insert(candidateIndex)
                for previousIndex in adjacency[candidateIndex] {
                    guard componentPrevious.insert(previousIndex).inserted else {
                        continue
                    }
                    visitedPrevious.insert(previousIndex)
                    pendingCandidates.append(
                        contentsOf: previousToCandidates[previousIndex]
                    )
                }
            }

            guard componentCandidates.count == componentPrevious.count,
                  let matching = perfectMatching(
                      candidates: componentCandidates.sorted(),
                      previous: componentPrevious,
                      adjacency: adjacency
                  ),
                  matchingIsUnique(
                      matching,
                      candidates: componentCandidates,
                      adjacency: adjacency
                  ) else {
                continue
            }
            assignments.merge(matching) { current, _ in current }
        }

        return assignments
    }

    private static func perfectMatching(
        candidates: [Int],
        previous: Set<Int>,
        adjacency: [[Int]]
    ) -> [Int: Int]? {
        var candidateByPrevious: [Int: Int] = [:]

        func augment(
            _ candidate: Int,
            visitedPrevious: inout Set<Int>
        ) -> Bool {
            for previousIndex in adjacency[candidate]
            where previous.contains(previousIndex)
                && visitedPrevious.insert(previousIndex).inserted {
                if let incumbent = candidateByPrevious[previousIndex] {
                    if augment(
                        incumbent,
                        visitedPrevious: &visitedPrevious
                    ) {
                        candidateByPrevious[previousIndex] = candidate
                        return true
                    }
                } else {
                    candidateByPrevious[previousIndex] = candidate
                    return true
                }
            }
            return false
        }

        for candidate in candidates {
            var visited = Set<Int>()
            guard augment(candidate, visitedPrevious: &visited) else {
                return nil
            }
        }
        guard candidateByPrevious.count == candidates.count else { return nil }
        return Dictionary(
            uniqueKeysWithValues: candidateByPrevious.map {
                (candidate: $0.value, previous: $0.key)
            }
        )
    }

    private static func matchingIsUnique(
        _ matching: [Int: Int],
        candidates: Set<Int>,
        adjacency: [[Int]]
    ) -> Bool {
        let candidateByPrevious = Dictionary(
            uniqueKeysWithValues: matching.map {
                (previous: $0.value, candidate: $0.key)
            }
        )
        var alternatingEdges: [Int: [Int]] = [:]
        for candidate in candidates {
            guard let matchedPrevious = matching[candidate] else {
                return false
            }
            alternatingEdges[candidate] = adjacency[candidate].compactMap {
                previousIndex in
                guard previousIndex != matchedPrevious,
                      let otherCandidate =
                        candidateByPrevious[previousIndex] else {
                    return nil
                }
                return otherCandidate
            }
        }

        enum VisitState {
            case visiting
            case visited
        }
        var stateByCandidate: [Int: VisitState] = [:]

        func hasCycle(from candidate: Int) -> Bool {
            if stateByCandidate[candidate] == .visiting {
                return true
            }
            if stateByCandidate[candidate] == .visited {
                return false
            }
            stateByCandidate[candidate] = .visiting
            for next in alternatingEdges[candidate] ?? []
            where hasCycle(from: next) {
                return true
            }
            stateByCandidate[candidate] = .visited
            return false
        }

        return !candidates.contains(where: hasCycle)
    }

    private static func usableCGWindowID(_ value: UInt32?) -> UInt32? {
        guard let value, value != 0 else { return nil }
        return value
    }

    private static func usableWindowNumber(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        return normalized.isEmpty ? nil : normalized
    }

    private static func usableFrame(_ value: CGRect?) -> CGRect? {
        guard let value,
              !value.isNull,
              !value.isInfinite,
              value.origin.x.isFinite,
              value.origin.y.isFinite,
              value.size.width.isFinite,
              value.size.height.isFinite,
              value.size.width > 0,
              value.size.height > 0 else {
            return nil
        }
        return value
    }

    private static func framesMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }
}

/// Main-actor-owned application incarnation marker. Every launch/PID reuse
/// receives a fresh epoch; termination removes the current epoch immediately,
/// making already-emitted worker results fail validation when they eventually
/// reach the UI.
nonisolated struct AXApplicationLifecycleEpoch: Hashable, Sendable {
    let rawValue: UInt64
}

nonisolated struct AXApplicationLifecycleStamp: Hashable, Sendable {
    let processIdentifier: Int32
    let epoch: AXApplicationLifecycleEpoch
}

/// Generic transport wrapper for either one process snapshot or a value/group
/// within a full snapshot. It contains no AX handle and can cross executors.
nonisolated struct AXApplicationLifecycleValue<Value: Sendable>: Sendable {
    let lifecycle: AXApplicationLifecycleStamp
    let value: Value
}

/// Tracks the currently accepted application incarnation for every PID.
/// `beginLifecycle` always creates a new epoch, even when the PID is already
/// present, so an explicit launch/reuse observation invalidates the previous
/// incarnation. Ordinary full scans use `currentOrBeginLifecycle` to retain the
/// existing epoch.
nonisolated struct AXApplicationLifecycleTracker: Sendable {
    private var nextRawValue: UInt64 = 0
    private var currentEpochByProcessIdentifier:
        [Int32: AXApplicationLifecycleEpoch] = [:]

    mutating func beginLifecycle(
        for processIdentifier: Int32
    ) -> AXApplicationLifecycleStamp {
        nextRawValue &+= 1
        if nextRawValue == 0 {
            nextRawValue = 1
        }
        let epoch = AXApplicationLifecycleEpoch(rawValue: nextRawValue)
        currentEpochByProcessIdentifier[processIdentifier] = epoch
        return AXApplicationLifecycleStamp(
            processIdentifier: processIdentifier,
            epoch: epoch
        )
    }

    mutating func currentOrBeginLifecycle(
        for processIdentifier: Int32
    ) -> AXApplicationLifecycleStamp {
        currentStamp(for: processIdentifier)
            ?? beginLifecycle(for: processIdentifier)
    }

    func currentStamp(
        for processIdentifier: Int32
    ) -> AXApplicationLifecycleStamp? {
        currentEpochByProcessIdentifier[processIdentifier].map {
            AXApplicationLifecycleStamp(
                processIdentifier: processIdentifier,
                epoch: $0
            )
        }
    }

    mutating func endLifecycle(for processIdentifier: Int32) {
        currentEpochByProcessIdentifier.removeValue(
            forKey: processIdentifier
        )
    }

    func isCurrent(_ stamp: AXApplicationLifecycleStamp) -> Bool {
        currentEpochByProcessIdentifier[stamp.processIdentifier]
            == stamp.epoch
    }

    func filteringCurrent<Value: Sendable>(
        _ values: [AXApplicationLifecycleValue<Value>]
    ) -> [AXApplicationLifecycleValue<Value>] {
        values.filter { isCurrent($0.lifecycle) }
    }
}

/// Hostless policy for classifying per-attribute AX failures. Unsupported
/// optional attributes and genuine no-value responses are stable absence;
/// every failure of a required identity attribute, and every other remote
/// failure, is inconclusive and must retain last-known-good state.
nonisolated enum AXAttributeReadPreservationPolicy {
    private static let success: Int32 = 0
    private static let attributeUnsupported: Int32 = -25205
    private static let noValue: Int32 = -25212

    static func shouldPreserveLastKnown(
        statusRawValue: Int32,
        required: Bool
    ) -> Bool {
        guard statusRawValue != success else { return false }
        if required {
            return true
        }
        return statusRawValue != attributeUnsupported
            && statusRawValue != noValue
    }
}

/// A candidate can replace its immutable DTO and action handle only after its
/// complete decode succeeds and app-specific filtering accepts it. Otherwise
/// both pieces of last-known-good state remain untouched.
nonisolated enum AXWindowDecodeCommitPolicy {
    static func shouldCommit(
        decodeIsConclusive: Bool,
        candidateIsAccepted: Bool
    ) -> Bool {
        decodeIsConclusive && candidateIsAccepted
    }

    static func allowsHeuristicRebinding(
        processSnapshotIsConclusive: Bool
    ) -> Bool {
        processSnapshotIsConclusive
    }
}

/// A bounded AX list request asks for one sentinel value beyond the number it
/// will publish. Receiving that sentinel proves truncation, so unseen prior
/// identities cannot be deleted.
nonisolated enum AXBoundedEnumerationPolicy {
    static func isComplete(
        returnedCount: Int,
        publishedLimit: Int
    ) -> Bool {
        returnedCount <= max(publishedLimit, 0)
    }
}

/// AX actions are replayed only when the API proves the proxy itself was
/// invalid. Busy/transport failures are ambiguous and may mean the operation
/// already happened, so retrying them could double-apply a close or resize.
nonisolated enum AXActionRetryPolicy {
    private static let invalidUIElement: Int32 = -25202

    static func shouldRefreshAndRetry(
        statusRawValue: Int32,
        alreadyRetried: Bool
    ) -> Bool {
        !alreadyRetried && statusRawValue == invalidUIElement
    }
}

/// Enforces the user-command recovery budget independently of the AX client.
/// A stale action may perform one bounded application-window list request to
/// look for the exact same AX object. It never reads attributes from candidate
/// windows synchronously; stronger rebinding is left to cooperative snapshots.
nonisolated struct AXActionRecoveryBudget: Sendable {
    static let maximumCandidateAttributeReads = 0

    private(set) var remainingSynchronousEnumerations: Int

    init(maximumSynchronousEnumerations: Int = 1) {
        remainingSynchronousEnumerations =
            max(maximumSynchronousEnumerations, 0)
    }

    mutating func consumeSynchronousEnumeration() -> Bool {
        guard remainingSynchronousEnumerations > 0 else { return false }
        remainingSynchronousEnumerations -= 1
        return true
    }
}

/// Shared cancellation/lifecycle gate used immediately before an AX action.
nonisolated enum AXActionExecutionPolicy {
    static func shouldProceed(
        isCancelled: Bool,
        lifecycleIsCurrent: Bool
    ) -> Bool {
        !isCancelled && lifecycleIsCurrent
    }
}

/// Closing through the standard button is a compatibility fallback only when
/// the target explicitly reports that the direct AXClose action is unsupported.
/// Transport and busy errors are ambiguous and must never trigger another
/// potentially destructive mechanism.
nonisolated enum AXCloseFallbackPolicy {
    private static let actionUnsupported: Int32 = -25206

    static func shouldAttemptButton(directStatusRawValue: Int32) -> Bool {
        directStatusRawValue == actionUnsupported
    }
}

/// Pure identity reducer for snapshot reliability. When any remote read was
/// inconclusive, last-known-good identities remain valid; only a fully
/// successful enumeration is allowed to prove that an unseen window vanished.
nonisolated enum AXSnapshotIdentityReducer {
    static func retainedIDs<ID: Hashable & Sendable>(
        previous: Set<ID>,
        discovered: Set<ID>,
        preserveUnseen: Bool
    ) -> Set<ID> {
        preserveUnseen ? previous.union(discovered) : discovered
    }
}

/// Maintains one immutable snapshot value per stable identity while retaining
/// the position at which that identity first appeared. Later values replace
/// stale last-known-good copies in place instead of producing duplicate UI
/// rows when one sibling window transiently fails to decode.
nonisolated enum AXSnapshotValueReducer {
    static func upsert<Value: Identifiable>(
        _ value: Value,
        into values: inout [Value]
    ) where Value.ID: Hashable {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }

    static func deduplicated<Value: Identifiable>(
        _ values: [Value]
    ) -> [Value] where Value.ID: Hashable {
        var result: [Value] = []
        result.reserveCapacity(values.count)
        for value in values {
            upsert(value, into: &result)
        }
        return result
    }
}
