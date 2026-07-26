import XCTest

final class PresentationGenerationTests: XCTestCase {
    func testLatestTransitionTokenIsCurrent() {
        var generation = PresentationGeneration()

        let token = generation.advance()

        XCTAssertTrue(generation.isCurrent(token))
    }

    func testReopenInvalidatesPendingDismissal() {
        var generation = PresentationGeneration()
        let dismissal = generation.advance()

        _ = generation.advance()

        XCTAssertFalse(generation.isCurrent(dismissal))
    }

    func testLaterDismissalInvalidatesEarlierDismissal() {
        var generation = PresentationGeneration()
        let firstDismissal = generation.advance()
        let secondDismissal = generation.advance()

        XCTAssertFalse(generation.isCurrent(firstDismissal))
        XCTAssertTrue(generation.isCurrent(secondDismissal))
    }

    func testNestedMenuPresentersDoNotMintPostPopupGeneration() throws {
        for path in [
            "Docky/Views/Tiles/AppFolderTileView.swift",
            "Docky/Views/Tiles/TileView.swift",
        ] {
            let source = try sourceFile(path)
            let popupReturn = try XCTUnwrap(
                source.range(of: "            popUp(menu: menu, in: view)")
            )
            let close = try XCTUnwrap(
                source.range(
                    of: "        func close() {",
                    range: popupReturn.upperBound..<source.endIndex
                )
            )
            let completion =
                source[popupReturn.upperBound..<close.lowerBound]

            XCTAssertTrue(
                completion.contains(
                    "guard activePresentation == presentation else"
                ),
                path
            )
            XCTAssertTrue(
                completion.contains(
                    "presentationGeneration.isCurrent(presentation)"
                ),
                path
            )
            XCTAssertFalse(
                completion.contains("presentationGeneration.advance()"),
                path
            )
            XCTAssertTrue(
                completion.contains("pendingDismissal = presentation"),
                path
            )
            XCTAssertTrue(
                completion.contains(
                    "self.pendingDismissal == presentation"
                ),
                path
            )

            let closeSection = source[
                close.lowerBound..<source.index(
                    close.lowerBound,
                    offsetBy: min(
                        500,
                        source.distance(
                            from: close.lowerBound,
                            to: source.endIndex
                        )
                    )
                )
            ]
            XCTAssertTrue(closeSection.contains("activeMenu?.cancelTracking()"))
            XCTAssertTrue(closeSection.contains("activePresentation = nil"))
        }
    }

    func testListMenuIdentityChangesRetireTrackedPresentation() throws {
        let appFolderSource = try sourceFile(
            "Docky/Views/Tiles/AppFolderTileView.swift"
        )
        let appFolderUpdate = try sourceSection(
            in: appFolderSource,
            startingWith:
                "        func update(tile: AppFolderTile, tileID: String,",
            endingWith: "        func scheduleShow("
        )
        XCTAssertTrue(appFolderUpdate.contains("self.tileID != tileID"))
        XCTAssertTrue(
            appFolderUpdate.contains("retireCurrentPresentation()")
        )

        let appFolderRetirement = try sourceSection(
            in: appFolderSource,
            startingWith:
                "        private func retireCurrentPresentation()",
            endingWith: "        private func buildMenu()"
        )
        XCTAssertTrue(
            appFolderRetirement.contains("activeMenu?.cancelTracking()")
        )
        XCTAssertTrue(
            appFolderRetirement.contains("activePresentation = nil")
        )
        XCTAssertTrue(
            appFolderRetirement.contains("pendingDismissal = nil")
        )

        let folderSource = try sourceFile(
            "Docky/Views/Tiles/TileView.swift"
        )
        let folderPresenter = try sourceSection(
            in: folderSource,
            startingWith:
                "private struct FolderListMenuPresenter:",
            endingWith:
                "private final class FolderListMenuAnchorView:"
        )
        let folderUpdate = try sourceSection(
            in: String(folderPresenter),
            startingWith:
                "        func update(tile: FolderTile,",
            endingWith: "        func scheduleShow("
        )
        XCTAssertTrue(
            folderUpdate.contains(
                "self.tile.url.standardizedFileURL"
            )
        )
        XCTAssertTrue(
            folderUpdate.contains("retireCurrentPresentation()")
        )

        let folderRetirement = try sourceSection(
            in: String(folderPresenter),
            startingWith:
                "        private func retireCurrentPresentation()",
            endingWith: "        private func buildMenu("
        )
        XCTAssertTrue(
            folderRetirement.contains("activeMenu?.cancelTracking()")
        )
        XCTAssertTrue(
            folderRetirement.contains("pendingDismissal = nil")
        )
        XCTAssertTrue(
            folderRetirement.contains("rootLoadTask?.cancel()")
        )
    }

