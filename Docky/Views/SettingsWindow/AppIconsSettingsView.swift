//
//  AppIconsSettingsView.swift
//  Docky
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppIconsSettingsView: View {
    @Bindable private var preferences = DockyPreferences.shared
    @ObservedObject private var workspace = WorkspaceService.shared
    @State private var appEntries: [AppIconSettingsEntry] = []
    @State private var folderEntries: [FolderIconSettingsEntry] = []
    @State private var metadataRequestGeneration: UInt64 = 0
    @State private var otherApps: [AppIconSettingsEntry] = []
    @State private var otherAppsLoaded = false
    @State private var otherAppsRequestGeneration: UInt64 = 0

    var body: some View {
        Form {
            Section("Trash") {
                Text("Pick custom images for the Trash tile's empty and full states. Both default to the system Trash icons.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(TrashIconState.allCases) { state in
                    TrashIconOverrideRow(state: state)
                        .padding(.vertical, 4)
                }
            }

            Section("Folders") {
                Text("Pick custom images for any folder tile currently in the dock. Each folder defaults to its system icon.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if folderEntries.isEmpty {
                    Text("No folder tiles are currently in the dock.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folderEntries) { entry in
                        FolderIconOverrideRow(entry: entry)
                            .padding(.vertical, 4)
                    }
                }
            }

            Section("Launchpad") {
                Text("Pick a custom image for the Launchpad tile. Defaults to the system Launchpad icon.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LaunchpadIconOverrideRow()
                    .padding(.vertical, 4)
            }

            Section("Start Menu") {
                Text("Pick a custom image for the Start Menu tile. Defaults to Docky's own app icon.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                StartMenuIconOverrideRow()
                    .padding(.vertical, 4)
            }

            Section("Overrides") {
                Text("Choose a custom image for any app Docky currently knows about. Custom app icons follow Docky's circle tile clipping when circle tiles are enabled.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if appEntries.isEmpty {
                    Text("No apps are currently available for icon overrides.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appEntries) { entry in
                        AppIconOverrideRow(entry: entry)
                            .padding(.vertical, 4)
                    }
                }
            }

            Section("Other Apps") {
                Text("Apps installed on this Mac that aren't currently in your dock. Set their icon ahead of time and it'll be ready when you add them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !otherAppsLoaded {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning…")
                            .foregroundStyle(.secondary)
                    }
                } else if otherApps.isEmpty {
                    Text("No other apps found in /Applications, /System/Applications, or ~/Applications.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(otherApps) { entry in
                        AppIconOverrideRow(entry: entry)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: metadataRequest) {
            await refreshMetadata(for: metadataRequest)
        }
        .task(id: dockBundleIDsSignature) {
            await refreshOtherApps()
        }
    }

    /// A value-only description of the settings rows. Building it reads only
    /// Docky's already-published model state; LaunchServices and filesystem
    /// metadata resolution happen later on the metadata worker.
    private var metadataRequest: AppIconSettingsMetadataRequest {
        var bundleIdentifiers: Set<String> = ["com.apple.finder"]
        bundleIdentifiers.formUnion(workspace.runningApps.map(\.bundleIdentifier))
        bundleIdentifiers.formUnion(preferences.appIconOverrides.map(\.bundleIdentifier))
        bundleIdentifiers.formUnion(preferences.widgetPlacements.map(\.ownerBundleIdentifier))

        for item in preferences.pinnedItems {
            if let bundleIdentifier = item.bundleIdentifier {
                bundleIdentifiers.insert(bundleIdentifier)
            }

            bundleIdentifiers.formUnion(item.folderBundleIdentifiers)
        }

        var seenPaths: Set<String> = []
        let folders = preferences.trailingItems.compactMap {
            item -> FolderIconSettingsMetadataRequest? in
            guard item.kind == .folder, let url = item.folderURL else {
                return nil
            }
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return nil }
            return FolderIconSettingsMetadataRequest(
                folderPath: path,
                preferredDisplayName: item.folderDisplayName
            )
        }

        return AppIconSettingsMetadataRequest(
            bundleIdentifiers: bundleIdentifiers.sorted(),
            folders: folders
        )
    }

    private func refreshMetadata(
        for request: AppIconSettingsMetadataRequest
    ) async {
        metadataRequestGeneration &+= 1
        let generation = metadataRequestGeneration
        let worker = Task.detached(priority: .userInitiated) {
            AppIconSettingsMetadataLoader.load(request)
        }
        let snapshot = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled,
              metadataRequestGeneration == generation,
              metadataRequest == request else {
            return
        }

        appEntries = snapshot.apps
        folderEntries = snapshot.folders
    }

    /// Stable string fingerprint of every bundle id already shown in
    /// the Overrides section. When the dock's app set changes (pin,
    /// launch, drag) this re-fires `refreshOtherApps()` so a freshly
    /// pinned app moves out of "Other Apps" without a restart.
    private var dockBundleIDsSignature: String {
        appEntries.map(\.bundleIdentifier).sorted().joined(separator: ",")
    }

    /// Walks `/Applications`, `/System/Applications`, `~/Applications`
    /// (top level + one subfolder deep) off the main actor, then
    /// rebuilds `otherApps` with everything that isn't already in
    /// `appEntries`. Bundle ids are deduped; the first occurrence
    /// across roots wins (matching `LaunchpadOverlayService`).
    private func refreshOtherApps() async {
        otherAppsRequestGeneration &+= 1
        let generation = otherAppsRequestGeneration
        let excluded = Set(appEntries.map(\.bundleIdentifier))
        let worker = Task.detached(priority: .userInitiated) {
            AppIconsInstalledAppScanner.scan()
        }
        let scanned = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        let filtered = scanned
            .filter { !excluded.contains($0.bundleIdentifier) }
            .sorted { lhs, rhs in
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if comparison == .orderedSame {
                    return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(rhs.bundleIdentifier) == .orderedAscending
                }
                return comparison == .orderedAscending
            }

        guard !Task.isCancelled,
              otherAppsRequestGeneration == generation,
              Set(appEntries.map(\.bundleIdentifier)) == excluded else {
            return
        }

        otherApps = filtered
        otherAppsLoaded = true
    }
}

private struct AppIconOverrideRow: View {
    let entry: AppIconSettingsEntry

    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AppIconSettingsPreview(
                    bundleIdentifier: entry.bundleIdentifier,
                    overrideURL: effectivePreviewURL,
                    placeholderSystemName: "app"
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.headline)

                    Text(entry.subtitle)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .textSelection(.enabled)

                    if let overrideName {
                        Text("Override: \(overrideName)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Choose Image...") {
                        chooseOverrideImage()
                    }

                    if let themeIconURL {
                        Button("Use Theme Icon") {
                            Task { @MainActor in
                                await preferences.setAppIconOverride(
                                    bundleIdentifier: entry.bundleIdentifier,
                                    iconPath: themeIconURL.path
                                )
                            }
                        }
                        .help("Pin the active theme's icon for this app as your override. Without this, the theme icon already applies; pinning it preserves the choice if you switch themes.")
                    }

                    if overrideEntry != nil {
                        Button("Clear") {
                            preferences.removeAppIconOverride(bundleIdentifier: entry.bundleIdentifier)
                        }
                    }
                }
            }

            if overrideEntry != nil {
                paddingSlider
            }
        }
    }

    /// Theme-supplied icon for this app, if the active theme ships
    /// one. `nil` when no theme is active or the theme doesn't have
    /// an `assets/<bundle-id>.<png|jpg|jpeg>` file.
    private var themeIconURL: URL? {
        ThemeManager.shared.activeAppIconURL(forBundleIdentifier: entry.bundleIdentifier)
    }

    /// Per-icon padding slider, shown only when an override is set. The
    /// fraction is stored as 0...0.5 of the smaller cell dimension and
    /// rendered as 0–50 % in the UI.
    private var paddingSlider: some View {
        HStack(spacing: 8) {
            Text("Padding")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: paddingFractionBinding, in: 0...0.5, step: 0.01)
                .controlSize(.small)

            Text("\(Int((overrideEntry?.paddingFraction ?? 0) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var paddingFractionBinding: Binding<CGFloat> {
        Binding(
            get: { overrideEntry?.paddingFraction ?? 0 },
            set: { newValue in
                let clamped = min(max(newValue, 0), 0.5)
                preferences.setAppIconPaddingFraction(
                    bundleIdentifier: entry.bundleIdentifier,
                    paddingFraction: clamped == 0 ? nil : clamped
                )
            }
        )
    }

    private var overrideEntry: AppIconOverride? {
        preferences.appIconOverride(forBundleIdentifier: entry.bundleIdentifier)
    }

    private var overrideName: String? {
        guard let iconPath = overrideEntry?.iconPath, !iconPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: iconPath).lastPathComponent
    }

    /// URL selection is a pure lookup in the managed-asset/theme catalogs.
    /// `CachedAsyncAppImage` performs any cold decode or LaunchServices icon
    /// fetch asynchronously and rejects stale results when this URL changes.
    private var effectivePreviewURL: URL? {
        preferences.effectiveAppIconOverrideURL(
            forBundleIdentifier: entry.bundleIdentifier
        )
    }

    private func chooseOverrideImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await preferences.setAppIconOverride(
                    bundleIdentifier: entry.bundleIdentifier,
                    iconPath: url.path
                )
            }
        }
    }
}

