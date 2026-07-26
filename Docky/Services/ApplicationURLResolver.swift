//
//  ApplicationURLResolver.swift
//  Docky
//
//  Coalesces LaunchServices URL lookups away from MainActor.
//

import AppKit
import Foundation

actor ApplicationURLResolver {
    static let shared = ApplicationURLResolver()

    private nonisolated struct PendingResolution: Sendable {
        let id: UUID
        let generation: UInt64
        let task: Task<URL?, Never>
    }

    private var resolvedByBundleIdentifier: [String: URL] = [:]
    private var missingRetryUptimeByBundleIdentifier:
        [String: TimeInterval] = [:]
    private var inFlightByBundleIdentifier:
        [String: PendingResolution] = [:]
    private var generationByBundleIdentifier: [String: UInt64] = [:]

    /// Avoid hammering LaunchServices for a genuinely missing bundle while
    /// still allowing an app installed after a miss to become discoverable
    /// without requiring a Docky restart.
    private let missingRetryDelay: TimeInterval = 5

    func applicationURL(for bundleIdentifier: String) async -> URL? {
        if let resolved = resolvedByBundleIdentifier[bundleIdentifier] {
            return resolved
        }
        if let retryUptime =
            missingRetryUptimeByBundleIdentifier[bundleIdentifier] {
            if ProcessInfo.processInfo.systemUptime < retryUptime {
                return nil
            }
            missingRetryUptimeByBundleIdentifier.removeValue(
                forKey: bundleIdentifier
            )
        }
        if let pending = inFlightByBundleIdentifier[bundleIdentifier] {
            let resolved = await pending.task.value
            return finish(
                pending,
                bundleIdentifier: bundleIdentifier,
                resolved: resolved
            )
        }

        let generation =
            generationByBundleIdentifier[bundleIdentifier] ?? 0
        let task: Task<URL?, Never> = Task.detached(
            priority: .userInitiated
        ) {
            guard !Task.isCancelled else { return nil }
            let resolved = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
            return Task.isCancelled ? nil : resolved
        }
        let pending = PendingResolution(
            id: UUID(),
            generation: generation,
            task: task
        )
        inFlightByBundleIdentifier[bundleIdentifier] = pending
        let resolved = await task.value
        return finish(
            pending,
            bundleIdentifier: bundleIdentifier,
            resolved: resolved
        )
    }

    private func finish(
        _ pending: PendingResolution,
        bundleIdentifier: String,
        resolved: URL?
    ) -> URL? {
        guard generationByBundleIdentifier[bundleIdentifier] ?? 0
                == pending.generation else {
            return nil
        }

        // Multiple callers can await the same task. Only its current owner
        // mutates shared state, while every same-generation waiter receives
        // the result even after the first waiter removes the in-flight entry.
        if inFlightByBundleIdentifier[bundleIdentifier]?.id == pending.id {
            inFlightByBundleIdentifier.removeValue(
                forKey: bundleIdentifier
            )
            if let resolved {
                resolvedByBundleIdentifier[bundleIdentifier] = resolved
                missingRetryUptimeByBundleIdentifier.removeValue(
                    forKey: bundleIdentifier
                )
            } else {
                missingRetryUptimeByBundleIdentifier[bundleIdentifier] =
                    ProcessInfo.processInfo.systemUptime + missingRetryDelay
            }
        } else if inFlightByBundleIdentifier[bundleIdentifier] != nil {
            // A newer same-generation request owns this bundle identifier.
            // This should be rare, but an older result must never supersede it.
            return nil
        }

        return resolved
    }

    func invalidate(bundleIdentifier: String? = nil) {
        if let bundleIdentifier {
            generationByBundleIdentifier[bundleIdentifier, default: 0] &+= 1
            resolvedByBundleIdentifier.removeValue(
                forKey: bundleIdentifier
            )
            missingRetryUptimeByBundleIdentifier.removeValue(
                forKey: bundleIdentifier
            )
            inFlightByBundleIdentifier.removeValue(
                forKey: bundleIdentifier
            )?.task.cancel()
            return
        }

        let knownBundleIdentifiers =
            Set(resolvedByBundleIdentifier.keys)
            .union(missingRetryUptimeByBundleIdentifier.keys)
            .union(inFlightByBundleIdentifier.keys)
            .union(generationByBundleIdentifier.keys)
        for identifier in knownBundleIdentifiers {
            generationByBundleIdentifier[identifier, default: 0] &+= 1
        }
        resolvedByBundleIdentifier.removeAll()
        missingRetryUptimeByBundleIdentifier.removeAll()
        inFlightByBundleIdentifier.values.forEach { $0.task.cancel() }
        inFlightByBundleIdentifier.removeAll()
    }
}
