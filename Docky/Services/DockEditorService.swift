//
//  DockEditorService.swift
//  Docky
//

import AppKit
import Foundation

final class DockEditorService {
    static let shared = DockEditorService()

    nonisolated private static let dockBundleIdentifier = "com.apple.dock"
    nonisolated private static let finderBundleIdentifier = "com.apple.finder"
    nonisolated private static let dockPlistFilename =
        "com.apple.dock.plist"
    private let worker = DockPlistEditingWorker()

    private init() {}

    @discardableResult
    func removePinnedApp(bundleIdentifier: String) async -> Bool {
        await setPinnedApp(bundleIdentifier: bundleIdentifier, pinned: false)
    }

    @discardableResult
    func setPinnedApp(
        bundleIdentifier: String,
        pinned: Bool
    ) async -> Bool {
        guard !bundleIdentifier.isEmpty, bundleIdentifier != Self.finderBundleIdentifier else {
            return false
        }

        let updated = await worker.perform {
            Self.updateDockPlist { plist in
                guard var apps =
                        plist["persistent-apps"] as? [[String: Any]] else {
                    return false
                }

                let existingIndex = apps.firstIndex { entry in
                    Self.pinnedAppBundleIdentifier(in: entry)
                        == bundleIdentifier
                }

                if pinned {
                    guard existingIndex == nil,
                          let entry = Self.makePinnedAppEntry(
                            bundleIdentifier: bundleIdentifier,
                            plist: plist
                          ) else {
                        return false
                    }
                    apps.append(entry)
                } else {
                    guard let existingIndex else {
                        return false
                    }
                    apps.remove(at: existingIndex)
                }

                plist["persistent-apps"] = apps
                return true
            }
        }

        guard updated else {
            return false
        }

        restartDock()
        TileStore.shared.refreshAfterDockyEditedSystemDock()
        return true
    }

    @discardableResult
    func setPinnedItemOrder(ids: [String]) async -> Bool {
        guard !ids.isEmpty else {
            return false
        }

        let updated = await worker.perform {
            Self.updateDockPlist { plist in
                guard let apps =
                        plist["persistent-apps"] as? [[String: Any]],
                      apps.count == ids.count else {
                    return false
                }

                let appsByID = Dictionary(
                    uniqueKeysWithValues: apps.enumerated().map {
                        index,
                        entry in
                        (
                            Self.pinnedItemID(in: entry, at: index),
                            entry
                        )
                    }
                )

                let orderedApps = ids.compactMap { appsByID[$0] }
                guard orderedApps.count == apps.count else {
                    return false
                }

                plist["persistent-apps"] = orderedApps
                return true
            }
        }

        guard updated else {
            return false
        }

        restartDock()
        TileStore.shared.refreshAfterDockyEditedSystemDock()
        return true
    }

    nonisolated private static func updateDockPlist(
        _ mutate: (inout [String: Any]) -> Bool
    ) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent(Self.dockPlistFilename)
        return updateDockPlist(at: url, mutate)
    }

    nonisolated private static func updateDockPlist(
        at url: URL,
        _ mutate: (inout [String: Any]) -> Bool
    ) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            return false
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = (try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )) as? [String: Any] else {
            return false
        }

        guard mutate(&plist) else {
            return false
        }

        guard let updatedData = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        ) else {
            return false
        }

        do {
            try updatedData.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func restartDock() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .forEach { $0.forceTerminate() }
    }

    nonisolated private static func pinnedAppBundleIdentifier(
        in entry: [String: Any]
    ) -> String? {
        let tileData = entry["tile-data"] as? [String: Any]
        let fileData = tileData?["file-data"] as? [String: Any]
        let urlString = fileData?["_CFURLString"] as? String
        let url = urlString.flatMap(URL.init(string:))

        return (tileData?["bundle-identifier"] as? String)
            ?? url.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    nonisolated private static func pinnedItemID(
        in entry: [String: Any],
        at index: Int
    ) -> String {
        if let guid = (entry["GUID"] as? NSNumber)?.stringValue {
            return guid
        }

        let tileType = (entry["tile-type"] as? String) ?? "unknown"
        let tileData = entry["tile-data"] as? [String: Any] ?? [:]
        let fileData = tileData["file-data"] as? [String: Any]
        let urlString = fileData?["_CFURLString"] as? String
        let bundleIdentifier = tileData["bundle-identifier"] as? String
        let label = tileData["file-label"] as? String

        let signature = [tileType, bundleIdentifier, urlString, label]
            .compactMap { $0?.replacingOccurrences(of: ":", with: "_") }
            .joined(separator: ":")

        if signature.isEmpty {
            return "persistent-apps:\(index):\(tileType)"
        }

        return "persistent-apps:\(index):\(signature)"
    }

    nonisolated private static func makePinnedAppEntry(
        bundleIdentifier: String,
        plist: [String: Any]
    ) -> [String: Any]? {
        if let recentApps = plist["recent-apps"] as? [[String: Any]],
           let existing = recentApps.first(where: {
               pinnedAppBundleIdentifier(in: $0) == bundleIdentifier
           }) {
            var copied = existing
            copied["GUID"] = NSNumber(value: Int.random(in: 1...Int(UInt32.max)))
            return copied
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let label = FileManager.default.displayName(atPath: appURL.path)
        let fileData: [String: Any] = [
            "_CFURLString": appURL.absoluteString,
            "_CFURLStringType": 15
        ]

        var tileData: [String: Any] = [
            "bundle-identifier": bundleIdentifier,
            "dock-extra": false,
            "file-data": fileData,
            "file-label": label,
            "is-beta": false
        ]

        if let bookmark = try? appURL.bookmarkData() {
            tileData["book"] = bookmark
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: appURL.path),
           let modificationDate = attributes[.modificationDate] as? Date {
            let modValue = plistDateValue(modificationDate)
            tileData["file-mod-date"] = modValue
            tileData["parent-mod-date"] = modValue
        }

        tileData["file-type"] = 1

        return [
            "GUID": NSNumber(value: Int.random(in: 1...Int(UInt32.max))),
            "tile-data": tileData,
            "tile-type": "file-tile"
        ]
    }

    nonisolated private static func plistDateValue(
        _ date: Date
    ) -> NSNumber {
        NSNumber(value: Int64(date.timeIntervalSinceReferenceDate * 1_000_000))
    }
}

private actor DockPlistEditingWorker {
    func perform(
        _ operation: @Sendable () -> Bool
    ) -> Bool {
        operation()
    }
}