/// Async settings preview with the same configured-image → system-app-icon
/// fallback the old synchronous code provided. Both cold paths use the shared
/// cache components, so a corrupt/missing override cannot trigger body I/O or
/// leave the row without its ordinary app icon.
private struct AppIconSettingsPreview: View {
    let bundleIdentifier: String
    let overrideURL: URL?
    let placeholderSystemName: String

    var body: some View {
        if let overrideURL {
            CachedAsyncImageFile(url: overrideURL) {
                systemAppIcon
            } content: { image in
                rendered(image)
            }
        } else {
            systemAppIcon
        }
    }

    private var systemAppIcon: some View {
        CachedAsyncAppImage(
            bundleIdentifier: bundleIdentifier,
            overrideURL: nil
        ) {
            Image(systemName: placeholderSystemName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(5)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
        } content: { image in
            rendered(image)
        }
    }

    private func rendered(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 36, height: 36)
    }
}

private struct AppIconSettingsEntry: Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let subtitle: String

    var id: String { bundleIdentifier }
}

private struct AppIconSettingsMetadataRequest: Hashable, Sendable {
    let bundleIdentifiers: [String]
    let folders: [FolderIconSettingsMetadataRequest]
}

private struct FolderIconSettingsMetadataRequest: Hashable, Sendable {
    let folderPath: String
    let preferredDisplayName: String?
}

