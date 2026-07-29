import Foundation
import XCTest

final class StartMenuEnablementPolicyTests: XCTestCase {
    func testDisabledInitializationRegistersNoHotKey() {
        let effects = StartMenuEnablementPolicy.effects(
            currentEnabled: false,
            isHotKeyRegistered: false,
            isPresented: false,
            requestedEnabled: false
        )

        XCTAssertEqual(effects.hotKeyAction, .none)
        XCTAssertEqual(effects.presentationAction, .none)
    }

    func testTurningFeatureOffUnregistersAndDismisses() {
        let effects = StartMenuEnablementPolicy.effects(
            currentEnabled: true,
            isHotKeyRegistered: true,
            isPresented: true,
            requestedEnabled: false
        )

        XCTAssertEqual(effects.hotKeyAction, .unregister)
        XCTAssertEqual(effects.presentationAction, .dismiss)
    }

    func testDisabledPresentAndToggleAreNoOps() {
        for command in [
            StartMenuEnablementPolicy.PresentationCommand.present,
            .toggle,
        ] {
            XCTAssertEqual(
                StartMenuEnablementPolicy.presentationAction(
                    for: command,
                    isEnabled: false,
                    isPresented: false
                ),
                .none
            )
        }
    }

    func testEnabledRegistrationOccursOnce() {
        let initialEffects = StartMenuEnablementPolicy.effects(
            currentEnabled: false,
            isHotKeyRegistered: false,
            isPresented: false,
            requestedEnabled: true
        )
        let reconciledEffects = StartMenuEnablementPolicy.effects(
            currentEnabled: true,
            isHotKeyRegistered: true,
            isPresented: false,
            requestedEnabled: true
        )

        XCTAssertEqual(initialEffects.hotKeyAction, .register)
        XCTAssertEqual(reconciledEffects.hotKeyAction, .none)
    }

    func testDisabledFeatureCannotBeInsertedFromPalette() {
        XCTAssertFalse(
            StartMenuEnablementPolicy.allowsPaletteInsertion(
                isEnabled: false
            )
        )
        XCTAssertTrue(
            StartMenuEnablementPolicy.allowsPaletteInsertion(
                isEnabled: true
            )
        )
    }

    func testRuntimeEntryPointsRetainIndependentEnablementChecks() throws {
        let service = try sourceFile("Docky/Services/StartMenuService.swift")
        let preferences = try sourceFile(
            "Docky/Services/DockyPreferences.swift"
        )
        let appDelegate = try sourceFile("Docky/AppDelegate.swift")

        XCTAssertTrue(
            service.contains(
                "DockyPreferences.shared.enablesStartMenuOverlay"
            )
        )
        XCTAssertTrue(
            service.contains(
                "StartMenuEnablementPolicy.presentationAction("
            )
        )
        XCTAssertTrue(
            service.contains(
                "guard DockyPreferences.shared.enablesStartMenuOverlay"
            ),
            "The Carbon callback must reject a stale queued event."
        )
        XCTAssertTrue(
            preferences.contains(
                "StartMenuService.shared.setEnabled("
            ),
            "The setting must synchronously reconcile runtime lifecycle."
        )
        XCTAssertTrue(
            appDelegate.contains(
                "guard DockyPreferences.shared.enablesStartMenuOverlay"
            ),
            "Disabled deep links must not initialize or present Start Menu."
        )
        let editor = try sourceFile(
            "Docky/Views/MainWindow/DockEditorOverlayWindowController.swift"
        )
        let editMode = try sourceFile(
            "Docky/Services/DockEditModeService.swift"
        )
        XCTAssertTrue(
            editor.contains(
                "StartMenuEnablementPolicy.allowsPaletteInsertion("
            ),
            "The editor must hide a disabled Start Menu tile."
        )
        XCTAssertTrue(
            editMode.contains(
                "StartMenuEnablementPolicy.allowsPaletteInsertion("
            ),
            "A stale disabled Start Menu palette drag must be rejected."
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
}
