//
//  FeedbackSettingsView.swift
//  Docky
//
//  Lets the user submit a textual report along with a self-contained
//  diagnostic zip. The zip bundles every `docky.*` UserDefaults key,
//  the live `com.apple.dock` plist, basic system specs, the bounded
//  privacy-safe diagnostics trace, and an optional user-picked asset
//  (screenshot / screen recording).
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
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("What's going on?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe the issue, idea, or feedback. The diagnostic bundle below is attached automatically so the maintainer can replicate your setup.")
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
                    Label("Docky preferences (every `docky.*` UserDefaults key)", systemImage: "doc.text")
                    Label("Live macOS Dock prefs (`com.apple.dock`)", systemImage: "dock.rectangle")
                    Label("Basic system info (macOS version, screens, Docky build)", systemImage: "info.circle")
                    Label("Recent Docky event trace (bounded; identifiers pseudonymized)", systemImage: "waveform.path.ecg")
                    if attachmentURL != nil {
                        Label("Your attachment", systemImage: "paperclip")
                    }
                    Text("The preference snapshots can include profile names, app identifiers, and file bookmarks. Nothing is shared until you choose a destination or complete the system share flow.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Save Diagnostic Bundle…") { saveDiagnosticBundle() }
                        .disabled(isPreparing)
                    Button("Send Feedback") { sendFeedback() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isPreparing || feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        errorMessage = nil
        isPreparing = true
        defer { isPreparing = false }

        do {
            let bundleURL = try FeedbackBundle.build(
                feedbackText: feedbackText,
                attachmentURL: attachmentURL
            )
            present(items: [feedbackText as NSString, bundleURL as NSURL])
            FeedbackBundle.scheduleCleanup(of: bundleURL)
        } catch {
            errorMessage = "Could not build feedback bundle: \(error.localizedDescription)"
        }
    }

    private func saveDiagnosticBundle() {
        errorMessage = nil
        isPreparing = true
        defer { isPreparing = false }

        do {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = FeedbackBundle.suggestedFileName()
            panel.canCreateDirectories = true
            panel.prompt = "Save"
            guard panel.runModal() == .OK, let destination = panel.url else {
                return
            }

            let bundleURL = try FeedbackBundle.build(
                feedbackText: feedbackText,
                attachmentURL: attachmentURL
            )
            defer {
                FeedbackBundle.removeTemporaryBundle(at: bundleURL)
            }

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: bundleURL, to: destination)
        } catch {
            errorMessage = "Could not save diagnostic bundle: \(error.localizedDescription)"
        }
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

/// Standalone helper so the build step is testable on its own and
/// nothing in the view code needs to know about plist serialization,
/// zipping, etc.
private enum FeedbackBundle {
    static func suggestedFileName() -> String {
        "docky-diagnostics-\(timestamp()).zip"
    }