private struct AppIconSettingsMetadataSnapshot: Sendable {
    let apps: [AppIconSettingsEntry]
    let folders: [FolderIconSettingsEntry]
}

/// Resolves LaunchServices and filesystem display metadata away from
/// MainActor, publishing only immutable strings and URLs back to the view.
private nonisolated enum AppIconSettingsMetadataLoader {
    static func load(
        _ request: AppIconSettingsMetadataRequest
    ) -> AppIconSettingsMetadataSnapshot {
        var apps: [AppIconSettingsEntry] = []
        for bundleIdentifier in request.bundleIdentifiers {
            guard !Task.isCancelled else { break }
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
            let displayName = appURL.map {
                FileManager.default.displayName(atPath: $0.path)
            } ?? bundleIdentifier
            let subtitle = appURL == nil
                ? "\(bundleIdentifier) • App not currently found on disk"
                : bundleIdentifier

            apps.append(AppIconSettingsEntry(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                subtitle: subtitle
            ))
        }
        apps.sort(by: appEntrySort)

        var folders: [FolderIconSettingsEntry] = []
        for folder in request.folders {
            guard !Task.isCancelled else { break }
            let displayName: String
            if let preferred = folder.preferredDisplayName,
               !preferred.isEmpty {
                displayName = preferred
            } else {
                displayName = FileManager.default.displayName(
                    atPath: folder.folderPath
                )
            }
            folders.append(FolderIconSettingsEntry(
                folderPath: folder.folderPath,
                displayName: displayName,
                folderURL: URL(
                    fileURLWithPath: folder.folderPath,
                    isDirectory: true
                )
            ))
        }
        folders.sort(by: folderEntrySort)

        return AppIconSettingsMetadataSnapshot(
            apps: apps,
            folders: folders
        )
    }

    private static func appEntrySort(
        _ lhs: AppIconSettingsEntry,
        _ rhs: AppIconSettingsEntry
    ) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
            rhs.displayName
        )
        if comparison == .orderedSame {
            return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(
                rhs.bundleIdentifier
            ) == .orderedAscending
        }
        return comparison == .orderedAscending
    }

    private static func folderEntrySort(
        _ lhs: FolderIconSettingsEntry,
        _ rhs: FolderIconSettingsEntry
    ) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
            rhs.displayName
        )
        if comparison == .orderedSame {
            return lhs.folderPath.localizedCaseInsensitiveCompare(
                rhs.folderPath
            ) == .orderedAscending
        }
        return comparison == .orderedAscending
    }
}

