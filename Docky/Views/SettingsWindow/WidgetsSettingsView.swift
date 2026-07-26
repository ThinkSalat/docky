//
//  WidgetsSettingsView.swift
//  Docky
//
//  Legacy external-widget inventory. Third-party bundles remain on disk
//  but are never installed or executed by Docky.
//

import AppKit
import SwiftUI

struct WidgetsSettingsView: View {
    @State private var bundleURLs: [URL] = []
    @State private var removalErrorMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Third-party widgets are disabled")
                            .font(.headline)
                        Text(
                            "Docky no longer installs, executes, or recursively removes external widget bundles in its own process. Existing files and profile records are preserved while a signed, notarized, isolated extension system is developed."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Existing Bundles (Inactive)") {
                if bundleURLs.isEmpty {
                    Text("No external widget bundles are installed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bundleURLs, id: \.standardizedFileURL) { url in
                        bundleRow(url)
                    }
                }
            }

            Section {
                Button {
                    revealWidgetsFolder()
                } label: {
                    Label("Reveal Widgets Folder", systemImage: "folder")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("External Widgets")
        .onAppear(perform: refresh)
        .alert(
            "Could not reveal widget folder",
            isPresented: removalErrorBinding,
            presenting: removalErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {
                removalErrorMessage = nil
            }
        } message: { message in
            Text(message)
        }
    }

    private func bundleRow(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .frame(width: 32, height: 32)
                .foregroundStyle(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                Text("Inactive")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

        }
    }

    private func refresh() {
        bundleURLs = ExternalWidgetLoader.shared.installedBundleURLs()
    }

    private func revealWidgetsFolder() {
        do {
            let directory =
                try ExternalWidgetLoader.shared.validatedWidgetsDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            removalErrorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Docky's Widgets folder has an unsafe path."
        }
    }

    private var removalErrorBinding: Binding<Bool> {
        Binding(
            get: { removalErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    removalErrorMessage = nil
                }
            }
        )
    }
}