    static func build(feedbackText: String, attachmentURL: URL?) throws -> URL {
        let fileManager = FileManager.default
        cleanupStaleTemporaryArtifacts()
        let identifier = "\(timestamp())-\(UUID().uuidString)"
        let stagingRoot = fileManager.temporaryDirectory
            .appending(path: "docky-feedback-\(identifier)", directoryHint: .isDirectory)
        let zipURL = stagingRoot.deletingLastPathComponent()
            .appending(path: stagingRoot.lastPathComponent + ".zip")
        var completedArchive = false
        defer {
            try? fileManager.removeItem(at: stagingRoot)
            if !completedArchive {
                try? fileManager.removeItem(at: zipURL)
            }
        }
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // 1. docky-defaults.plist, filtered to our namespace so we
        //    don't leak unrelated UserDefaults from other domains.
        let allDefaults = UserDefaults.standard.dictionaryRepresentation()
        let dockyDefaults = allDefaults.filter { $0.key.hasPrefix("docky.") }
        try writePlist(dockyDefaults, to: stagingRoot.appending(path: "docky-defaults.plist"))

        // 2. com.apple.dock plist, exact snapshot of system dock prefs.
        if let dockPlist = DockPlistReader.read() {
            try writePlist(dockPlist, to: stagingRoot.appending(path: "com.apple.dock.plist"))
        }

        // 3. system.json, Mac specs (kept minimal: no usernames or
        //    paths). Enough to tell apart "M1 Air on macOS 14" vs
        //    "Mac Pro on macOS 26".
        let system = systemSnapshot()
        try writeJSON(system, to: stagingRoot.appending(path: "system.json"))

        // 4. Bounded structural event trace. This contains state transitions,
        //    decisions, counts, and geometry, but never paths, window titles,
        //    profile names, or raw app identifiers.
        let diagnosticsDirectory = stagingRoot
            .appending(path: "diagnostics", directoryHint: .isDirectory)
        try DiagnosticsTrace.shared.copyRetainedLogs(to: diagnosticsDirectory)
        try """
        Docky diagnostics trace

        Format: newline-delimited JSON, one event per line.
        Retention: at most two 2 MiB generations.
        Privacy: no window titles, filenames, file paths, profile names, or raw app identifiers.
        Identifier tokens are scoped to one Docky launch and are useful only for correlation.
        """
        .write(
            to: diagnosticsDirectory.appending(path: "README.txt"),
            atomically: true,
            encoding: .utf8
        )
        try secureFile(
            at: diagnosticsDirectory.appending(path: "README.txt")
        )

        // 5. feedback.txt, verbatim user message.
        let feedbackURL = stagingRoot.appending(path: "feedback.txt")
        try feedbackText.write(
            to: feedbackURL,
            atomically: true,
            encoding: .utf8
        )
        try secureFile(at: feedbackURL)

        // 6. Optional asset, copied alongside (preserves original name).
        if let attachmentURL {
            let dest = stagingRoot.appending(path: attachmentURL.lastPathComponent)
            try fileManager.copyItem(at: attachmentURL, to: dest)
            try secureFile(at: dest)
        }

        // Zip into one cohesive attachment. The unzipped staging tree is
        // removed by defer on both success and failure.
        try ditto(source: stagingRoot, destination: zipURL)
        try secureFile(at: zipURL)
        completedArchive = true
        return zipURL
    }

    static func scheduleCleanup(of bundleURL: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3_600))
            removeTemporaryBundle(at: bundleURL)
        }
    }

    static func removeTemporaryBundle(at bundleURL: URL) {
        guard bundleURL.deletingLastPathComponent()
                == FileManager.default.temporaryDirectory,
              bundleURL.lastPathComponent.hasPrefix("docky-feedback-"),
              bundleURL.pathExtension == "zip"
        else { return }
        try? FileManager.default.removeItem(at: bundleURL)
    }

    private static func writePlist(_ value: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        try secureFile(at: url)
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        try secureFile(at: url)
    }

    private static func secureFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func cleanupStaleTemporaryArtifacts() {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-86_400)
        for entry in entries
            where entry.lastPathComponent.hasPrefix("docky-feedback-") {
            let modified = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func systemSnapshot() -> [String: Any] {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersion
        var screens: [[String: Any]] = []
        for screen in NSScreen.screens {
            screens.append([
                "frame": NSStringFromRect(screen.frame),
                "visibleFrame": NSStringFromRect(screen.visibleFrame),
                "backingScaleFactor": screen.backingScaleFactor,
                "localizedName": screen.localizedName
            ])
        }
        return [
            "dockyVersion": Bundle.main.shortVersion,
            "dockyBuild": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?",
            "macosVersion": "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            "macosVersionString": processInfo.operatingSystemVersionString,
            "processorCount": processInfo.processorCount,
            "physicalMemoryBytes": processInfo.physicalMemory,
            "locale": Locale.current.identifier,
            "screens": screens
        ]
    }

    /// Use `/usr/bin/ditto` for archiving, it produces a real macOS
    /// zip (preserves resource forks / extended attrs, deterministic,
    /// no third-party deps).
    private static func ditto(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FeedbackBundle", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ditto exited with status \(process.terminationStatus)"
            ])
        }
    }
}