/// Off-main scanner that walks the standard application directories
/// and returns one `AppIconSettingsEntry` per discovered `.app`.
/// Bundle ids are deduped (first occurrence wins). Skips Docky
/// itself so users can't accidentally override the running app's
/// own icon. Icons are *not* loaded here — preview rows fetch them
/// lazily from `IconCacheService` so a 200-app scan stays cheap.
private nonisolated enum AppIconsInstalledAppScanner {
    static func scan() -> [AppIconSettingsEntry] {
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appending(path: "Applications", directoryHint: .isDirectory),
        ]

        let fileManager = FileManager.default
        let selfBundleIdentifier = Bundle.main.bundleIdentifier
        var seen: [String: AppIconSettingsEntry] = [:]

        for root in roots {
            guard !Task.isCancelled else { break }
            guard let topLevel = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in topLevel {
                guard !Task.isCancelled else { break }
                if url.pathExtension == "app" {
                    addEntry(at: url, into: &seen, skipping: selfBundleIdentifier)
                    continue
                }

                // One subfolder deep covers `/Applications/Utilities`
                // and similar collection directories without
                // wandering into arbitrary user folders.
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }

                guard let nested = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for nestedURL in nested where nestedURL.pathExtension == "app" {
                    guard !Task.isCancelled else { break }
                    addEntry(at: nestedURL, into: &seen, skipping: selfBundleIdentifier)
                }
            }
        }

        return Array(seen.values)
    }

    private static func addEntry(
        at url: URL,
        into entries: inout [String: AppIconSettingsEntry],
        skipping selfBundleIdentifier: String?
    ) {
        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier != selfBundleIdentifier,
              entries[bundleIdentifier] == nil else { return }

        let displayName = FileManager.default.displayName(atPath: url.path)
        entries[bundleIdentifier] = AppIconSettingsEntry(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            subtitle: bundleIdentifier
        )
    }
}

