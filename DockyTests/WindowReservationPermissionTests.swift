import Combine
import Foundation
import XCTest

final class WindowReservationPermissionTests: XCTestCase {
    func testDeniedResizeModeStartsCapabilityRecheck() {
        let transition = WindowReservationActivationPolicy.reduce(
            current: WindowReservationActivationState(),
            resizeWindowsSelected: true,
            accessibilityGranted: false
        )

        XCTAssertEqual(
            transition.state,
            WindowReservationActivationState(
                reservationActive: false,
                accessibilityMonitorActive: true
            )
        )
        XCTAssertEqual(transition.reservationChange, .unchanged)
        XCTAssertEqual(transition.accessibilityMonitorChange, .start)
    }

    func testGrantStartsReservationAndKeepsRevocationMonitor() {
        let denied = WindowReservationActivationPolicy.reduce(
            current: WindowReservationActivationState(),
            resizeWindowsSelected: true,
            accessibilityGranted: false
        )
        let granted = WindowReservationActivationPolicy.reduce(
            current: denied.state,
            resizeWindowsSelected: true,
            accessibilityGranted: true
        )

        XCTAssertEqual(
            granted.state,
            WindowReservationActivationState(
                reservationActive: true,
                accessibilityMonitorActive: true
            )
        )
        XCTAssertEqual(granted.reservationChange, .start)
        XCTAssertEqual(
            granted.accessibilityMonitorChange,
            .unchanged
        )
    }

    func testRevocationDetachesReservationAndKeepsMonitor() {
        let transition = WindowReservationActivationPolicy.reduce(
            current: WindowReservationActivationState(
                reservationActive: true,
                accessibilityMonitorActive: true
            ),
            resizeWindowsSelected: true,
            accessibilityGranted: false
        )

        XCTAssertEqual(
            transition.state,
            WindowReservationActivationState(
                reservationActive: false,
                accessibilityMonitorActive: true
            )
        )
        XCTAssertEqual(transition.reservationChange, .stop)
        XCTAssertEqual(
            transition.accessibilityMonitorChange,
            .unchanged
        )
    }

    func testOtherModeNeitherReservesNorWatches() {
        let transition = WindowReservationActivationPolicy.reduce(
            current: WindowReservationActivationState(
                reservationActive: true,
                accessibilityMonitorActive: true
            ),
            resizeWindowsSelected: false,
            accessibilityGranted: true
        )

        XCTAssertEqual(
            transition.state,
            WindowReservationActivationState()
        )
        XCTAssertEqual(transition.reservationChange, .stop)
        XCTAssertEqual(
            transition.accessibilityMonitorChange,
            .stop
        )
    }

    func testRepeatedStateProducesNoLifecycleEffects() {
        let current = WindowReservationActivationState(
            reservationActive: false,
            accessibilityMonitorActive: true
        )
        let transition = WindowReservationActivationPolicy.reduce(
            current: current,
            resizeWindowsSelected: true,
            accessibilityGranted: false
        )

        XCTAssertEqual(transition.state, current)
        XCTAssertEqual(transition.reservationChange, .unchanged)
        XCTAssertEqual(
            transition.accessibilityMonitorChange,
            .unchanged
        )
    }

    @MainActor
    func testEventMonitorForwardsOnlyWhileStarted() {
        let events = PassthroughSubject<Void, Never>()
        var refreshCount = 0
        let monitor = WindowReservationPermissionEventMonitor(
            events: events.eraseToAnyPublisher(),
            onEvent: { refreshCount += 1 }
        )

        events.send(())
        XCTAssertEqual(refreshCount, 0)

        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        events.send(())
        XCTAssertEqual(refreshCount, 1)

        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        events.send(())
        XCTAssertEqual(refreshCount, 1)
    }

    func testServiceWiresCapabilityScopedWorkspaceRecheck() throws {
        let source = try sourceFile(
            "Docky/Services/WindowReservationService.swift"
        )

        XCTAssertTrue(
            source.contains(
                "WindowReservationActivationPolicy.reduce("
            )
        )
        XCTAssertTrue(
            source.contains(
                "NSWorkspace.didActivateApplicationNotification"
            )
        )
        XCTAssertTrue(
            source.contains("refreshAccessibilityStatus()")
        )
        XCTAssertTrue(
            source.contains("accessibilityMonitor.stop()")
        )
    }

    func testResizeSettingSurfacesExactRecoveryActions() throws {
        let source = try sourceFile(
            "Docky/Views/SettingsWindow/BehaviorSettingsView.swift"
        )

        XCTAssertTrue(
            source.contains(
                "permissions.accessibility != .granted"
            )
        )
        XCTAssertTrue(
            source.contains("Open Accessibility Settings")
        )
        XCTAssertTrue(source.contains("Show Current Docky.app"))
        XCTAssertTrue(source.contains("remove that entry"))
        XCTAssertTrue(
            source.contains("refreshAccessibilityStatus()")
        )
        XCTAssertFalse(
            source.contains("Grant Accessibility Access")
        )
    }

    func testTargetedRefreshDoesNotRefreshOtherCapabilities() throws {
        let source = try sourceFile(
            "Docky/Services/PermissionsService.swift"
        )
        let method = try sourceSection(
            in: source,
            startingAt:
                "    func refreshAccessibilityStatus()"
                + " -> PermissionStatus {",
            endingAt:
                "    private func "
                + "recordPermissionDiagnosticsIfNeeded("
        )

        XCTAssertTrue(method.contains("updateAccessibilityStatus()"))
        XCTAssertTrue(
            method.contains("recordPermissionDiagnosticsIfNeeded(")
        )
        XCTAssertFalse(method.contains("refreshScreenCapture()"))
        XCTAssertFalse(method.contains("refreshLocation()"))
        XCTAssertFalse(method.contains("refreshCalendar()"))
        XCTAssertFalse(method.contains("refreshReminders()"))
        XCTAssertFalse(method.contains("refreshFinderAutomation()"))
        XCTAssertFalse(
            method.contains("refreshSystemEventsAutomation()")
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
        startingAt start: String,
        endingAt end: String
    ) throws -> Substring {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(
                of: end,
                range: startRange.upperBound..<source.endIndex
            )
        )
        return source[startRange.lowerBound..<endRange.lowerBound]
    }
}
