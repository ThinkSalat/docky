//
//  WidgetSettingsSchema.swift
//  Docky
//

import Foundation

struct WidgetSettingsField: Equatable, Codable, Identifiable {
    enum FieldType: String, Codable {
        case text
        case number
        case toggle
        case select
    }

    struct Option: Equatable, Codable {
        let value: String
        let label: String
    }

    let id: String
    let label: String
    let type: FieldType
    let defaultValue: WidgetSettingValue?
    /// Choices for `.select`; ignored otherwise.
    let options: [Option]?

    init(
        id: String,
        label: String,
        type: FieldType,
        defaultValue: WidgetSettingValue? = nil,
        options: [Option]? = nil
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.options = options
    }
}

extension WidgetKind {
    /// External widgets have settings iff their bundle shipped a non-empty manifest.
    nonisolated var hasConfigurableSettings: Bool {
        switch self {
        case .weather, .calendar, .nowPlaying:
            true
        case .calendarDate, .reminders, .batteries, .systemStatus, .search, .photoFrame:
            false
        case .external:
            false
        }
    }
}