private struct TrashIconOverrideRow: View {
    let state: TrashIconState

    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                CachedAsyncImageFile(url: overrideEntry?.effectiveIconURL) {
                    Image(nsImage: NSImage(named: state.systemImageName) ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                } content: { image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash (\(state.title))")
                        .font(.headline)

                    Text(state == .empty
                         ? "Shown when the Trash is empty."
                         : "Shown when the Trash has items.")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    if let overrideName {
                        Text("Override: \(overrideName)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Choose Image...") {
                        chooseOverrideImage()
                    }

                    if overrideEntry != nil {
                        Button("Clear") {
                            preferences.removeTrashIconOverride(state: state)
                        }
                    }
                }
            }

            if overrideEntry != nil {
                paddingSlider
            }
        }
    }

    private var paddingSlider: some View {
        HStack(spacing: 8) {
            Text("Padding")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: paddingFractionBinding, in: 0...0.5, step: 0.01)
                .controlSize(.small)

            Text("\(Int((overrideEntry?.paddingFraction ?? 0) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var paddingFractionBinding: Binding<CGFloat> {
        Binding(
            get: { overrideEntry?.paddingFraction ?? 0 },
            set: { newValue in
                let clamped = min(max(newValue, 0), 0.5)
                preferences.setTrashIconPaddingFraction(
                    state: state,
                    paddingFraction: clamped == 0 ? nil : clamped
                )
            }
        )
    }

    private var overrideEntry: TrashIconOverride? {
        preferences.trashIconOverride(forState: state)
    }

    private var overrideName: String? {
        guard let iconPath = overrideEntry?.iconPath, !iconPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: iconPath).lastPathComponent
    }

    private func chooseOverrideImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await preferences.setTrashIconOverride(
                    state: state,
                    iconPath: url.path
                )
            }
        }
    }
}

private struct FolderIconSettingsEntry: Identifiable, Sendable {
    let folderPath: String
    let displayName: String
    let folderURL: URL

    var id: String { folderPath }
}

private struct FolderIconOverrideRow: View {
    let entry: FolderIconSettingsEntry

    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                CachedAsyncImageFile(url: overrideEntry?.effectiveIconURL) {
                    CachedAsyncFileImage(url: entry.folderURL) {
                        Image(systemName: "folder")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    } content: { image in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                    }
                } content: { image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.headline)

                    Text(entry.folderPath)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let overrideName {
                        Text("Override: \(overrideName)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Choose Image...") {
                        chooseOverrideImage()
                    }

                    if overrideEntry != nil {
                        Button("Clear") {
                            preferences.removeFolderIconOverride(folderPath: entry.folderPath)
                        }
                    }
                }
            }

            if overrideEntry != nil {
                paddingSlider
            }
        }
    }

    private var paddingSlider: some View {
        HStack(spacing: 8) {
            Text("Padding")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: paddingFractionBinding, in: 0...0.5, step: 0.01)
                .controlSize(.small)

            Text("\(Int((overrideEntry?.paddingFraction ?? 0) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var paddingFractionBinding: Binding<CGFloat> {
        Binding(
            get: { overrideEntry?.paddingFraction ?? 0 },
            set: { newValue in
                let clamped = min(max(newValue, 0), 0.5)
                preferences.setFolderIconPaddingFraction(
                    folderPath: entry.folderPath,
                    paddingFraction: clamped == 0 ? nil : clamped
                )
            }
        )
    }

    private var overrideEntry: FolderIconOverride? {
        preferences.folderIconOverride(forPath: entry.folderPath)
    }

    private var overrideName: String? {
        guard let iconPath = overrideEntry?.iconPath, !iconPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: iconPath).lastPathComponent
    }

    private func chooseOverrideImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await preferences.setFolderIconOverride(
                    folderPath: entry.folderPath,
                    iconPath: url.path
                )
            }
        }
    }
}

