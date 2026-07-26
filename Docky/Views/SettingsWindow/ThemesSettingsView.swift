//
//  ThemesSettingsView.swift
//  Docky
//
//  Read-only catalog of installed `.dockytheme` bundles. Validated themes can
//  be activated, deactivated, revealed, and refreshed. Runtime import, export,
//  and deletion remain visibly unavailable while theme storage is secured.
//

import AppKit
import SwiftUI

struct ThemesSettingsView: View {
    @Bindable private var manager = ThemeManager.shared
    @Bindable private var preferences = DockyPreferences.shared
    @State private var errorPresentation: ThemeSettingsError?
    @State private var operation: ThemeSettingsOperation?
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Active") {
                if let active = manager.activeManifest {
                    activeThemeRow(active)
                } else {
                    Text("No theme is active. Your appearance customizations are applied directly.")
                        .foregroundStyle(.secondary)
                }

                if !preferences.userOverriddenAppearanceKeys.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You have \(preferences.userOverriddenAppearanceKeys.count) theme override(s).")
                                .font(.callout)
                            Text("These appearance and behavior choices take precedence over the active theme. Clear them to let the theme show through.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Clear Overrides") {
                            preferences.clearAllAppearanceOverrides()
                        }
                        .disabled(operation != nil)
                    }
                }
            }

            Section {
                Label {
                    Text(ThemeRuntimeMutationPolicy.unavailableExplanation)
                        .font(.callout)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .foregroundStyle(.secondary)
            }

            Section("Installed Themes") {
                let installed = manager.installedThemes.values
                    .sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }

                if installed.isEmpty, operation == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No themes installed yet.")
                            .font(.callout)
                        Text("Drop an unzipped `.dockytheme` folder into the Themes directory, then refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(installed, id: \.manifest.id) { theme in
                        installedThemeRow(theme)
                    }
                }
            }

            Section {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        themesActionButton(
                            "Reveal Themes Folder",
                            systemImage: "folder",
                            action: revealThemesFolder
                        )
                        themesActionButton(
                            "Refresh",
                            systemImage: "arrow.clockwise",
                            action: refreshThemes
                        )
                    }
                }
                .disabled(operation != nil)

                if let operation {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(operation.progressLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            errorPresentation?.title ?? "Theme operation failed",
            isPresented: errorBinding,
            presenting: errorPresentation
        ) { _ in
            Button("OK", role: .cancel) { errorPresentation = nil }
        } message: { error in
            Text(error.message)
        }
        .task {
            await performOperation(.loading) {
                try await manager.bootstrap()
            }
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func activeThemeRow(_ manifest: ThemeManifest) -> some View {
        HStack(spacing: 12) {
            ThemePreviewBadge(manifest: manifest)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.name)
                    .font(.headline)
                if let author = manifest.author, !author.isEmpty {
                    Text("by \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Deactivate") {
                manager.clearActive()
            }
            .disabled(operation != nil)
        }
    }

    @ViewBuilder
    private func installedThemeRow(_ theme: InstalledTheme) -> some View {
        let isActive = manager.activeThemeID == theme.manifest.id

        HStack(spacing: 12) {
            ThemePreviewBadge(manifest: theme.manifest)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(theme.manifest.name)
                        .font(.headline)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if theme.isBundled {
                        Text("Built-in")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if let author = theme.manifest.author, !author.isEmpty {
                    Text("by \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let description = theme.manifest.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)

            if isActive {
                Button("Deactivate") {
                    manager.clearActive()
                }
                .disabled(operation != nil)
            } else {
                Button("Apply") {
                    manager.setActive(theme.manifest.id)
                }
                .disabled(operation != nil)
            }

        }
    }

    // MARK: - Actions

    private func revealThemesFolder() {
        let url = manager.themesDirectoryURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshThemes() {
        startOperation(.refreshing) {
            try await manager.refreshInstalled()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorPresentation != nil },
            set: { newValue in
                if !newValue { errorPresentation = nil }
            }
        )
    }

    @MainActor
    private func startOperation(
        _ requestedOperation: ThemeSettingsOperation,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard operation == nil else { return }
        actionTask = Task {
            await performOperation(requestedOperation, action: action)
            actionTask = nil
        }
    }

    @MainActor
    private func performOperation(
        _ requestedOperation: ThemeSettingsOperation,
        action: @escaping @MainActor () async throws -> Void
    ) async {
        guard operation == nil else { return }
        operation = requestedOperation
        defer { operation = nil }
        do {
            try await action()
        } catch is CancellationError {
            return
        } catch {
            errorPresentation = ThemeSettingsError(
                title: requestedOperation.errorTitle,
                message: (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
    }

    /// Grid cell used for every Themes action button. Mirrors the
    /// onboarding's `.bordered` + `.large` styling so on macOS 26+
    /// each cell picks up the system Liquid Glass material for free,
    /// and stretches to fill its column for a uniform two-column row.
    @ViewBuilder
    private func themesActionButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

private enum ThemeSettingsOperation: Equatable {
    case loading
    case refreshing

    var progressLabel: String {
        switch self {
        case .loading: return "Loading themes…"
        case .refreshing: return "Refreshing themes…"
        }
    }

    var errorTitle: String {
        switch self {
        case .loading, .refreshing: return "Could not load themes"
        }
    }
}

private struct ThemeSettingsError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 16:9 cover/preview tile used in the installed-themes list.
///
/// Preference order:
///   1. `cover_image.png` (or `.jpg`/`.jpeg`) at the bundle root —
///      theme-author-supplied artwork.
///   2. The theme's `appearance.window.backgroundImage` asset,
///      scaled to fill — synthesizes a usable preview from the
///      same asset the dock chrome would render.
///   3. The manifest's `appearance.window.tintColor` — flat-color
///      placeholder so a bare manifest still reads visually.
///   4. A neutral secondary fill when none of the above apply.
private struct ThemePreviewBadge: View {
    let manifest: ThemeManifest

    private static let size = CGSize(width: 96, height: 54)
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        let tint = manifest.appearance.window?.tintColor?.nsColor
        let clipShape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        // The outer `.clipShape` guarantees the fill, image overlay,
        // and anything added later are all confined to the rounded
        // bounds — `scaledToFill` will gladly render outside the
        // frame, and per-image clipping has been forgotten before.
        ZStack {
            Rectangle()
                .fill(
                    tint.map(Color.init(nsColor:))
                        ?? Color.secondary.opacity(0.2)
                )
            CachedAsyncImageFile(url: previewImageURL) {
                EmptyView()
            } content: { image in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(clipShape)
            .overlay {
                clipShape.strokeBorder(.separator, lineWidth: 0.5)
            }
    }

    private var previewImageURL: URL? {
        guard let installed =
                ThemeManager.shared.installedThemes[manifest.id] else {
            return nil
        }
        if let coverImageURL = installed.coverImageURL {
            return coverImageURL
        }
        guard let backgroundImage =
                manifest.appearance.window?.backgroundImage else {
            return nil
        }
        return installed.assetURL(for: backgroundImage)
    }
}
