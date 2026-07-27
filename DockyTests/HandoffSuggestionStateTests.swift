import XCTest

final class HandoffSuggestionStateTests: XCTestCase {
    private let firefox = DockHandoffSuggestion(
        bundleIdentifier: "org.mozilla.firefox",
        displayName: "Firefox"
    )
    private let whatsapp = DockHandoffSuggestion(
        bundleIdentifier: "net.whatsapp.WhatsApp",
        displayName: "WhatsApp"
    )

    func testAvailableSuggestionPublishesImmediately() {
        var state = HandoffSuggestionState(missThreshold: 3)

        state.apply(.available(firefox))

        XCTAssertEqual(state.visibleSuggestion, firefox)
        XCTAssertEqual(state.consecutiveMissCount, 0)
    }

    func testSuggestionExpiresOnlyAfterConsecutiveConfirmedMisses() {
        var state = HandoffSuggestionState(missThreshold: 3)
        state.apply(.available(firefox))

        state.apply(.absent)
        state.apply(.unresolved)
        XCTAssertEqual(state.visibleSuggestion, firefox)
        XCTAssertEqual(state.consecutiveMissCount, 1)

        state.apply(.absent)
        XCTAssertEqual(state.visibleSuggestion, firefox)

        state.apply(.absent)
        XCTAssertNil(state.visibleSuggestion)
        XCTAssertEqual(state.consecutiveMissCount, 0)
    }

    func testInconclusiveScanPreservesSuggestionAndMissProgress() {
        var state = HandoffSuggestionState(missThreshold: 3)
        state.apply(.available(firefox))
        state.apply(.absent)

        state.apply(.inconclusive(errorCode: -25204))

        XCTAssertEqual(state.visibleSuggestion, firefox)
        XCTAssertEqual(state.consecutiveMissCount, 1)
    }

    func testPermissionLossClearsVisibleAndSuppressedState() {
        var state = HandoffSuggestionState(missThreshold: 3)
        state.apply(.available(firefox))
        XCTAssertTrue(
            state.markContinuationSucceeded(
                expectedBundleIdentifier:
                    firefox.bundleIdentifier
            )
        )

        state.apply(.permissionUnavailable)

        XCTAssertNil(state.visibleSuggestion)
        XCTAssertNil(state.suppressedBundleIdentifier)
        XCTAssertEqual(state.suppressionAbsenceCount, 0)
    }

    func testSuccessfulContinuationSuppressesSameSuggestionUntilItEnds() {
        var state = HandoffSuggestionState(missThreshold: 3)
        state.apply(.available(firefox))
        XCTAssertTrue(
            state.markContinuationSucceeded(
                expectedBundleIdentifier:
                    firefox.bundleIdentifier
            )
        )

        state.apply(.available(firefox))
        XCTAssertNil(state.visibleSuggestion)
        XCTAssertEqual(
            state.suppressedBundleIdentifier,
            firefox.bundleIdentifier
        )

        state.apply(.absent)
        state.apply(.absent)
        XCTAssertEqual(
            state.suppressedBundleIdentifier,
            firefox.bundleIdentifier
        )

        state.apply(.absent)
        XCTAssertNil(state.suppressedBundleIdentifier)

        state.apply(.available(firefox))
        XCTAssertEqual(state.visibleSuggestion, firefox)
    }

    func testReplacementSuggestionBypassesPriorSuppression() {
        var state = HandoffSuggestionState(missThreshold: 3)
        state.apply(.available(firefox))
        _ = state.markContinuationSucceeded(
            expectedBundleIdentifier:
                firefox.bundleIdentifier
        )

        state.apply(.available(whatsapp))

        XCTAssertEqual(state.visibleSuggestion, whatsapp)
        XCTAssertNil(state.suppressedBundleIdentifier)
    }

    func testStaleContinuationCannotSuppressReplacementSuggestion() {
        var state = HandoffSuggestionState(missThreshold: 3)
        state.apply(.available(whatsapp))

        XCTAssertFalse(
            state.markContinuationSucceeded(
                expectedBundleIdentifier:
                    firefox.bundleIdentifier
            )
        )
        XCTAssertEqual(state.visibleSuggestion, whatsapp)
        XCTAssertNil(state.suppressedBundleIdentifier)
    }

    func testStaleActionResultCannotClearReplacementSuggestion() {
        var state = HandoffSuggestionState(missThreshold: 3)
        state.apply(.available(whatsapp))

        XCTAssertFalse(
            state.clearVisibleSuggestion(
                expectedBundleIdentifier:
                    firefox.bundleIdentifier
            )
        )
        XCTAssertEqual(state.visibleSuggestion, whatsapp)

        XCTAssertTrue(
            state.clearVisibleSuggestion(
                expectedBundleIdentifier:
                    whatsapp.bundleIdentifier
            )
        )
        XCTAssertNil(state.visibleSuggestion)
    }
}
