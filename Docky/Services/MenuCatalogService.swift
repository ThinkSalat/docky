//
//  MenuCatalogService.swift
//  Docky
//

import AppKit
import Combine
import Foundation

private nonisolated struct MenuCatalogLoadResult: Sendable {
    let actionsDocument: MenuCatalogActionsDocumentDTO?
    let menusDocument: MenuCatalogMenusDocumentDTO?
    let errorDescription: String?
}

private nonisolated struct MenuCatalogActionsDocumentDTO:
    Decodable,
    Sendable {
    let version: Int
    let packages: [MenuCatalogActionPackageDTO]
}

private nonisolated struct MenuCatalogMenusDocumentDTO:
    Decodable,
    Sendable {
    let version: Int
    let menus: [MenuCatalogMenuDefinitionDTO]
}

private nonisolated struct MenuCatalogActionPackageDTO:
    Decodable,
    Sendable {
    let id: String
    let title: String
    let author: String
    let version: String
    let reviewStatus: String
    let description: String?
    let actions: [MenuCatalogActionDefinitionDTO]
}

private nonisolated struct MenuCatalogActionDefinitionDTO:
    Decodable,
    Sendable {
    let id: String
    let title: String
    let alternateTitle: String?
    let alternateTitleWhen: MenuCatalogConditionDTO?
    let kind: String
    let tileTypes: [String]
    let destructive: Bool
    let destructiveWhen: MenuCatalogConditionDTO?
    let toggleFlag: String?
    let when: MenuCatalogConditionDTO?
    let permissions: [String]
    let builtinIdentifier: String?
    let targetApp: String?
    let inputs: [String]
    let script: String?
    let path: [String]?
    let requiresFrontmost: Bool
    let holdOption: Bool
    let symbol: String?
}

private nonisolated struct MenuCatalogMenuDefinitionDTO:
    Decodable,
    Sendable {
    let tileType: String
    let items: [MenuCatalogMenuItemDefinitionDTO]
}

private nonisolated struct MenuCatalogMenuItemDefinitionDTO:
    Decodable,
    Sendable {
    let type: String
    let title: String?
    let action: String?
    let alternateAction: String?
    let alternateActionWhen: MenuCatalogConditionDTO?
    let when: MenuCatalogConditionDTO?
    let children: [MenuCatalogMenuItemDefinitionDTO]?
}

private nonisolated indirect enum MenuCatalogConditionDTO:
    Decodable,
    Sendable {
    case flag(String)
    case bundleIdentifierEquals(String)
    case all([MenuCatalogConditionDTO])
    case any([MenuCatalogConditionDTO])
    case not(MenuCatalogConditionDTO)

    private enum CodingKeys: String, CodingKey {
        case flag
        case bundleIdentifierEquals
        case all
        case any
        case not
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let flag = try container.decodeIfPresent(
            String.self,
            forKey: .flag
        ) {
            self = .flag(flag)
            return
        }
        if let bundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .bundleIdentifierEquals
        ) {
            self = .bundleIdentifierEquals(bundleIdentifier)
            return
        }
        if let conditions = try container.decodeIfPresent(
            [MenuCatalogConditionDTO].self,
            forKey: .all
        ) {
            self = .all(conditions)
            return
        }
        if let conditions = try container.decodeIfPresent(
            [MenuCatalogConditionDTO].self,
            forKey: .any
        ) {
            self = .any(conditions)
            return
        }
        if let condition = try container.decodeIfPresent(
            MenuCatalogConditionDTO.self,
            forKey: .not
        ) {
            self = .not(condition)
            return
        }

        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription:
                "Catalog condition must define a supported condition key."
        ))
    }
}

final class MenuCatalogService: ObservableObject {
    static let shared = MenuCatalogService()

    @Published private(set) var packageSummaries: [CatalogPackageSummary] = []
    @Published private(set) var diagnostics: [String] = []

    private var actionsByID: [String: CatalogActionDefinition] = [:]
    private var menusByTileType: [MenuTileType: CatalogMenuDefinition] = [:]
    private var reloadGeneration: UInt64 = 0
    private var reloadTask: Task<Void, Never>?

    private init() {
        reload()
    }

