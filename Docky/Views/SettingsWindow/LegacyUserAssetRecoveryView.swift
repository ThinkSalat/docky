import SwiftUI

/// Explicit recovery UI for custom-image preferences written by Docky builds
/// that rendered directly from user-selected source paths.
///
/// Rendering this view performs lexical candidate discovery only. Legacy
/// files are read exclusively after the user presses Recover.
struct LegacyUserAssetRecoveryView: View {
    @Bindable private var preferences = DockyPreferences.shared
    @State private var isRecovering = false
    @State private var lastSummary: LegacyUserAssetRecoverySummary?

    private var candidateCount: Int {
        preferences.legacyUserAssetRecoveryCandidates.count
    }

    var body: some View {
        if candidateCount > 0 || lastSummary != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(
                            systemName: candidateCount > 0
                                ? "photo.badge.exclamationmark"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(
                            candidateCount > 0 ? Color.orange : Color.green
                        )
                        .font(.title3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                candidateCount > 0
                                    ? "Recover Custom Images"
                                    : "Custom Image Recovery Finished"
                            )
                            .font(.headline)

                            if candidateCount > 0 {
                                Text(recoveryExplanation)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                            } else {
                                Text(
                                    completionExplanation
                                )
                                .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 8)
                    }

                    if let lastSummary,
                       lastSummary.failedCount > 0
                            || lastSummary.staleCount > 0 {
                        Text(resultExplanation(lastSummary))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        if candidateCount > 0 {
                            Button("Recover \(candidateCount) Image\(candidateCount == 1 ? "" : "s")") {
                                recover()
                            }
                            .disabled(isRecovering)

                            if isRecovering {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Recovering…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Dismiss") {
                                lastSummary = nil
                            }
                        }
                    }
                }
                .padding(4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var recoveryExplanation: String {
        "Docky found \(candidateCount) custom image setting\(candidateCount == 1 ? "" : "s") from an older build. The paths remain saved, but Docky will not read them until you choose Recover. Recovery copies accessible images into Docky’s managed storage; inaccessible images and their settings are left unchanged."
    }

    private var completionExplanation: String {
        guard let lastSummary else {
            return "There are no custom images waiting for recovery."
        }
        if lastSummary.recoveredCount > 0 {
            return "Docky copied \(lastSummary.recoveredCount) image\(lastSummary.recoveredCount == 1 ? "" : "s") into its managed storage."
        }
        return "No custom-image settings were overwritten."
    }

    private func resultExplanation(
        _ summary: LegacyUserAssetRecoverySummary
    ) -> String {
        var parts: [String] = []
        if summary.failedCount > 0 {
            parts.append(
                "\(summary.failedCount) image\(summary.failedCount == 1 ? "" : "s") could not be read. Re-select those images from their original setting to grant access again."
            )
        }
        if summary.staleCount > 0 {
            let verb = summary.staleCount == 1 ? "was" : "were"
            parts.append(
                "\(summary.staleCount) setting\(summary.staleCount == 1 ? "" : "s") changed during recovery and \(verb) not overwritten."
            )
        }
        return parts.joined(separator: " ")
    }

    private func recover() {
        guard !isRecovering else { return }
        isRecovering = true
        lastSummary = nil
        Task {
            lastSummary = await preferences.recoverLegacyUserAssets()
            isRecovering = false
        }
    }
}