    func testAppFolderListActionsUseImmutablePresentationTargets() throws {
        let source = try sourceFile(
            "Docky/Views/Tiles/AppFolderTileView.swift"
        )
        let menuBuilder = try sourceSection(
            in: source,
            startingWith: "        private func buildMenu()",
            endingWith: "        private func listMenuIcon("
        )
        XCTAssertTrue(menuBuilder.contains("let presentedTile = tile"))
        XCTAssertTrue(menuBuilder.contains("let presentedTileID = tileID"))
        XCTAssertTrue(
            menuBuilder.contains(
                "presentedTile.apps.map(\\.bundleIdentifier)"
            )
        )
        XCTAssertTrue(
            menuBuilder.contains("AppFolderRemovalMenuTarget(")
        )

        let openAll = try sourceSection(
            in: source,
            startingWith:
                "        @objc private func openAllApps(",
            endingWith:
                "        @objc private func removeApp("
        )
        XCTAssertTrue(openAll.contains("sender.representedObject"))
        XCTAssertFalse(openAll.contains("tile.apps"))

        let removal = try sourceSection(
            in: source,
            startingWith:
                "        @objc private func removeApp(",
            endingWith: "        private func popUp("
        )
        XCTAssertTrue(removal.contains("target.tileID"))
        XCTAssertTrue(removal.contains("target.bundleIdentifier"))
        XCTAssertFalse(removal.contains("tileID: tileID"))
    }

    func testAppFolderListIconsAreCachedOnlyDuringMenuBuild() throws {
        let source = try sourceFile(
            "Docky/Views/Tiles/AppFolderTileView.swift"
        )
        let iconBuilder = try sourceSection(
            in: source,
            startingWith:
                "        private func listMenuIcon(",
            endingWith:
                "        private static let genericAppIcon"
        )
        XCTAssertTrue(
            iconBuilder.contains("cachedIcon(")
        )
        XCTAssertFalse(
            iconBuilder.contains("image(forImageFileURL:")
        )
        XCTAssertFalse(
            iconBuilder.contains("icon(forBundleIdentifier:")
        )

        let preload = try sourceSection(
            in: source,
            startingWith:
                "        private func startIconPreload(",
            endingWith:
                "        @objc private func openApp("
        )
        XCTAssertTrue(preload.contains("withTaskGroup"))
        XCTAssertTrue(preload.contains("loadImageAsync("))
        XCTAssertTrue(preload.contains("loadIconAsync("))
    }

    func testAsyncSubmenuKeepsStableGeometryAndChecksAttachment() throws {
        let source = try sourceFile(
            "Docky/Views/Tiles/ContextActionPopover.swift"
        )
        let controller = try sourceSection(
            in: source,
            startingWith:
                "private final class AsyncLazyMenuController:",
            endingWith: "\nfinal class AnchorView:"
        )
        XCTAssertTrue(
            controller.contains("loadingPlaceholderRowCount = 4")
        )
        XCTAssertTrue(
            controller.contains("installStableLoadingItems(in: menu)")
        )
        XCTAssertTrue(controller.contains("let provider = provider"))
        let providerAwait = try XCTUnwrap(
            controller.range(of: "let children = await provider()")
        )
        let strongSelf = controller.range(
            of: "guard let self",
            range: controller.startIndex..<providerAwait.lowerBound
        )
        XCTAssertNil(
            strongSelf,
            "The task must not retain its controller across a hung provider."
        )
        XCTAssertTrue(controller.contains("menu.supermenu != nil"))
        XCTAssertTrue(controller.contains("menu.update()"))
        XCTAssertTrue(controller.contains("_ = menu.size"))
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
        startingWith start: String,
        endingWith end: String
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
