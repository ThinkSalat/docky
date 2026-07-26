import XCTest

final class DockVisibilityReducerTests: XCTestCase {
    private let leaseID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testNormalAutohideOffRemainsVisibleWithoutAnyHold() {
        let decision = DockVisibilityReducer.reduce(makeInputs())

        XCTAssertEqual(decision.visibility, .visible)
        XCTAssertFalse(decision.effectivelyAutohides)
        XCTAssertFalse(decision.contentOverlapHidingActive)
    }

    func testFullscreenHideIsTransientAndDoesNotChangeAutohidePreference() {
        var inputs = makeInputs(fullscreenHidingActive: true)

        let fullscreenDecision = DockVisibilityReducer.reduce(inputs)
        XCTAssertEqual(fullscreenDecision.visibility, .hidden)
        XCTAssertTrue(fullscreenDecision.effectivelyAutohides)
        XCTAssertFalse(inputs.autohidePreferenceEnabled)

        inputs.fullscreenHidingActive = false
        let normalDecision = DockVisibilityReducer.reduce(inputs)
        XCTAssertEqual(normalDecision.visibility, .visible)
        XCTAssertFalse(normalDecision.effectivelyAutohides)
        XCTAssertFalse(inputs.autohidePreferenceEnabled)
    }

    func testFullscreenPointerRequiresFreshRevealAuthorization() {
        var inputs = makeInputs(
            fullscreenHidingActive: true,
            pointerInside: true
        )

        let beforeDwell = DockVisibilityReducer.reduce(inputs)
        XCTAssertEqual(beforeDwell.visibility, .hidden)
        XCTAssertTrue(beforeDwell.requiresPointerRevealAuthorization)

        inputs.pointerRevealAuthorized = true
        let afterDwell = DockVisibilityReducer.reduce(inputs)
        XCTAssertEqual(afterDwell.visibility, .visible)
        XCTAssertFalse(afterDwell.requiresPointerRevealAuthorization)
    }

    func testClearingTransitionLeaseIDsRemovesStaleVisibilityHold() {
        var inputs = makeInputs(
            fullscreenHidingActive: true,
            activeInteractionLeaseIDs: [leaseID]
        )

        XCTAssertEqual(DockVisibilityReducer.reduce(inputs).visibility, .visible)

        inputs.activeInteractionLeaseIDs.removeAll()
        XCTAssertEqual(DockVisibilityReducer.reduce(inputs).visibility, .hidden)
    }

    func testLeaseVisibilityDoesNotAuthorizeFullscreenPointerReveal() {
        var inputs = makeInputs(
            fullscreenHidingActive: true,
            pointerInside: true,
            pointerRevealAuthorized: false,
            activeInteractionLeaseIDs: [leaseID]
        )

        let whilePresented = DockVisibilityReducer.reduce(inputs)
        XCTAssertEqual(whilePresented.visibility, .visible)
        XCTAssertTrue(whilePresented.requiresPointerRevealAuthorization)
        XCTAssertTrue(
            whilePresented.interactionLeaseBlocksPointerRevealAuthorization
        )
        XCTAssertFalse(inputs.pointerRevealAuthorized)

        inputs.activeInteractionLeaseIDs.removeAll()
        let afterPresenterCloses = DockVisibilityReducer.reduce(inputs)
        XCTAssertEqual(afterPresenterCloses.visibility, .hidden)
        XCTAssertTrue(afterPresenterCloses.requiresPointerRevealAuthorization)
        XCTAssertFalse(
            afterPresenterCloses.interactionLeaseBlocksPointerRevealAuthorization
        )
        XCTAssertFalse(inputs.pointerRevealAuthorized)
    }

    func testLeaseAlreadyActiveWhenPointerEntersBlocksRevealDwell() {
        let beforePointerEntry = DockVisibilityReducer.reduce(
            makeInputs(
                fullscreenHidingActive: true,
                activeInteractionLeaseIDs: [leaseID]
            )
        )
        XCTAssertEqual(beforePointerEntry.visibility, .visible)
        XCTAssertFalse(beforePointerEntry.requiresPointerRevealAuthorization)

        let afterPointerEntry = DockVisibilityReducer.reduce(
            makeInputs(
                fullscreenHidingActive: true,
                pointerInside: true,
                activeInteractionLeaseIDs: [leaseID]
            )
        )
        XCTAssertEqual(afterPointerEntry.visibility, .visible)
        XCTAssertTrue(afterPointerEntry.requiresPointerRevealAuthorization)
        XCTAssertTrue(
            afterPointerEntry.interactionLeaseBlocksPointerRevealAuthorization
        )
    }

    func testNormalAutohideUsesPointerLeaseEditAndDragHolds() {
        let noHold = makeInputs(autohidePreferenceEnabled: true)
        XCTAssertEqual(DockVisibilityReducer.reduce(noHold).visibility, .hidden)

        XCTAssertEqual(
            DockVisibilityReducer.reduce(
                makeInputs(autohidePreferenceEnabled: true, pointerInside: true)
            ).visibility,
            .visible
        )
        XCTAssertEqual(
            DockVisibilityReducer.reduce(
                makeInputs(
                    autohidePreferenceEnabled: true,
                    activeInteractionLeaseIDs: [leaseID]
                )
            ).visibility,
            .visible
        )
        XCTAssertEqual(
            DockVisibilityReducer.reduce(
                makeInputs(autohidePreferenceEnabled: true, editModeActive: true)
            ).visibility,
            .visible
        )
        XCTAssertEqual(
            DockVisibilityReducer.reduce(
                makeInputs(autohidePreferenceEnabled: true, dragActive: true)
            ).visibility,
            .visible
        )
    }

    func testMaximizedHideUsesSameTransientPolicy() {
        let decision = DockVisibilityReducer.reduce(
            makeInputs(maximizedHidingActive: true)
        )

        XCTAssertEqual(decision.visibility, .hidden)
        XCTAssertTrue(decision.contentOverlapHidingActive)
        XCTAssertTrue(decision.effectivelyAutohides)
    }

    private func makeInputs(
        autohidePreferenceEnabled: Bool = false,
        fullscreenHidingActive: Bool = false,
        maximizedHidingActive: Bool = false,
        pointerInside: Bool = false,
        pointerRevealAuthorized: Bool = false,
        activeInteractionLeaseIDs: Set<UUID> = [],
        editModeActive: Bool = false,
        dragActive: Bool = false
    ) -> DockVisibilityInputs {
        DockVisibilityInputs(
            autohidePreferenceEnabled: autohidePreferenceEnabled,
            fullscreenHidingActive: fullscreenHidingActive,
            maximizedHidingActive: maximizedHidingActive,
            pointerInside: pointerInside,
            pointerRevealAuthorized: pointerRevealAuthorized,
            activeInteractionLeaseIDs: activeInteractionLeaseIDs,
            editModeActive: editModeActive,
            dragActive: dragActive
        )
    }
}