    func reload() {
        diagnostics = []
        packageSummaries = []
        actionsByID = [:]
        menusByTileType = [:]
        reloadGeneration &+= 1
        let generation = reloadGeneration
        reloadTask?.cancel()

        let worker = Task.detached(
            priority: .utility
        ) {
            Self.loadCatalogDocuments()
        }
        reloadTask = Task { [weak self] in
            let result = await worker.value
            guard let self,
                  !Task.isCancelled,
                  self.reloadGeneration == generation else {
                return
            }

            guard let actionsDTO = result.actionsDocument,
                  let menusDTO = result.menusDocument else {
                self.diagnostics = [
                    "Failed to load menu catalog: " +
                    (result.errorDescription ?? "Unknown error")
                ]
                self.logDiagnostics()
                return
            }
            do {
                self.apply(
                    actionsDocument: try self.materialize(
                        actionsDocument: actionsDTO
                    ),
                    menusDocument: try self.materialize(
                        menusDocument: menusDTO
                    )
                )
            } catch {
                self.diagnostics = [
                    "Failed to load menu catalog: " +
                    error.localizedDescription
                ]
                self.logDiagnostics()
            }
        }
    }

    func contextActions(for tile: Tile, modifierFlags: NSEvent.ModifierFlags) -> [ContextAction]? {
        switch tile.content {
        case .app, .folder, .trash:
            break
        case .minimizedWindow, .appFolder, .launchpad, .startMenu, .widget, .smartStack, .spacer, .flexibleSpacer, .divider:
            return nil
        }

        let tileType = tileType(for: tile)
        guard let menu = menusByTileType[tileType] else {
            record("Missing menu definition for tile type '\(tileType.rawValue)'.")
            return nil
        }

        let context = makeContext(for: tile, modifierFlags: modifierFlags)
        return buildMenuItems(from: menu.items, context: context)
    }

    private func apply(actionsDocument: CatalogActionsDocument, menusDocument: CatalogMenusDocument) {
        var localDiagnostics: [String] = []
        var resolvedActions: [String: CatalogActionDefinition] = [:]

        for package in actionsDocument.packages {
            packageSummaries.append(CatalogPackageSummary(
                id: package.id,
                title: package.title,
                author: package.author,
                version: package.version,
                reviewStatus: package.reviewStatus,
                description: package.description,
                actionCount: package.actions.count
            ))

            for action in package.actions {
                if resolvedActions[action.id] != nil {
                    localDiagnostics.append("Duplicate action id '\(action.id)' in package '\(package.id)'.")
                    continue
                }

                if let error = validate(action: action) {
                    localDiagnostics.append("Action '\(action.id)' rejected: \(error)")
                    continue
                }

                resolvedActions[action.id] = action
            }
        }

        var resolvedMenus: [MenuTileType: CatalogMenuDefinition] = [:]
        for menu in menusDocument.menus {
            if resolvedMenus[menu.tileType] != nil {
                localDiagnostics.append("Duplicate menu definition for tile type '\(menu.tileType.rawValue)'.")
                continue
            }

            if let error = validate(menu: menu, actionsByID: resolvedActions) {
                localDiagnostics.append("Menu '\(menu.tileType.rawValue)' rejected: \(error)")
                continue
            }

            resolvedMenus[menu.tileType] = menu
        }

        actionsByID = resolvedActions
        menusByTileType = resolvedMenus
        diagnostics = localDiagnostics
        logDiagnostics()
    }

