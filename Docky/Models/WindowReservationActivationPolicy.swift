//
//  WindowReservationActivationPolicy.swift
//  Docky
//
//  Pure lifecycle reducer for the Accessibility-backed window reservation
//  service. Keeping this independent from AppKit makes both reservation and
//  permission-recheck transitions directly testable in the hostless target.
//

import Combine

nonisolated struct WindowReservationActivationState:
    Equatable,
    Sendable
{
    let reservationActive: Bool
    let accessibilityMonitorActive: Bool

    init(
        reservationActive: Bool = false,
        accessibilityMonitorActive: Bool = false
    ) {
        self.reservationActive = reservationActive
        self.accessibilityMonitorActive = accessibilityMonitorActive
    }
}

nonisolated enum WindowReservationLifecycleChange:
    Equatable,
    Sendable
{
    case unchanged
    case start
    case stop
}

nonisolated struct WindowReservationActivationTransition:
    Equatable,
    Sendable
{
    let state: WindowReservationActivationState
    let reservationChange: WindowReservationLifecycleChange
    let accessibilityMonitorChange: WindowReservationLifecycleChange
}

nonisolated enum WindowReservationActivationPolicy {
    static func reduce(
        current: WindowReservationActivationState,
        resizeWindowsSelected: Bool,
        accessibilityGranted: Bool
    ) -> WindowReservationActivationTransition {
        let next = WindowReservationActivationState(
            reservationActive:
                resizeWindowsSelected && accessibilityGranted,
            accessibilityMonitorActive: resizeWindowsSelected
        )
        return WindowReservationActivationTransition(
            state: next,
            reservationChange: lifecycleChange(
                from: current.reservationActive,
                to: next.reservationActive
            ),
            accessibilityMonitorChange: lifecycleChange(
                from: current.accessibilityMonitorActive,
                to: next.accessibilityMonitorActive
            )
        )
    }

    private static func lifecycleChange(
        from current: Bool,
        to next: Bool
    ) -> WindowReservationLifecycleChange {
        guard current != next else { return .unchanged }
        return next ? .start : .stop
    }
}

/// Bridges a capability-scoped event stream to an authoritative permission
/// refresh. The monitor is idempotent and contains no timer or polling loop.
@MainActor
final class WindowReservationPermissionEventMonitor {
    private let events: AnyPublisher<Void, Never>
    private let onEvent: () -> Void
    private var cancellable: AnyCancellable?

    init(
        events: AnyPublisher<Void, Never>,
        onEvent: @escaping () -> Void
    ) {
        self.events = events
        self.onEvent = onEvent
    }

    var isRunning: Bool {
        cancellable != nil
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = events.sink { [weak self] _ in
            self?.onEvent()
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