private struct LaunchpadIconOverrideRow: View {
    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AppIconSettingsPreview(
                    bundleIdentifier: LaunchpadTile.spotlightBundleIdentifier,
                    overrideURL: preferences.effectiveLaunchpadIconOverrideURL,
                    placeholderSystemName: "square.grid.3x3.fill"
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Launchpad")
                        .font(.headline)

                    Text("Replaces the Launchpad tile's icon.")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    if let overrideName {
                        Text("Override: \(overrideName)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Choose Image...") {
                        chooseOverrideImage()
                    }

                    if hasOverride {
                        Button("Clear") {
                            preferences.clearUserAsset(
                                slot: "special-icon:launchpad"
                            ) {
                                preferences.launchpadIconPath = nil
                                preferences.launchpadIconPaddingFraction = nil
                            }
                        }
                    }
                }
            }

            if hasOverride {
                paddingSlider
            }
        }
    }

    private var paddingSlider: some View {
        HStack(spacing: 8) {
            Text("Padding")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: paddingFractionBinding, in: 0...0.5, step: 0.01)
                .controlSize(.small)

            Text("\(Int((preferences.launchpadIconPaddingFraction ?? 0) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var paddingFractionBinding: Binding<CGFloat> {
        Binding(
            get: { preferences.launchpadIconPaddingFraction ?? 0 },
            set: { newValue in
                let clamped = min(max(newValue, 0), 0.5)
                preferences.launchpadIconPaddingFraction = clamped == 0 ? nil : clamped
            }
        )
    }

    private var hasOverride: Bool {
        guard let path = preferences.launchpadIconPath else { return false }
        return !path.isEmpty
    }

    private var overrideName: String? {
        guard let path = preferences.launchpadIconPath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func chooseOverrideImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                guard let path = await preferences.importUserAssetPath(
                    from: url,
                    slot: "special-icon:launchpad"
                ) else {
                    return
                }
                preferences.commitImportedUserAssetPath(
                    path,
                    slot: "special-icon:launchpad"
                ) {
                    preferences.launchpadIconPath = $0
                }
            }
        }
    }
}

private struct StartMenuIconOverrideRow: View {
    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AppIconSettingsPreview(
                    bundleIdentifier: StartMenuTile.iconBundleIdentifier,
                    overrideURL: preferences.effectiveStartMenuIconOverrideURL,
                    placeholderSystemName: "square.grid.2x2.fill"
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Menu")
                        .font(.headline)

                    Text("Replaces the Start Menu tile's icon.")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    if let overrideName {
                        Text("Override: \(overrideName)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Choose Image...") {
                        chooseOverrideImage()
                    }

                    if hasOverride {
                        Button("Clear") {
                            preferences.clearUserAsset(
                                slot: "special-icon:start-menu"
                            ) {
                                preferences.startMenuIconPath = nil
                                preferences.startMenuIconPaddingFraction = nil
                            }
                        }
                    }
                }
            }

            if hasOverride {
                paddingSlider
            }
        }
    }

    private var paddingSlider: some View {
        HStack(spacing: 8) {
            Text("Padding")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: paddingFractionBinding, in: 0...0.5, step: 0.01)
                .controlSize(.small)

            Text("\(Int((preferences.startMenuIconPaddingFraction ?? 0) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var paddingFractionBinding: Binding<CGFloat> {
        Binding(
            get: { preferences.startMenuIconPaddingFraction ?? 0 },
            set: { newValue in
                let clamped = min(max(newValue, 0), 0.5)
                preferences.startMenuIconPaddingFraction = clamped == 0 ? nil : clamped
            }
        )
    }

    private var hasOverride: Bool {
        guard let path = preferences.startMenuIconPath else { return false }
        return !path.isEmpty
    }

    private var overrideName: String? {
        guard let path = preferences.startMenuIconPath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func chooseOverrideImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                guard let path = await preferences.importUserAssetPath(
                    from: url,
                    slot: "special-icon:start-menu"
                ) else {
                    return
                }
                preferences.commitImportedUserAssetPath(
                    path,
                    slot: "special-icon:start-menu"
                ) {
                    preferences.startMenuIconPath = $0
                }
            }
        }
    }
}