    private nonisolated static func loadCatalogDocuments()
        -> MenuCatalogLoadResult {
        do {
            let actions: MenuCatalogActionsDocumentDTO = try loadJSON(
                named: "actions",
                subdirectory: "MenuCatalog"
            )
            let menus: MenuCatalogMenusDocumentDTO = try loadJSON(
                named: "menus",
                subdirectory: "MenuCatalog"
            )
            return MenuCatalogLoadResult(
                actionsDocument: actions,
                menusDocument: menus,
                errorDescription: nil
            )
        } catch {
            return MenuCatalogLoadResult(
                actionsDocument: nil,
                menusDocument: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    private nonisolated static func loadJSON<T: Decodable>(
        named name: String,
        subdirectory: String
    ) throws -> T {
        let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: "json")
        guard let url else {
            throw NSError(domain: "MenuCatalogService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing resource \(subdirectory)/\(name).json"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func materialize(
        actionsDocument document: MenuCatalogActionsDocumentDTO
    ) throws -> CatalogActionsDocument {
        CatalogActionsDocument(
            version: document.version,
            packages: try document.packages.map { package in
                CatalogActionPackage(
                    id: package.id,
                    title: package.title,
                    author: package.author,
                    version: package.version,
                    reviewStatus: package.reviewStatus,
                    description: package.description,
                    actions: try package.actions.map(materialize)
                )
            }
        )
    }

    private func materialize(
        action: MenuCatalogActionDefinitionDTO
    ) throws -> CatalogActionDefinition {
        CatalogActionDefinition(
            id: action.id,
            title: action.title,
            alternateTitle: action.alternateTitle,
            alternateTitleWhen: try action.alternateTitleWhen.map(
                materialize
            ),
            kind: try catalogValue(
                action.kind,
                as: CatalogActionKind.self,
                field: "action kind"
            ),
            tileTypes: try action.tileTypes.map {
                try catalogValue(
                    $0,
                    as: MenuTileType.self,
                    field: "tile type"
                )
            },
            destructive: action.destructive,
            destructiveWhen: try action.destructiveWhen.map(
                materialize
            ),
            toggleFlag: try action.toggleFlag.map {
                try catalogValue(
                    $0,
                    as: CatalogContextFlag.self,
                    field: "toggle flag"
                )
            },
            when: try action.when.map(materialize),
            permissions: try action.permissions.map {
                try catalogValue(
                    $0,
                    as: CatalogPermissionRequirement.self,
                    field: "permission"
                )
            },
            builtinIdentifier: action.builtinIdentifier,
            targetApp: action.targetApp,
            inputs: try action.inputs.map {
                try catalogValue(
                    $0,
                    as: CatalogInputKey.self,
                    field: "input"
                )
            },
            script: action.script,
            path: action.path,
            requiresFrontmost: action.requiresFrontmost,
            holdOption: action.holdOption,
            symbol: action.symbol
        )
    }

    private func materialize(
        menusDocument document: MenuCatalogMenusDocumentDTO
    ) throws -> CatalogMenusDocument {
        CatalogMenusDocument(
            version: document.version,
            menus: try document.menus.map { menu in
                CatalogMenuDefinition(
                    tileType: try catalogValue(
                        menu.tileType,
                        as: MenuTileType.self,
                        field: "menu tile type"
                    ),
                    items: try menu.items.map(materialize)
                )
            }
        )
    }

    private func materialize(
        menuItem item: MenuCatalogMenuItemDefinitionDTO
    ) throws -> CatalogMenuItemDefinition {
        CatalogMenuItemDefinition(
            type: try catalogValue(
                item.type,
                as: CatalogMenuItemType.self,
                field: "menu item type"
            ),
            title: item.title,
            action: item.action,
            alternateAction: item.alternateAction,
            alternateActionWhen: try item.alternateActionWhen.map(
                materialize
            ),
            when: try item.when.map(materialize),
            children: try item.children?.map(materialize)
        )
    }

    private func materialize(
        condition: MenuCatalogConditionDTO
    ) throws -> CatalogCondition {
        let kind: CatalogCondition.Kind
        switch condition {
        case .flag(let rawValue):
            kind = .flag(try catalogValue(
                rawValue,
                as: CatalogContextFlag.self,
                field: "condition flag"
            ))
        case .bundleIdentifierEquals(let bundleIdentifier):
            kind = .bundleIdentifierEquals(bundleIdentifier)
        case .all(let conditions):
            kind = .all(try conditions.map(materialize))
        case .any(let conditions):
            kind = .any(try conditions.map(materialize))
        case .not(let condition):
            kind = .not(try materialize(condition: condition))
        }
        return CatalogCondition(kind: kind)
    }

    private func catalogValue<Value>(
        _ rawValue: String,
        as type: Value.Type,
        field: String
    ) throws -> Value
    where Value: RawRepresentable, Value.RawValue == String {
        guard let value = Value(rawValue: rawValue) else {
            throw NSError(
                domain: "MenuCatalogService",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unknown \(field) '\(rawValue)'."
                ]
            )
        }
        return value
    }

    private func validate(action: CatalogActionDefinition) -> String? {
        switch action.kind {
        case .builtin:
            guard let builtinIdentifier = action.builtinIdentifier, BuiltinAction(rawValue: builtinIdentifier) != nil else {
                return "unknown builtin identifier"
            }
        case .applescript:
            guard let targetApp = action.targetApp, !targetApp.isEmpty else {
                return "AppleScript actions require targetApp"
            }
            guard let script = action.script, !script.isEmpty else {
                return "AppleScript actions require script"
            }
            let placeholders = Set(script.placeholders)
            let declaredInputs = Set(action.inputs.map(\.rawValue))
            let unknownPlaceholders = placeholders.subtracting(declaredInputs)
            if !unknownPlaceholders.isEmpty {
                return "unknown placeholders: \(unknownPlaceholders.sorted().joined(separator: ", "))"
            }
        case .menuClick:
            guard let targetApp = action.targetApp, !targetApp.isEmpty else {
                return "menuClick actions require targetApp"
            }
            guard let path = action.path, !path.isEmpty else {
                return "menuClick actions require a non-empty path"
            }
        }

        return nil
    }

    private func validate(menu: CatalogMenuDefinition, actionsByID: [String: CatalogActionDefinition]) -> String? {
        validate(menuItems: menu.items, tileType: menu.tileType, actionsByID: actionsByID)
    }

    private func validate(menuItems: [CatalogMenuItemDefinition], tileType: MenuTileType, actionsByID: [String: CatalogActionDefinition]) -> String? {
        for item in menuItems {
            switch item.type {
            case .action:
                guard let actionID = item.action, let action = actionsByID[actionID] else {
                    return "references unknown action id '\(item.action ?? "")'"
                }
                guard action.tileTypes.contains(tileType) else {
                    return "action '\(actionID)' does not support tile type '\(tileType.rawValue)'"
                }
                if let alternateActionID = item.alternateAction {
                    guard let alternateAction = actionsByID[alternateActionID] else {
                        return "references unknown alternate action id '\(alternateActionID)'"
                    }
                    guard alternateAction.tileTypes.contains(tileType) else {
                        return "alternate action '\(alternateActionID)' does not support tile type '\(tileType.rawValue)'"
                    }
                }
            case .submenu:
                guard let title = item.title, !title.isEmpty else {
                    return "submenu is missing title"
                }
                guard let children = item.children, !children.isEmpty else {
                    return "submenu '\(title)' is empty"
                }
                if let error = validate(menuItems: children, tileType: tileType, actionsByID: actionsByID) {
                    return error
                }
            case .divider:
                break
            }
        }

        return nil
    }

    private func buildMenuItems(from items: [CatalogMenuItemDefinition], context: CatalogActionContext) -> [ContextAction] {
        var resolved: [ContextAction] = []

        for item in items {
            if let condition = item.when, !condition.evaluate(in: context) {
                continue
            }

            switch item.type {
            case .divider:
                if !resolved.isEmpty, resolved.last?.kind != .divider {
                    resolved.append(.divider)
                }
            case .submenu:
                guard let title = item.title, let children = item.children else { continue }
                let submenuItems = buildMenuItems(from: children, context: context)
                guard !submenuItems.isEmpty else { continue }
                resolved.append(.submenu(title, children: submenuItems))
            case .action:
                let resolvedActionID: String
                if let alternateActionID = item.alternateAction,
                   item.alternateActionWhen?.evaluate(in: context) == true {
                    resolvedActionID = alternateActionID
                } else if let actionID = item.action {
                    resolvedActionID = actionID
                } else {
                    continue
                }

                guard
                    let definition = actionsByID[resolvedActionID],
                    definition.when.map({ $0.evaluate(in: context) }) ?? true
                else {
                    continue
                }

                resolved.append(ContextAction.action(
                    resolvedTitle(for: definition, context: context),
                    image: symbolImage(for: definition.symbol),
                    isDestructive: definition.destructive || (definition.destructiveWhen?.evaluate(in: context) ?? false),
                    isOn: definition.toggleFlag.map { context.value(for: $0) } ?? false
                ) {
                    Task {
                        await ActionExecutionService.shared.perform(action: definition, context: context)
                    }
                })
            }
        }

        while resolved.last?.kind == .divider {
            _ = resolved.popLast()
        }

        return resolved
    }

    private func symbolImage(for symbolName: String?) -> NSImage? {
        guard let symbolName, !symbolName.isEmpty else { return nil }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func resolvedTitle(for action: CatalogActionDefinition, context: CatalogActionContext) -> String {
        if let alternateTitle = action.alternateTitle,
           action.alternateTitleWhen?.evaluate(in: context) == true {
            return alternateTitle
        }
        return action.title
    }

    private func makeContext(for tile: Tile, modifierFlags: NSEvent.ModifierFlags) -> CatalogActionContext {
        let finderBundleIdentifier = "com.apple.finder"

        switch tile.content {
        case .app(let app):
            let isPinned = tile.id.hasPrefix("pinned:")
            return CatalogActionContext(
                tile: tile,
                modifierFlags: modifierFlags,
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.displayName,
                appBundlePath: nil,
                folderPath: nil,
                filePath: nil,
                isRunning: WorkspaceService.shared.isRunning(bundleIdentifier: app.bundleIdentifier),
                isPinned: isPinned,
                canTogglePin: app.bundleIdentifier != finderBundleIdentifier,
                isFinder: app.bundleIdentifier == finderBundleIdentifier
            )
        case .folder(let folder):
            return CatalogActionContext(
                tile: tile,
                modifierFlags: modifierFlags,
                bundleIdentifier: nil,
                displayName: folder.displayName,
                appBundlePath: nil,
                folderPath: folder.url.path,
                filePath: folder.url.path,
                isRunning: false,
                isPinned: true,
                canTogglePin: false,
                isFinder: false
            )
        case .appFolder(let folder):
            return CatalogActionContext(
                tile: tile,
                modifierFlags: modifierFlags,
                bundleIdentifier: nil,
                displayName: folder.displayName,
                appBundlePath: nil,
                folderPath: nil,
                filePath: nil,
                isRunning: false,
                isPinned: true,
                canTogglePin: false,
                isFinder: false
            )
        case .launchpad(let launchpad):
            return CatalogActionContext(
                tile: tile,
                modifierFlags: modifierFlags,
                bundleIdentifier: nil,
                displayName: launchpad.title,
                appBundlePath: nil,
                folderPath: nil,
                filePath: nil,
                isRunning: false,
                isPinned: true,
                canTogglePin: false,
                isFinder: false
            )
        case .trash:
            return CatalogActionContext(
                tile: tile,
                modifierFlags: modifierFlags,
                bundleIdentifier: nil,
                displayName: "Trash",
                appBundlePath: nil,
                folderPath: nil,
                filePath: nil,
                isRunning: false,
                isPinned: true,
                canTogglePin: false,
                isFinder: false
            )
        case .startMenu(let menu):
            return CatalogActionContext(
                tile: tile,
                modifierFlags: modifierFlags,
                bundleIdentifier: nil,
                displayName: menu.title,
                appBundlePath: nil,
                folderPath: nil,
                filePath: nil,
                isRunning: false,
                isPinned: true,
                canTogglePin: false,
                isFinder: false
            )
        case .minimizedWindow, .widget, .smartStack, .spacer, .flexibleSpacer, .divider:
            return CatalogActionContext(
                tile: tile,
                modifierFlags: modifierFlags,
                bundleIdentifier: nil,
                displayName: "",
                appBundlePath: nil,
                folderPath: nil,
                filePath: nil,
                isRunning: false,
                isPinned: false,
                canTogglePin: false,
                isFinder: false
            )
        }
    }

    private func tileType(for tile: Tile) -> MenuTileType {
        switch tile.content {
        case .app: return .app
        case .minimizedWindow:
            fatalError("Unsupported tile type for context menu catalog")
        case .appFolder:
            fatalError("Unsupported tile type for context menu catalog")
        case .launchpad:
            fatalError("Unsupported tile type for context menu catalog")
        case .startMenu:
            fatalError("Unsupported tile type for context menu catalog")
        case .folder: return .folder
        case .trash: return .trash
        case .widget, .smartStack, .spacer, .flexibleSpacer, .divider:
            fatalError("Unsupported tile type for context menu catalog")
        }
    }

    private func record(_ message: String) {
        diagnostics.append(message)
        NSLog("[Docky] \(message)")
    }

    private func logDiagnostics() {
        diagnostics.forEach { NSLog("[Docky] \($0)") }
    }
}

private extension String {
    var placeholders: [String] {
        let pattern = #"\{\{([A-Za-z0-9_]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: nsRange).compactMap { match in
            guard match.numberOfRanges == 2,
                  let range = Range(match.range(at: 1), in: self) else {
                return nil
            }
            return String(self[range])
        }
    }
}
