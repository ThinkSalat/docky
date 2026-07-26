//
//  HiddenAppsSettingsView.swift
//  Docky
//

import AppKit
import SwiftUI

struct HiddenAppsSettingsView: View {
    @Bindable private var preferences = DockyPreferences.shared
    @State private var hiddenApps: [HiddenAppSettingsEntry] = []
    @State private var metadataRequestGeneration: UInt64 = 0

    var body: some View {
        Form {
            Section("Restore") {
                Text("Apps hidden with \"Hide in Docky\" stay out of Docky's pinned and running app surfaces until you restore them here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if hiddenApps.isEmpty {
                    Text("No apps are currently hidden from Docky.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hiddenApps) { app in
                        HiddenAppRow(app: app)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: metadataRequest) {
            await refreshMetadata(for: metadataRequest)
        }
    }

    /// Value-only request built from Docky's published preference state.
    /// LaunchServices and filesystem display-name work is deferred to the
    /// detached metadata loader below.
    private var metadataRequest: HiddenAppsMetadataRequest {
        let dockyBundleID = Bundle.main.bundleIdentifier
        return HiddenAppsMetadataRequest(
            bundleIdentifiers: preferences.hiddenAppBundleIdentifiers
            .filter { $0 != dockyBundleID }
            .sorted()
        )
    }

    private func refreshMetadata(
        for request: HiddenAppsMetadataRequest
    ) async {
        metadataRequestGeneration &+= 1
        let generation = metadataRequestGeneration
        let worker = Task.detached(priority: .userInitiated) {
            HiddenAppsMetadataLoader.load(request)
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

        hiddenApps = snapshot.entries
    }
}

private struct HiddenAppRow: View {
    let app: HiddenAppSettingsEntry

    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CachedAsyncAppImage(
                bundleIdentifier: app.bundleIdentifier,
                overrideURL: nil
            ) {
                Image(systemName: "app")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(5)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            } content: { image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.headline)

                Text(app.subtitle)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Show in Docky") {
                preferences.setAppHiddenInDocky(bundleIdentifier: app.bundleIdentifier, isHidden: false)
            }
        }
    }
}

private struct HiddenAppSettingsEntry: Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let subtitle: String

    var id: String { bundleIdentifier }
}

private struct HiddenAppsMetadataRequest: Hashable, Sendable {
    let bundleIdentifiers: [String]
}

private struct HiddenAppsMetadataSnapshot: Sendable {
    let entries: [HiddenAppSettingsEntry]
}

private nonisolated enum HiddenAppsMetadataLoader {
    static func load(
        _ request: HiddenAppsMetadataRequest
    ) -> HiddenAppsMetadataSnapshot {
        var entries: [HiddenAppSettingsEntry] = []
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

            entries.append(HiddenAppSettingsEntry(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                subtitle: subtitle
            ))
        }
        entries.sort { lhs, rhs in
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

        return HiddenAppsMetadataSnapshot(entries: entries)
    }
}
