//
//  WidgetSettingsView.swift
//  Docky
//

import SwiftUI

struct WidgetSettingsView: View {
    let tileID: String
    let widget: WidgetTile
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockyGlass(.regular, in: .rect(cornerRadius: 14))
        .dockyGlassBorder(in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.secondary)
            Text(widget.kind.title)
                .font(.headline)
            Spacer()
            Button {
                onDone()
            } label: {
                Text("Done")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch widget.kind {
        case .weather:
            WeatherWidgetSettingsContent(tileID: tileID)
        case .calendar:
            CalendarWidgetSettingsContent(tileID: tileID)
        case .nowPlaying:
            NowPlayingWidgetSettingsContent(
                tileID: tileID,
                ownerBundleIdentifier: widget.ownerBundleIdentifier
            )
        case .external(let identifier):
            ExternalWidgetSettingsForm(
                tileID: tileID,
                schema: ExternalWidgetRegistry.shared.metadata(for: identifier)?.settingsSchema ?? []
            )
        case .calendarDate, .reminders, .batteries, .systemStatus, .search, .photoFrame:
            EmptyView()
        }
    }
}

/// Reads/writes the same per-instance settings blob as first-party views, so storage is uniform across widget origins.
struct ExternalWidgetSettingsForm: View {
    let tileID: String
    let schema: [WidgetSettingsField]

    var body: some View {
        if schema.isEmpty {
            Text("This widget has no settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(schema) { field in
                fieldView(for: field)
            }
        }
    }

    @ViewBuilder
    private func fieldView(for field: WidgetSettingsField) -> some View {
        switch field.type {
        case .text:
            WidgetSettingsTextField(
                title: field.label,
                text: binding(
                    for: field,
                    get: { $0.string(field.id) ?? field.defaultValue?.stringValue ?? "" },
                    set: { value in value.isEmpty ? nil : .string(value) }
                )
            )
        case .number:
            WidgetSettingsNumberField(
                title: field.label,
                value: binding(
                    for: field,
                    get: { $0.double(field.id) ?? field.defaultValue?.doubleValue },
                    set: { value in value.map(WidgetSettingValue.number) }
                )
            )
        case .toggle:
            Toggle(field.label, isOn: binding(
                for: field,
                get: { $0.bool(field.id) ?? field.defaultValue?.boolValue ?? false },
                set: { .bool($0) }
            ))
        case .select:
            WidgetSettingsPicker(
                title: field.label,
                options: field.options ?? [],
                selection: binding(
                    for: field,
                    get: { $0.string(field.id) ?? field.defaultValue?.stringValue ?? "" },
                    set: { value in value.isEmpty ? nil : .string(value) }
                )
            )
        }
    }

    /// Writes each change straight to TileStore (live-apply, no save step).
    private func binding<T>(
        for field: WidgetSettingsField,
        get: @escaping (WidgetSettings) -> T,
        set: @escaping (T) -> WidgetSettingValue?
    ) -> Binding<T> {
        Binding(
            get: { get(TileStore.shared.widgetSettings(tileID: tileID) ?? [:]) },
            set: { newValue in
                TileStore.shared.setWidgetSetting(tileID: tileID, key: field.id, value: set(newValue))
            }
        )
    }
}

struct WidgetSettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            control()
        }
    }
}

struct WidgetSettingsTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        WidgetSettingsRow(title: title) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct WidgetSettingsNumberField: View {
    let title: String
    @Binding var value: Double?

    @State private var text: String = ""

    var body: some View {
        WidgetSettingsRow(title: title) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = value.map { formatted($0) } ?? "" }
                .onChange(of: text) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    value = trimmed.isEmpty ? nil : Double(trimmed)
                }
        }
    }

    private func formatted(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}

struct WidgetSettingsPicker: View {
    let title: String
    let options: [WidgetSettingsField.Option]
    @Binding var selection: String

    var body: some View {
        WidgetSettingsRow(title: title) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
