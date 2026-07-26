//
//  ThemeManager.swift
//  Docky
//
//  Main-actor theme selection and immutable catalog publication. Catalog
//  scans run on ThemeStorageWorker so theme I/O never blocks dock interaction.
//  Runtime import, export, and deletion intentionally fail closed until all
//  theme-tree mutations use retained, descriptor-relative storage.
//

import Foundation
import Observation

@MainActor
@Observable final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var installedThemes: [String: InstalledTheme] = [:]
    private(set) var activeThemeID: String?
    private(set) var hasLoadedCatalog = false

    private let defaults: UserDefaults
    private let storageWorker: ThemeStorageWorker
    private var publishedCatalogRevision: UInt64 = 0

    private enum Keys {
        static let activeThemeID = "docky.activeThemeID"
    }

    /// Intentionally performs no filesystem work. App startup and the Themes
    /// settings pane explicitly call `bootstrap()` when they are ready to
    /// publish the first immutable catalog snapshot.
    private init() {
        defaults = .standard
        storageWorker = ThemeStorageWorker()
        activeThemeID = defaults.string(forKey: Keys.activeThemeID)
    }

    private static var bundledThemesDirectoryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(
            "Themes",
            isDirectory: true
        )
    }

    var themesDirectoryURL: URL {
        Self.themesDirectoryURL
    }

    var activeManifest: ThemeManifest? {
        guard let activeThemeID else { return nil }
        return installedThemes[activeThemeID]?.manifest
    }

    var activeBundleURL: URL? {
        guard let activeThemeID else { return nil }
        return installedThemes[activeThemeID]?.bundleURL
    }

    /// Pure cached resolution. Catalog assembly has already proven that the
    /// returned object is a contained regular file with no symlink component.
    func activeAssetURL(_ relativePath: String?) -> URL? {
        guard let relativePath,
              !relativePath.isEmpty,
              let activeThemeID,
              let activeTheme = installedThemes[activeThemeID] else {
            return nil
        }
        return activeTheme.assetURL(for: relativePath)
    }

    func activeAppIconURL(
        forBundleIdentifier bundleIdentifier: String
    ) -> URL? {
        guard !bundleIdentifier.isEmpty, let activeThemeID else {
            return nil
        }
        return installedThemes[activeThemeID]?
            .appIconURLsByBundleIdentifier[bundleIdentifier]
    }

    func activeAppIconBundleIDs() -> [String] {
        guard let activeThemeID,
              let theme = installedThemes[activeThemeID] else {
            return []
        }
        return Array(theme.appIconURLsByBundleIdentifier.keys)
    }

    func setActive(_ id: String) {
        guard installedThemes[id] != nil, activeThemeID != id else {
            return
        }
        activeThemeID = id
        defaults.set(id, forKey: Keys.activeThemeID)
        IconCacheService.shared.invalidate()
    }

    func clearActive() {
        guard activeThemeID != nil else { return }
        activeThemeID = nil
        defaults.removeObject(forKey: Keys.activeThemeID)
        IconCacheService.shared.invalidate()
    }

    /// Explicit, nonblocking first load. Repeated calls after a successful
    /// bootstrap are cheap no-ops; callers can use `refreshInstalled()` for a
    /// deliberate rescan.
    func bootstrap() async throws {
        guard !hasLoadedCatalog else { return }
        try await refreshInstalled()
    }

    func refreshInstalled() async throws {
        let snapshot = try await storageWorker.refreshCatalog(
            bundledDirectoryURL: Self.bundledThemesDirectoryURL,
            userDirectoryURL: themesDirectoryURL
        )
        publish(snapshot)
    }

    func deleteTheme(id _: String) async throws {
        try ThemeRuntimeMutationPolicy.reject(.deleteTheme)
    }

    @discardableResult
    func importTheme(from _: URL) async throws -> ThemeManifest {
        try ThemeRuntimeMutationPolicy.reject(.importTheme)
    }

    @discardableResult
    func exportCurrentAppearance(
        name _: String,
        to _: URL
    ) async throws -> URL {
        try ThemeRuntimeMutationPolicy.reject(.exportTheme)
    }

    private func publish(_ snapshot: ThemeCatalogSnapshot) {
        guard snapshot.revision > publishedCatalogRevision else { return }
        publishedCatalogRevision = snapshot.revision
        installedThemes = snapshot.installedThemes
        hasLoadedCatalog = true

        if let activeThemeID, installedThemes[activeThemeID] == nil {
            self.activeThemeID = nil
            defaults.removeObject(forKey: Keys.activeThemeID)
        }
        // Asset contents may change while all paths and manifest values remain
        // equal (for example, replacing cover_image.png in-place).
        IconCacheService.shared.invalidate()
    }

    private static var themesDirectoryURL: URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return base
            .appendingPathComponent("Docky", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }
}
