//
//  FeedbackSettingsView.swift
//  Docky
//
//  Lets the user submit a textual report and an optional user-picked asset.
//  Docky still records its bounded privacy-safe diagnostics trace locally,
//  but automatic archive export remains fail-closed until a descriptor-bound
//  ZIP implementation can replace the pathname-based system archiver.
//
//  Delivery is via macOS's built-in share sheet, `NSSharingService`
//  composed for email when Mail.app is configured, otherwise a
//  picker (`NSSharingServicePicker`) so the user can route through
//  Messages / AirDrop / Files / etc. Zero backend; the only cost is
//  the user pressing "Send" in whichever app they pick.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let feedbackDestinationEmail = "hello@quintero.gt"

struct FeedbackSettingsView: View {
    @State private var feedbackText: String = ""
    @State private var attachmentURL: URL?

    var body: some View {
        Form {
            Section("What's going on?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe the issue, idea, or feedback. Your message and optional attachment are shared directly; Docky does not upload anything itself.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $feedbackText)
                        .font(.body)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if feedbackText.isEmpty {
                                Text("Describe the steps to reproduce, or what you'd like to see…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
                .padding(.vertical, 4)
            }

            Section("Attachment (optional)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Choose Screenshot / Video…") { chooseAttachment() }
                        if attachmentURL != nil {
                            Button("Clear") { attachmentURL = nil }
                        }
                        Spacer()
                    }
                    if let attachmentURL {
                        Text(attachmentURL.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Text("Optional, a screen recording or screenshot helps explain UI issues. Images and videos are supported.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("What gets sent") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Your message", systemImage: "text.alignleft")
                    if attachmentURL != nil {
                        Label("Your attachment", systemImage: "paperclip")
                    }
                    Text("Recent Docky diagnostics remain on this Mac. Automatic diagnostic archive export is temporarily disabled until it can be implemented without granting a pathname-based archiver Docky's permissions.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save Diagnostic Bundle…") {}
                        .disabled(true)
                        .help("Temporarily unavailable while Docky's diagnostic exporter is made descriptor-safe.")
                    Button("Send Feedback") { sendFeedback() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachmentURL = url
    }

    private func sendFeedback() {
        let message = feedbackText
        var items: [Any] = [message as NSString]
        if let attachmentURL {
            // The sharing service receives the picker-selected URL directly;
            // Docky never opens or copies the attachment with its permissions.
            items.append(attachmentURL as NSURL)
        }
        present(items: items)
    }

    /// Tries `NSSharingService.composeEmail` first (one-click into
    /// Mail.app with our address pre-filled). Falls back to a generic
    /// `NSSharingServicePicker` if Mail.app isn't configured.
    private func present(items: [Any]) {
        let subject = "Docky Feedback (v\(Bundle.main.shortVersion))"
        if let mail = NSSharingService(named: .composeEmail) {
            mail.recipients = [feedbackDestinationEmail]
            mail.subject = subject
            mail.perform(withItems: items)
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(
            relativeTo: .zero,
            of: window.contentView ?? NSView(),
            preferredEdge: .minY
        )
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}

/// Captures only the AppKit state that must be read on MainActor. UserDefaults,
/// CFPreferences, and property-list/JSON serialization are deferred to the
/// cancellable builder below after the progress state is already visible.
@MainActor
private enum FeedbackBundleCapture {
    static func suggestedFileName() -> String {
        "docky-diagnostics-\(timestamp()).zip"
    }

    static func input(
        feedbackText: String,
        attachmentURL: URL?
    ) -> FeedbackBundleCaptureInput {
        let diagnosticsSource = DiagnosticsTrace.shared.makeExportSource()

        return FeedbackBundleCaptureInput(
            feedbackText: feedbackText,
            system: systemSnapshot(),
            attachmentURL: attachmentURL,
            diagnostics: FeedbackDiagnosticsSnapshot {
                destinationDirectory in
                try diagnosticsSource.copyRetainedLogs(
                    to: destinationDirectory
                )
            }
        )
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func systemSnapshot() -> FeedbackSystemSnapshot {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersion
        return FeedbackSystemSnapshot(
            dockyVersion: Bundle.main.shortVersion,
            dockyBuild:
                (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                ?? "?",
            macosVersion:
                "\(osVersion.majorVersion).\(osVersion.minorVersion)."
                + "\(osVersion.patchVersion)",
            macosVersionString: processInfo.operatingSystemVersionString,
            processorCount: processInfo.processorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            locale: Locale.current.identifier,
            screens: NSScreen.screens.map {
                FeedbackScreenSnapshot(
                    frame: NSStringFromRect($0.frame),
                    visibleFrame: NSStringFromRect($0.visibleFrame),
                    backingScaleFactor: $0.backingScaleFactor,
                    localizedName: $0.localizedName
                )
            }
        )
    }
}

private nonisolated struct FeedbackBundleCaptureInput: Sendable {
    let feedbackText: String
    let system: FeedbackSystemSnapshot
    let attachmentURL: URL?
    let diagnostics: FeedbackDiagnosticsSnapshot
}

private nonisolated struct FeedbackSystemSnapshot: Codable, Sendable {
    let dockyVersion: String
    let dockyBuild: String
    let macosVersion: String
    let macosVersionString: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let locale: String
    let screens: [FeedbackScreenSnapshot]
}

private nonisolated struct FeedbackScreenSnapshot: Codable, Sendable {
    let frame: String
    let visibleFrame: String
    let backingScaleFactor: CGFloat
    let localizedName: String
}

private nonisolated enum FeedbackBundleCaptureBuilder {
    static func snapshot(
        from input: FeedbackBundleCaptureInput
    ) async throws -> FeedbackBundleSnapshot {
        let task: Task<FeedbackBundleSnapshot, Error> = Task.detached(
            priority: .userInitiated
        ) {
            try Task.checkCancellation()
            let dockyDefaults = FeedbackBundlePrivacy.dockyDefaults(
                from: UserDefaults.standard.dictionaryRepresentation()
            )
            let dockyDefaultsPlist = try plistData(dockyDefaults)
            try Task.checkCancellation()
            let dockPlist = try DockPlistReader.read().map(plistData)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let systemJSON = try encoder.encode(input.system)
            try Task.checkCancellation()
            return FeedbackBundleSnapshot(
                feedbackText: input.feedbackText,
                dockyDefaultsPlist: dockyDefaultsPlist,
                dockPlist: dockPlist,
                systemJSON: systemJSON,
                attachmentURL: input.attachmentURL,
                diagnostics: input.diagnostics
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func plistData(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }
}
