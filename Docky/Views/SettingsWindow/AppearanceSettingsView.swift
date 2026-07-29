//
//  AppearanceSettingsView.swift
//  Docky
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettingsView: View {
    enum Subsection {
        case general
        case indicators
        case tileLayout
        case windowShape
        case windowBackground
        case widgets
    }

    let subsection: Subsection

    private let dockSettings = DockSettingsService.shared
    @Bindable private var preferences = DockyPreferences.shared
    @State private var isShowingResetConfirmation = false
    @State private var isShowingSystemDockImportConfirmation = false
    @State private var systemDockImportResult: Bool?

    var body: some View {
        Form {
            switch subsection {
            case .general:
                generalSection
            case .indicators:
                indicatorsSection
            case .tileLayout:
                tileLayoutSection
            case .windowShape:
                windowShapeSection
            case .windowBackground:
                windowBackgroundSection
            case .widgets:
                widgetsSection
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset appearance settings?",
            isPresented: $isShowingResetConfirmation
        ) {
            Button("Reset Appearance", role: .destructive) {
                DockyPreferences.shared.resetAppearanceToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stored indicators, Docky tile and widget chrome, window shape, window background, and glass values will return to their built-in defaults, and their theme overrides will be cleared. An active theme can still supply those appearance values. Imported tile size and magnification, behavior, app icons, and other settings are unaffected. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("Glass") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Disable Glass Look",
                    isOn: themeAwareBinding(
                        for: .disablesGlassLook,
                        at: \.disablesGlassLook,
                        effective: {
                            preferences.effectiveDisablesGlassLook
                        }
                    )
                )
                    .font(.headline)

                Text("Removes the main window's glossy gradient border and Liquid Glass material while keeping the existing blur and background tinting.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }

        Section("Reset Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Restores indicators, Docky tile and widget chrome, window shape, window background, and glass preferences, then lets an active theme supply those appearance values. Imported tile size and magnification, behavior, app icons, Launchpad, and Window Manager settings keep their current values.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reset Appearance", role: .destructive) {
                    isShowingResetConfirmation = true
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var indicatorsSection: some View {
        Section("Activity Indicator") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Active Indicator Shape")
                        .font(.headline)

                    Spacer()

                    Picker(
                        "Active Indicator Shape",
                        selection: themeAwareBinding(
                            for: .activeIndicatorShape,
                            at: \.activeIndicatorShape,
                            effective: {
                                preferences.effectiveActiveIndicatorShape
                            }
                        )
                    ) {
                        ForEach(DockTileIndicatorShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if preferences.effectiveActiveIndicatorShape == .image {
                    optionalImageSourceRow(
                        title: "Indicator Image",
                        key: .activeIndicatorImagePath,
                        path: preferences.activeIndicatorImagePath,
                        onChoose: chooseActiveIndicatorImage,
                        onRemoveCustom: {
                            preferences.clearUserAsset(
                                slot: "appearance:active-indicator"
                            ) {
                                preferences.activeIndicatorImagePath = nil
                                preferences.setOptionalAppearanceMode(
                                    .disabled,
                                    for: .activeIndicatorImagePath
                                )
                            }
                        }
                    )
                }

                if showsIndicatorColorControls {
                    Divider()

                    optionalSourceModeRow(
                        title: "Indicator Color",
                        key: .activeIndicatorColor,
                        disabledLabel: "System Default",
                        ensureCustomValue: ensureCustomActiveIndicatorColor
                    )
                        .font(.headline)

                    if preferences.optionalAppearanceMode(
                        for: .activeIndicatorColor
                    ) == .custom {
                        ColorPicker("Indicator Color", selection: activeIndicatorColorBinding, supportsOpacity: false)
                    }
                }

                Text("Choose whether running apps use no marker, the classic dot, a pill, or a custom image.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            sliderRow(
                title: "Inward Offset",
                value: themeAwareBinding(
                    for: .activeIndicatorOffset,
                    at: \.activeIndicatorOffset,
                    effective: {
                        preferences.effectiveActiveIndicatorOffset
                    }
                ),
                range: -20...20,
                step: 1,
                format: { "\(Int($0)) pt" },
                description: "Shifts the indicator further from or closer to the screen edge."
            )

            sliderRow(
                title: "Size",
                value: themeAwareBinding(
                    for: .activeIndicatorScale,
                    at: \.activeIndicatorScale,
                    effective: {
                        preferences.effectiveActiveIndicatorScale
                    }
                ),
                range: 0.5...2.0,
                step: 0.05,
                format: { String(format: "%.2fx", $0) },
                description: "Scales the indicator's rendered size."
            )
        }

        Section("Dividers") {
            customDividerImageControls
        }
    }

    @ViewBuilder
    private var customDividerImageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Divider Image")
                .font(.headline)

            optionalImageSourceRow(
                title: "Center",
                key: .dividerImagePath,
                path: preferences.dividerImagePath,
                disabledLabel: "Default Line",
                onChoose: { chooseDividerImage(slot: .global) },
                onRemoveCustom: {
                    preferences.clearUserAsset(
                        slot: "appearance:divider-global"
                    ) {
                        preferences.dividerImagePath = nil
                        preferences.setOptionalAppearanceMode(
                            .disabled,
                            for: .dividerImagePath
                        )
                    }
                }
            )

            Divider()

            optionalImageSourceRow(
                title: "Left Side",
                key: .leftDividerImagePath,
                path: preferences.leftDividerImagePath,
                onChoose: { chooseDividerImage(slot: .left) },
                onRemoveCustom: {
                    preferences.clearUserAsset(
                        slot: "appearance:divider-left"
                    ) {
                        preferences.leftDividerImagePath = nil
                        preferences.setOptionalAppearanceMode(
                            .disabled,
                            for: .leftDividerImagePath
                        )
                    }
                }
            )

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Right Side")
                    Spacer()
                    Toggle(
                        "Mirror Left Side",
                        isOn: themeAwareBinding(
                            for: .mirrorsLeftDividerOnRight,
                            at: \.mirrorsLeftDividerOnRight,
                            effective: {
                                preferences
                                    .effectiveMirrorsLeftDividerOnRight
                            }
                        )
                    )
                        .toggleStyle(.switch)
                }

                if !preferences.effectiveMirrorsLeftDividerOnRight {
                    optionalImageSourceRow(
                        title: "Image Source",
                        key: .rightDividerImagePath,
                        path: preferences.rightDividerImagePath,
                        onChoose: { chooseDividerImage(slot: .right) },
                        onRemoveCustom: {
                            preferences.clearUserAsset(
                                slot: "appearance:divider-right"
                            ) {
                                preferences.rightDividerImagePath = nil
                                preferences.setOptionalAppearanceMode(
                                    .disabled,
                                    for: .rightDividerImagePath
                                )
                            }
                        }
                    )
                }
            }

            Text("Use a custom image for dividers. The center image applies to dividers near the middle of the dock; the left and right overrides target dividers near each end. Mirror reuses the left image flipped on the right side. In vertical docks the image is rotated 90° to follow the dock's axis.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)

        sliderRow(
            title: "Padding",
            value: themeAwareBinding(
                for: .dividerPaddingFraction,
                at: \.dividerPaddingFraction,
                effective: {
                    preferences.effectiveDividerPaddingFraction
                }
            ),
            range: 0...0.5,
            step: 0.01,
            format: { "\(Int(($0 * 100).rounded()))%" },
            description: "Controls how much each divider is inset along its short axis, as a fraction of the tile size."
        )

        sliderRow(
            title: "Vertical Offset",
            value: themeAwareBinding(
                for: .dividerOffset,
                at: \.dividerOffset,
                effective: {
                    preferences.effectiveDividerOffset
                }
            ),
            range: -20...20,
            step: 1,
            format: { "\(Int($0)) pt" },
            description: "Shifts dividers along the tile's short axis. Positive values move them up in horizontal docks or right in vertical docks."
        )

        sliderRow(
            title: "Image Size",
            value: themeAwareBinding(
                for: .dividerImageScale,
                at: \.dividerImageScale,
                effective: {
                    preferences.effectiveDividerImageScale
                }
            ),
            range: 0.5...2.0,
            step: 0.05,
            format: { String(format: "%.2fx", $0) },
            description: "Scales custom divider images. Has no effect on the default line."
        )

        sliderRow(
            title: "Opacity",
            value: themeAwareBinding(
                for: .dividerOpacity,
                at: \.dividerOpacity,
                effective: {
                    preferences.effectiveDividerOpacity
                }
            ),
            range: 0...1,
            step: 0.05,
            format: { "\(Int(($0 * 100).rounded()))%" },
            description: "Controls how visible dividers are. 100% is fully opaque; 0% hides them entirely."
        )

        VStack(alignment: .leading, spacing: 8) {
            optionalSourceModeRow(
                title: "Divider Color",
                key: .dividerColor,
                disabledLabel: "System Default",
                ensureCustomValue: ensureCustomDividerColor
            )
                .font(.headline)

            if preferences.optionalAppearanceMode(for: .dividerColor)
                == .custom
            {
                ColorPicker("Divider Color", selection: dividerColorBinding, supportsOpacity: false)
            }

            Text("Choose the active theme's color, the system label color, or a custom plain-divider color. This has no effect on dividers using an image.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var alphaBadge: some View {
        Text("ALPHA")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(.orange.opacity(0.4), lineWidth: 0.5))
            .accessibilityLabel("Alpha feature")
    }

    @ViewBuilder
    private func sliderRow(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        format: @escaping (CGFloat) -> String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            HStack {
                Slider(
                    value: value,
                    in: rangeIncludingCurrent(
                        range,
                        current: value.wrappedValue
                    ),
                    step: step
                ) {
                    Text(title)
                }
                .labelsHidden()

                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }

            Text(description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func optionalAppearanceModeBinding(
        key: DockyThemeOverrideKey,
        ensureCustomValue: @escaping () -> Void = {}
    ) -> Binding<ThemeOptionalAppearanceMode> {
        Binding(
            get: { preferences.optionalAppearanceMode(for: key) },
            set: { mode in
                if mode == .custom {
                    ensureCustomValue()
                }
                // This explicit call is required even when the dormant custom
                // value already equals the selected value: a same-value
                // property assignment does not fire didSet or mark an
                // override.
                preferences.setOptionalAppearanceMode(mode, for: key)
            }
        )
    }

    @ViewBuilder
    private func optionalSourceModeRow(
        title: String,
        key: DockyThemeOverrideKey,
        disabledLabel: String,
        ensureCustomValue: @escaping () -> Void = {}
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(
                title,
                selection: optionalAppearanceModeBinding(
                    key: key,
                    ensureCustomValue: ensureCustomValue
                )
            ) {
                Text("Theme / Default")
                    .tag(ThemeOptionalAppearanceMode.inherit)
                Text(disabledLabel)
                    .tag(ThemeOptionalAppearanceMode.disabled)
                Text("Custom")
                    .tag(ThemeOptionalAppearanceMode.custom)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 150)
        }
    }

    @ViewBuilder
    private func optionalImageSourceRow(
        title: String,
        key: DockyThemeOverrideKey,
        path: String?,
        disabledLabel: String = "None",
        onChoose: @escaping () -> Void,
        onRemoveCustom: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            optionalSourceModeRow(
                title: title,
                key: key,
                disabledLabel: disabledLabel
            )

            if preferences.optionalAppearanceMode(for: key) == .custom {
                HStack {
                    Button(
                        path == nil ? "Choose Image..." : "Replace Image...",
                        action: onChoose
                    )

                    if path != nil {
                        Button(
                            "Remove Custom",
                            action: onRemoveCustom
                        )
                    }

                    if let name = path.flatMap({
                        $0.isEmpty
                            ? nil
                            : URL(fileURLWithPath: $0).lastPathComponent
                    }) {
                        Text(name)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No custom image selected")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tileLayoutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tile Clip Shape")
                        .font(.headline)

                    Spacer()

                    Picker(
                        "Tile Clip Shape",
                        selection: themeAwareBinding(
                            for: .tileClipShape,
                            at: \.tileClipShape,
                            effective: {
                                preferences.effectiveTileClipShape
                            }
                        )
                    ) {
                        ForEach(DockClipShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Text("Choose whether Docky tile chrome keeps the current rounded corners or uses a full circle or capsule clip.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tile Vertical Padding")
                        .font(.headline)

                    Spacer()

                    HStack {
                        Slider(
                            value: themeAwareBinding(
                                for: .tileVerticalPadding,
                                at: \.tileVerticalPadding,
                                effective: {
                                    preferences
                                        .effectiveTileVerticalPadding
                                }
                            ),
                            in: rangeIncludingCurrent(
                                8...32,
                                current:
                                    preferences
                                        .effectiveTileVerticalPadding
                            ),
                            step: 1
                        ) {
                            Text("Tile Vertical Padding")
                        }
                        .labelsHidden()

                        Text(
                            "\(Int(preferences.effectiveTileVerticalPadding)) pt"
                        )
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Text("Controls the top and bottom inset inside each dock tile.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tile Spacing")
                        .font(.headline)

                    Spacer()

                    HStack {
                        Slider(
                            value: themeAwareBinding(
                                for: .tileSpacing,
                                at: \.tileSpacing,
                                effective: {
                                    preferences.effectiveTileSpacing
                                }
                            ),
                            in: rangeIncludingCurrent(
                                0...16,
                                current: preferences.effectiveTileSpacing
                            ),
                            step: 1
                        ) {
                            Text("Tile Spacing")
                        }
                        .labelsHidden()
                        Text("\(Int(preferences.effectiveTileSpacing)) pt")
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Text("Controls the horizontal gap between adjacent dock tiles.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Tile Size")
                    .font(.headline)

                HStack {
                    Slider(
                        value: systemDockTileSizeBinding,
                        in: rangeIncludingCurrent(
                            16...128,
                            current: Double(
                                dockSettings.effectiveTileSize
                            )
                        ),
                        step: 1
                    ) {
                        Text("Tile Size")
                    }
                    .labelsHidden()

                    Text(
                        "\(Int(dockSettings.effectiveTileSize.rounded())) pt"
                    )
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Text("Controls the base width and height of each dock tile.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tile Icon Padding")
                        .font(.headline)

                    Spacer()

                    HStack {
                        Slider(
                            value: themeAwareBinding(
                                for: .tileIconPadding,
                                at: \.tileIconPadding,
                                effective: {
                                    preferences.effectiveTileIconPadding
                                }
                            ),
                            in: rangeIncludingCurrent(
                                0...24,
                                current:
                                    preferences.effectiveTileIconPadding
                            ),
                            step: 1
                        ) {
                            Text("Tile Icon Padding")
                        }
                        .labelsHidden()
                        Text("\(Int(preferences.effectiveTileIconPadding)) pt")
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Text("Shrinks the rendered icon inside each tile without changing the tile's layout box. Useful for Windows-style chunky tile slots.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Tile Hover Effects")
                    .font(.headline)

                Toggle(
                    "Enable Tile Hover Effects",
                    isOn: $preferences.tileHoverEffectsEnabled
                )

                VStack(alignment: .leading, spacing: 8) {
                    optionalSourceModeRow(
                        title: "Background Color",
                        key: .tileHoverBackgroundColor,
                        disabledLabel: "None",
                        ensureCustomValue: ensureCustomHoverBackgroundColor
                    )

                    if preferences.optionalAppearanceMode(
                        for: .tileHoverBackgroundColor
                    ) == .custom {
                        ColorPicker(
                            "Hover Background Color",
                            selection: hoverBackgroundColorBinding,
                            supportsOpacity: false
                        )
                    }

                    optionalImageSourceRow(
                        title: "Background Image",
                        key: .tileHoverBackgroundImagePath,
                        path: preferences.tileHoverBackgroundImagePath,
                        onChoose: chooseTileHoverBackgroundImage,
                        onRemoveCustom: {
                            preferences.clearUserAsset(
                                slot: "appearance:tile-hover-background"
                            ) {
                                preferences.tileHoverBackgroundImagePath = nil
                                preferences.setOptionalAppearanceMode(
                                    .disabled,
                                    for: .tileHoverBackgroundImagePath
                                )
                            }
                        }
                    )

                    HStack {
                        Text("Background Opacity")
                        Slider(
                            value: hoverBackgroundOpacityBinding,
                            in: 0...1,
                            step: 0.05
                        ) {
                            Text("Hover Background Opacity")
                        }
                        .labelsHidden()
                        Text("\(Int((preferences.configuredTileHoverBackgroundOpacity * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .disabled(!hasHoverBackgroundSource)

                    HStack {
                        Text("Background Corner Radius")
                        Slider(
                            value: hoverBackgroundCornerRadiusBinding,
                            in: 0...32,
                            step: 1
                        ) {
                            Text("Hover Background Corner Radius")
                        }
                        .labelsHidden()
                        Text("\(Int(preferences.configuredTileHoverBackgroundCornerRadius)) pt")
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .disabled(!hasHoverBackgroundSource)

                    HStack {
                        Text("Hover Scale")
                        Slider(
                            value: hoverScaleBinding,
                            in: 0.8...1.4,
                            step: 0.01
                        ) {
                            Text("Hover Scale")
                        }
                        .labelsHidden()
                        Text(String(format: "%.2f×", preferences.configuredTileHoverScale))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }

                    HStack {
                        Text("Hover Opacity")
                        Slider(
                            value: hoverOpacityBinding,
                            in: 0...1,
                            step: 0.05
                        ) {
                            Text("Hover Opacity")
                        }
                        .labelsHidden()
                        Text("\(Int((preferences.configuredTileHoverOpacity * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .disabled(!preferences.tileHoverEffectsEnabled)

                Text("Master switch for every visible tile-hover response: background, scale, fade, magnification, title labels, app-window previews, and widget previews. Turning it off preserves the individual choices for re-enable.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Active App Background")
                    .font(.headline)

                optionalSourceModeRow(
                    title: "Background Color",
                    key: .tileActiveBackgroundColor,
                    disabledLabel: "None",
                    ensureCustomValue: ensureCustomActiveBackgroundColor
                )

                if preferences.optionalAppearanceMode(
                    for: .tileActiveBackgroundColor
                ) == .custom {
                    ColorPicker("Active Background Color", selection: activeBackgroundColorBinding, supportsOpacity: false)
                }

                optionalImageSourceRow(
                    title: "Background Image",
                    key: .tileActiveBackgroundImagePath,
                    path: preferences.tileActiveBackgroundImagePath,
                    onChoose: chooseTileActiveBackgroundImage,
                    onRemoveCustom: {
                        preferences.clearUserAsset(
                            slot: "appearance:tile-active-background"
                        ) {
                            preferences.tileActiveBackgroundImagePath = nil
                            preferences.setOptionalAppearanceMode(
                                .disabled,
                                for: .tileActiveBackgroundImagePath
                            )
                        }
                    }
                )

                HStack {
                    Text("Background Opacity")
                    Slider(value: activeBackgroundOpacityBinding, in: 0...1, step: 0.05) {
                        Text("Active Background Opacity")
                    }
                    .labelsHidden()
                    Text("\(Int((preferences.effectiveTileActiveBackgroundOpacity * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .disabled(!hasActiveBackgroundSource)

                HStack {
                    Text("Background Corner Radius")
                    Slider(value: activeBackgroundCornerRadiusBinding, in: 0...32, step: 1) {
                        Text("Active Background Corner Radius")
                    }
                    .labelsHidden()
                    Text("\(Int(preferences.effectiveTileActiveBackgroundCornerRadius)) pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .disabled(!hasActiveBackgroundSource)

                Text("Background fill drawn under every running app tile, independent of hover. Useful for taskbar-style \"highlighted active app\" looks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                optionalSourceModeRow(
                    title: "Icon Shadow",
                    key: .iconShadowColor,
                    disabledLabel: "Off",
                    ensureCustomValue: ensureCustomIconShadow
                )
                    .font(.headline)

                if preferences.optionalAppearanceMode(
                    for: .iconShadowColor
                ) == .custom {
                    ColorPicker("Shadow Color", selection: iconShadowColorBinding, supportsOpacity: false)

                    HStack {
                        Text("Radius")
                        Slider(
                            value: themeAwareBinding(
                                for: .iconShadowRadius,
                                at: \.iconShadowRadius,
                                effective: {
                                    preferences.effectiveIconShadowRadius
                                }
                            ),
                            in: rangeIncludingCurrent(
                                0...32,
                                current:
                                    preferences.effectiveIconShadowRadius
                            ),
                            step: 0.5
                        ) {
                            Text("Shadow Radius")
                        }
                        .labelsHidden()
                        Text(String(format: "%.1f pt", preferences.effectiveIconShadowRadius))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }

                    HStack {
                        Text("Opacity")
                        Slider(
                            value: themeAwareBinding(
                                for: .iconShadowOpacity,
                                at: \.iconShadowOpacity,
                                effective: {
                                    preferences.effectiveIconShadowOpacity
                                }
                            ),
                            in: 0...1,
                            step: 0.05
                        ) {
                            Text("Shadow Opacity")
                        }
                        .labelsHidden()
                        Text("\(Int((preferences.effectiveIconShadowOpacity * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }

                Text("Adds a drop shadow behind every icon-bearing tile. Has no visible effect on spacers and dividers.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: systemDockMagnificationBinding) {
                    HStack(spacing: 8) {
                        Text("Magnification")
                        alphaBadge
                    }
                }
                .font(.headline)

                if dockSettings.effectiveMagnification {
                    HStack {
                        Slider(value: systemDockLargeSizeBinding, in: largeSizeRange, step: 1) {
                            Text("Magnified Size")
                        }
                        .labelsHidden()

                        Text(
                            "\(Int(dockSettings.effectiveLargeSize.rounded())) pt"
                        )
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Text("Tiles near the pointer grow toward the magnified size and smoothly fall off with distance. Alpha: known issues with certain tile types and during reorder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !preferences.tileHoverEffectsEnabled {
                    Text("Disabled by the Tile Hover Effects master switch. Your magnification choice is preserved.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .disabled(!preferences.tileHoverEffectsEnabled)
        }

        Section("macOS Dock Import") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Import Current macOS Dock Settings") {
                    isShowingSystemDockImportConfirmation = true
                }
                .confirmationDialog(
                    "Import macOS Dock settings?",
                    isPresented:
                        $isShowingSystemDockImportConfirmation
                ) {
                    Button("Import Settings") {
                        systemDockImportResult =
                            dockSettings
                                .importCurrentSystemDockSettings()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This replaces Docky's imported edge, tile size, magnified size, and related compatibility values with the current macOS Dock values. Pinned items are unaffected.")
                }

                Text("Docky otherwise keeps its own values. Refreshing diagnostics or system Dock data never imports these settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let systemDockImportResult {
                    if systemDockImportResult {
                        Text("Imported the current macOS Dock settings.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The macOS Dock settings could not be read. Docky's settings were not changed.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var windowShapeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Chrome Clip Shape")
                        .font(.headline)

                    Spacer()

                    Picker(
                        "Chrome Clip Shape",
                        selection: themeAwareBinding(
                            for: .windowClipShape,
                            at: \.windowClipShape,
                            effective: {
                                preferences.effectiveWindowClipShape
                            }
                        )
                    ) {
                        ForEach(DockClipShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Text("Choose whether the dock chrome keeps the current rounded corners or uses a full circle or capsule clip.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Window Corner Radius")
                        .font(.headline)

                    Spacer()

                    HStack {
                        Slider(value: windowCornerRadiusBinding, in: 0...maximumCornerRadius, step: 1) {
                            Text("Window Corner Radius")
                        }
                        .labelsHidden()
                        Text(
                            "\(Int(min(preferences.effectiveWindowCornerRadius, maximumCornerRadius))) pt"
                        )
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Text(windowCornerRadiusDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .disabled(preferences.effectiveWindowClipShape == .circle)

            DisclosureGroup("Per-Corner Radii") {
                cornerRadiusRow(
                    label: "Top Leading",
                    key: .windowCornerRadiusTopLeading,
                    keyPath: \.windowCornerRadiusTopLeading,
                    effective: preferences.effectiveWindowCornerRadiusTopLeading
                )
                cornerRadiusRow(
                    label: "Top Trailing",
                    key: .windowCornerRadiusTopTrailing,
                    keyPath: \.windowCornerRadiusTopTrailing,
                    effective: preferences.effectiveWindowCornerRadiusTopTrailing
                )
                cornerRadiusRow(
                    label: "Bottom Leading",
                    key: .windowCornerRadiusBottomLeading,
                    keyPath: \.windowCornerRadiusBottomLeading,
                    effective: preferences.effectiveWindowCornerRadiusBottomLeading
                )
                cornerRadiusRow(
                    label: "Bottom Trailing",
                    key: .windowCornerRadiusBottomTrailing,
                    keyPath: \.windowCornerRadiusBottomTrailing,
                    effective: preferences.effectiveWindowCornerRadiusBottomTrailing
                )

                Text("Each corner that's set overrides only itself; unset corners inherit the uniform radius above. Use this to flatten only the screen-facing edge (taskbar look).")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(preferences.effectiveWindowClipShape == .circle)
            .padding(.vertical, 4)

            DisclosureGroup("Per-Edge Content Insets") {
                contentInsetRow(
                    label: "Top",
                    value: themeAwareBinding(
                        for: .windowContentInsetTop,
                        at: \.windowContentInsetTop,
                        effective: {
                            preferences.effectiveWindowContentInsetTop
                        }
                    )
                )
                contentInsetRow(
                    label: "Leading",
                    value: themeAwareBinding(
                        for: .windowContentInsetLeading,
                        at: \.windowContentInsetLeading,
                        effective: {
                            preferences
                                .effectiveWindowContentInsetLeading
                        }
                    )
                )
                contentInsetRow(
                    label: "Bottom",
                    value: themeAwareBinding(
                        for: .windowContentInsetBottom,
                        at: \.windowContentInsetBottom,
                        effective: {
                            preferences.effectiveWindowContentInsetBottom
                        }
                    )
                )
                contentInsetRow(
                    label: "Trailing",
                    value: themeAwareBinding(
                        for: .windowContentInsetTrailing,
                        at: \.windowContentInsetTrailing,
                        effective: {
                            preferences
                                .effectiveWindowContentInsetTrailing
                        }
                    )
                )

                Text("Padding between the dock panel and the chrome view, per edge. Full-axis mode forces these to 0 regardless.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                optionalSourceModeRow(
                    title: "Window Border",
                    key: .windowBorderColor,
                    disabledLabel: "Off",
                    ensureCustomValue: ensureCustomWindowBorder
                )
                    .font(.headline)

                if preferences.optionalAppearanceMode(
                    for: .windowBorderColor
                ) == .custom {
                    ColorPicker("Border Color", selection: windowBorderColorBinding, supportsOpacity: false)

                    HStack {
                        Text("Border Width")
                        Slider(
                            value: themeAwareBinding(
                                for: .windowBorderWidth,
                                at: \.windowBorderWidth,
                                effective: {
                                    preferences.effectiveWindowBorderWidth
                                }
                            ),
                            in: rangeIncludingCurrent(
                                0...8,
                                current:
                                    preferences.effectiveWindowBorderWidth
                            ),
                            step: 0.5
                        ) {
                            Text("Border Width")
                        }
                        .labelsHidden()
                        Text(String(format: "%.1f pt", preferences.effectiveWindowBorderWidth))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }

                Text("Choose the theme border, explicitly turn the flat border off, or use a custom solid color. The normal glass stroke remains independent.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var widgetsSection: some View {
        Section {
            widgetSpanBlock(
                title: "1x Widgets",
                paddingKey: .widget1xContentPadding,
                paddingKeyPath: \.widget1xContentPadding,
                radiusKey: .widget1xCornerRadius,
                radiusKeyPath: \.widget1xCornerRadius,
                effectivePadding: preferences.effectiveWidgetContentPadding(for: .one),
                effectiveRadius: preferences.effectiveWidgetCornerRadius(for: .one)
            )
            widgetSpanBlock(
                title: "2x Widgets",
                paddingKey: .widget2xContentPadding,
                paddingKeyPath: \.widget2xContentPadding,
                radiusKey: .widget2xCornerRadius,
                radiusKeyPath: \.widget2xCornerRadius,
                effectivePadding: preferences.effectiveWidgetContentPadding(for: .two),
                effectiveRadius: preferences.effectiveWidgetCornerRadius(for: .two)
            )
            widgetSpanBlock(
                title: "3x Widgets",
                paddingKey: .widget3xContentPadding,
                paddingKeyPath: \.widget3xContentPadding,
                radiusKey: .widget3xCornerRadius,
                radiusKeyPath: \.widget3xCornerRadius,
                effectivePadding: preferences.effectiveWidgetContentPadding(for: .three),
                effectiveRadius: preferences.effectiveWidgetCornerRadius(for: .three)
            )

            Text("Each rendering size can opt into its own content padding and corner radius. Unset values inherit the tile-chrome defaults, useful for letting wide widgets bleed edge-to-edge while keeping the 1x form rounded.")
                .foregroundStyle(.secondary)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func widgetSpanBlock(
        title: String,
        paddingKey: DockyThemeOverrideKey,
        paddingKeyPath:
            ReferenceWritableKeyPath<DockyPreferences, CGFloat?>,
        radiusKey: DockyThemeOverrideKey,
        radiusKeyPath:
            ReferenceWritableKeyPath<DockyPreferences, CGFloat?>,
        effectivePadding: CGFloat?,
        effectiveRadius: CGFloat?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)

            widgetOverrideRow(
                label: "Content Padding",
                key: paddingKey,
                keyPath: paddingKeyPath,
                effective: effectivePadding,
                range: 0...32
            )
            widgetOverrideRow(
                label: "Corner Radius",
                key: radiusKey,
                keyPath: radiusKeyPath,
                effective: effectiveRadius,
                range: 0...32
            )
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func widgetOverrideRow(
        label: String,
        key: DockyThemeOverrideKey,
        keyPath:
            ReferenceWritableKeyPath<DockyPreferences, CGFloat?>,
        effective: CGFloat?,
        range: ClosedRange<Double>
    ) -> some View {
        // The toggle is typed source intent (custom or inherit), independent
        // from dormant raw storage. The slider becomes editable only while
        // custom intent is active.
        let isOverriding =
            optionalNumericAppearanceUsesCustomBinding(
                for: key,
                at: keyPath,
                effective: { effective ?? 0 }
            )
        let sliderValue = optionalNumericAppearanceBinding(
            for: key,
            at: keyPath,
            effective: { effective ?? 0 }
        )
        HStack {
            Toggle(isOn: isOverriding) {
                Text(label).frame(width: 140, alignment: .leading)
            }
            .toggleStyle(.checkbox)
            Slider(value: sliderValue, in: range, step: 1) {
                Text(label)
            }
            .labelsHidden()
            .disabled(!isOverriding.wrappedValue)
            Text(isOverriding.wrappedValue
                 ? "\(Int(sliderValue.wrappedValue)) pt"
                 : (effective.map { "\(Int($0)) pt" } ?? "inherited"))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    private var windowBackgroundSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Window Background Image")
                    .font(.headline)

                optionalImageSourceRow(
                    title: "Image Source",
                    key: .windowBackgroundImagePath,
                    path: preferences.windowBackgroundImagePath,
                    onChoose: chooseWindowBackgroundImage,
                    onRemoveCustom: {
                        preferences.clearUserAsset(
                            slot: "appearance:window-background"
                        ) {
                            preferences.windowBackgroundImagePath = nil
                            preferences.setOptionalAppearanceMode(
                                .disabled,
                                for: .windowBackgroundImagePath
                            )
                        }
                    }
                )

                Text("Follow the theme image, explicitly use no image, or choose a custom image. An active image replaces the material tint and opacity.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Background Image Mode")

                    Spacer()

                    Picker(
                        "Background Image Mode",
                        selection: themeAwareBinding(
                            for: .windowBackgroundImageMode,
                            at: \.windowBackgroundImageMode,
                            effective: {
                                preferences
                                    .effectiveWindowBackgroundImageMode
                            }
                        )
                    ) {
                        ForEach(DockBackgroundImageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(
                        preferences.optionalAppearanceMode(
                            for: .windowBackgroundImagePath
                        ) != .custom
                            || preferences.windowBackgroundImagePath == nil
                    )
                }

                Text("Sprite mode keeps the leading and trailing thirds of the image pinned and stretches the middle along the dock's axis.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                optionalSourceModeRow(
                    title: "Window Tint",
                    key: .windowTintColor,
                    disabledLabel: "System Material",
                    ensureCustomValue: ensureCustomWindowTint
                )
                    .font(.headline)

                if preferences.optionalAppearanceMode(
                    for: .windowTintColor
                ) == .custom {
                    ColorPicker("Window Tint", selection: windowTintBinding, supportsOpacity: false)
                }

                Text("Choose the active theme tint, the native system material with no explicit tint layer, or a custom color.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .disabled(usesWindowBackgroundImage)

            VStack(alignment: .leading, spacing: 8) {
                Text("Window Tint Opacity")
                    .font(.headline)

                HStack {
                    Slider(value: windowTintOpacityBinding, in: 0...1, step: 0.01) {
                        Text("Window Tint Opacity")
                    }
                    Text("\(Int(preferences.effectiveWindowTintOpacity * 100))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Text("Controls how strongly the tint color is laid over the window blur.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .disabled(
                usesWindowBackgroundImage
                    || preferences.optionalAppearanceMode(
                        for: .windowTintColor
                    ) == .disabled
            )
        }
    }

    private func effectiveBinding<Value>(
        get: @escaping () -> Value,
        commit: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: commit)
    }

    private func themeAwareBinding(
        for key: DockyThemeOverrideKey,
        at keyPath:
            ReferenceWritableKeyPath<DockyPreferences, CGFloat>,
        effective: @escaping () -> CGFloat
    ) -> Binding<CGFloat> {
        effectiveBinding(get: effective) {
            preferences.commitUserAppearanceValue(
                $0,
                for: key,
                at: keyPath
            )
        }
    }

    private func themeAwareBinding(
        for key: DockyThemeOverrideKey,
        at keyPath:
            ReferenceWritableKeyPath<DockyPreferences, Bool>,
        effective: @escaping () -> Bool
    ) -> Binding<Bool> {
        effectiveBinding(get: effective) {
            preferences.commitUserAppearanceValue(
                $0,
                for: key,
                at: keyPath
            )
        }
    }

    private func themeAwareBinding<Value: RawRepresentable>(
        for key: DockyThemeOverrideKey,
        at keyPath:
            ReferenceWritableKeyPath<DockyPreferences, Value>,
        effective: @escaping () -> Value
    ) -> Binding<Value> where Value.RawValue == String {
        effectiveBinding(get: effective) {
            preferences.commitUserAppearanceValue(
                $0,
                for: key,
                at: keyPath
            )
        }
    }

    /// Displays the resolved theme/default value while committing an explicit
    /// custom source on every user edit. The forced commit is important when a
    /// dormant raw value already equals the selection after Clear Overrides.
    private func optionalNumericAppearanceBinding(
        for key: DockyThemeOverrideKey,
        at keyPath:
            ReferenceWritableKeyPath<DockyPreferences, CGFloat?>,
        effective: @escaping () -> CGFloat
    ) -> Binding<Double> {
        effectiveBinding(
            get: { Double(effective()) },
            commit: {
                preferences.commitUserOptionalAppearanceValue(
                    CGFloat($0),
                    for: key,
                    at: keyPath
                )
            }
        )
    }

    /// The checkbox reflects source intent, not whether dormant custom storage
    /// happens to be non-nil. Inherit keeps that storage available for a later
    /// re-enable.
    private func optionalNumericAppearanceUsesCustomBinding(
        for key: DockyThemeOverrideKey,
        at keyPath:
            ReferenceWritableKeyPath<DockyPreferences, CGFloat?>,
        effective: @escaping () -> CGFloat
    ) -> Binding<Bool> {
        Binding(
            get: {
                preferences.optionalAppearanceMode(for: key) == .custom
            },
            set: {
                preferences.setUserOptionalAppearanceUsesCustom(
                    $0,
                    for: key,
                    at: keyPath,
                    effectiveValue: effective()
                )
            }
        )
    }

    private func rangeIncludingCurrent<Value: Comparable>(
        _ base: ClosedRange<Value>,
        current: Value
    ) -> ClosedRange<Value> {
        min(base.lowerBound, current)
            ... max(base.upperBound, current)
    }

    private var maximumCornerRadius: CGFloat {
        (
            dockSettings.effectiveTileSize
                + preferences.effectiveTileVerticalPadding * 2
        ) / 2
    }

    private var systemDockTileSizeBinding: Binding<Double> {
        effectiveBinding(
            get: { Double(dockSettings.effectiveTileSize) },
            commit: { dockSettings.setTileSize(CGFloat($0)) }
        )
    }

    private var systemDockMagnificationBinding: Binding<Bool> {
        effectiveBinding(
            get: { dockSettings.effectiveMagnification },
            commit: { dockSettings.setMagnification($0) }
        )
    }

    private var systemDockLargeSizeBinding: Binding<Double> {
        effectiveBinding(
            get: { Double(dockSettings.effectiveLargeSize) },
            commit: { dockSettings.setLargeSize(CGFloat($0)) }
        )
    }

    private var largeSizeRange: ClosedRange<Double> {
        let lower = Double(dockSettings.effectiveTileSize)
        let current = Double(dockSettings.effectiveLargeSize)
        return lower...max(max(lower, 256), current)
    }

    private var windowCornerRadiusBinding: Binding<CGFloat> {
        themeAwareBinding(
            for: .windowCornerRadius,
            at: \.windowCornerRadius,
            effective: {
                min(
                    preferences.effectiveWindowCornerRadius,
                    maximumCornerRadius
                )
            }
        )
    }

    private var windowCornerRadiusDescription: String {
        switch preferences.effectiveWindowClipShape {
        case .rounded:
            "Controls the roundness of the main dock window and its border, up to a full capsule."
        case .circle:
            "Circle mode uses the maximum radius automatically, so square chrome becomes circular and wider chrome becomes a capsule."
        }
    }

    private func ensureCustomWindowTint() {
        guard preferences.windowTintColor == nil else { return }
        preferences.windowTintColor = DockColor(
            nsColor: preferences.effectiveWindowTintColor
        )
    }

    private var windowTintBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: preferences.effectiveWindowTintColor) },
            set: { newValue in
                guard let tintColor = DockColor(nsColor: NSColor(newValue)) else {
                    return
                }

                preferences.windowTintColor = tintColor
            }
        )
    }

    private var showsIndicatorColorControls: Bool {
        switch preferences.effectiveActiveIndicatorShape {
        case .dot, .pill, .underline:
            true
        case .none, .image:
            false
        }
    }

    private func ensureCustomActiveIndicatorColor() {
        guard preferences.activeIndicatorColor == nil else { return }
        preferences.activeIndicatorColor = DockColor(
            nsColor: preferences.effectiveActiveIndicatorColor
        )
    }

    private var activeIndicatorColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: preferences.effectiveActiveIndicatorColor) },
            set: { newValue in
                guard let indicatorColor = DockColor(nsColor: NSColor(newValue)) else {
                    return
                }

                preferences.activeIndicatorColor = indicatorColor
            }
        )
    }

    private var windowTintOpacityBinding: Binding<CGFloat> {
        themeAwareBinding(
            for: .windowTintOpacity,
            at: \.windowTintOpacity,
            effective: {
                preferences.effectiveWindowTintOpacity
            }
        )
    }

    private func ensureCustomWindowBorder() {
        guard preferences.windowBorderColor == nil else { return }
        let seed = preferences.effectiveWindowBorderColor ?? .labelColor
        preferences.windowBorderColor = DockColor(nsColor: seed)
    }

    private var windowBorderColorBinding: Binding<Color> {
        Binding(
            get: {
                let nsColor = preferences.effectiveWindowBorderColor ?? .labelColor
                return Color(nsColor: nsColor)
            },
            set: { newValue in
                guard let color = DockColor(nsColor: NSColor(newValue)) else { return }
                preferences.windowBorderColor = color
            }
        )
    }

    private func ensureCustomIconShadow() {
        guard preferences.iconShadowColor == nil else { return }
        let seed = preferences.effectiveIconShadowColor ?? .black
        preferences.iconShadowColor = DockColor(nsColor: seed)
    }

    private var iconShadowColorBinding: Binding<Color> {
        Binding(
            get: {
                let nsColor = preferences.effectiveIconShadowColor ?? .black
                return Color(nsColor: nsColor)
            },
            set: { newValue in
                guard let color = DockColor(nsColor: NSColor(newValue)) else { return }
                preferences.iconShadowColor = color
            }
        )
    }

    private func ensureCustomDividerColor() {
        guard preferences.dividerColor == nil else { return }
        let seed = preferences.effectiveDividerColor ?? .labelColor
        preferences.dividerColor = DockColor(nsColor: seed)
    }

    private var dividerColorBinding: Binding<Color> {
        Binding(
            get: {
                let nsColor = preferences.effectiveDividerColor ?? .labelColor
                return Color(nsColor: nsColor)
            },
            set: { newValue in
                guard let color = DockColor(nsColor: NSColor(newValue)) else { return }
                preferences.dividerColor = color
            }
        )
    }

    private var usesWindowBackgroundImage: Bool {
        preferences.effectiveWindowBackgroundImageURL != nil
    }

    private var selectedWindowBackgroundImageName: String? {
        guard let path = preferences.windowBackgroundImagePath, !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var selectedActiveIndicatorImageName: String? {
        guard let path = preferences.activeIndicatorImagePath, !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func chooseActiveIndicatorImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose Image"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            guard let path = await preferences.importUserAssetPath(
                from: url,
                slot: "appearance:active-indicator"
            ) else {
                return
            }
            preferences.commitImportedUserAssetPath(
                path,
                slot: "appearance:active-indicator"
            ) {
                preferences.activeIndicatorImagePath = $0
            }
        }
    }

    private func chooseWindowBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose Image"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            guard let path = await preferences.importUserAssetPath(
                from: url,
                slot: "appearance:window-background"
            ) else {
                return
            }
            preferences.commitImportedUserAssetPath(
                path,
                slot: "appearance:window-background"
            ) {
                preferences.windowBackgroundImagePath = $0
            }
        }
    }

    private func chooseTileActiveBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose Image"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            guard let path = await preferences.importUserAssetPath(
                from: url,
                slot: "appearance:tile-active-background"
            ) else {
                return
            }
            preferences.commitImportedUserAssetPath(
                path,
                slot: "appearance:tile-active-background"
            ) {
                preferences.tileActiveBackgroundImagePath = $0
            }
        }
    }

    private var selectedActiveBackgroundImageName: String? {
        guard let path = preferences.tileActiveBackgroundImagePath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var hasActiveBackgroundSource: Bool {
        preferences.effectiveTileActiveBackgroundColor != nil
            || preferences.effectiveTileActiveBackgroundImageURL != nil
    }

    private func ensureCustomActiveBackgroundColor() {
        guard preferences.tileActiveBackgroundColor == nil else { return }
        let seed =
            preferences.effectiveTileActiveBackgroundColor
            ?? .controlAccentColor
        preferences.tileActiveBackgroundColor = DockColor(nsColor: seed)
    }

    private var activeBackgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                let ns = preferences.effectiveTileActiveBackgroundColor ?? .controlAccentColor
                return Color(nsColor: ns)
            },
            set: { newValue in
                guard let color = DockColor(nsColor: NSColor(newValue)) else { return }
                preferences.tileActiveBackgroundColor = color
            }
        )
    }

    private var activeBackgroundOpacityBinding: Binding<Double> {
        optionalNumericAppearanceBinding(
            for: .tileActiveBackgroundOpacity,
            at: \.tileActiveBackgroundOpacity,
            effective: {
                preferences.effectiveTileActiveBackgroundOpacity
            }
        )
    }

    private var activeBackgroundCornerRadiusBinding: Binding<Double> {
        optionalNumericAppearanceBinding(
            for: .tileActiveBackgroundCornerRadius,
            at: \.tileActiveBackgroundCornerRadius,
            effective: {
                preferences.effectiveTileActiveBackgroundCornerRadius
            }
        )
    }

    private func chooseTileHoverBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose Image"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            guard let path = await preferences.importUserAssetPath(
                from: url,
                slot: "appearance:tile-hover-background"
            ) else {
                return
            }
            preferences.commitImportedUserAssetPath(
                path,
                slot: "appearance:tile-hover-background"
            ) {
                preferences.tileHoverBackgroundImagePath = $0
            }
        }
    }

    private var selectedHoverBackgroundImageName: String? {
        guard let path = preferences.tileHoverBackgroundImagePath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var hasHoverBackgroundSource: Bool {
        preferences.configuredTileHoverBackgroundColor != nil
            || preferences.configuredTileHoverBackgroundImageURL != nil
    }

    private func ensureCustomHoverBackgroundColor() {
        guard preferences.tileHoverBackgroundColor == nil else { return }
        let seed =
            preferences.configuredTileHoverBackgroundColor
            ?? .white
        preferences.tileHoverBackgroundColor = DockColor(nsColor: seed)
    }

    private var hoverBackgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                let ns =
                    preferences.configuredTileHoverBackgroundColor
                    ?? .white
                return Color(nsColor: ns)
            },
            set: { newValue in
                guard let color = DockColor(nsColor: NSColor(newValue)) else { return }
                preferences.tileHoverBackgroundColor = color
            }
        )
    }

    private var hoverBackgroundOpacityBinding: Binding<Double> {
        optionalNumericAppearanceBinding(
            for: .tileHoverBackgroundOpacity,
            at: \.tileHoverBackgroundOpacity,
            effective: {
                preferences.configuredTileHoverBackgroundOpacity
            }
        )
    }

    private var hoverBackgroundCornerRadiusBinding: Binding<Double> {
        optionalNumericAppearanceBinding(
            for: .tileHoverBackgroundCornerRadius,
            at: \.tileHoverBackgroundCornerRadius,
            effective: {
                preferences.configuredTileHoverBackgroundCornerRadius
            }
        )
    }

    private var hoverScaleBinding: Binding<Double> {
        optionalNumericAppearanceBinding(
            for: .tileHoverScale,
            at: \.tileHoverScale,
            effective: {
                preferences.configuredTileHoverScale
            }
        )
    }

    private var hoverOpacityBinding: Binding<Double> {
        optionalNumericAppearanceBinding(
            for: .tileHoverOpacity,
            at: \.tileHoverOpacity,
            effective: {
                preferences.configuredTileHoverOpacity
            }
        )
    }

    @ViewBuilder
    private func cornerRadiusRow(
        label: String,
        key: DockyThemeOverrideKey,
        keyPath:
            ReferenceWritableKeyPath<DockyPreferences, CGFloat?>,
        effective: CGFloat
    ) -> some View {
        // The toggle is the user's source intent (custom or inherit), not a
        // test for non-nil raw storage. Turning it off preserves the dormant
        // custom radius while the theme/uniform value becomes effective.
        let usesOverride =
            optionalNumericAppearanceUsesCustomBinding(
                for: key,
                at: keyPath,
                effective: { effective }
            )
        let value = optionalNumericAppearanceBinding(
            for: key,
            at: keyPath,
            effective: { effective }
        )

        HStack {
            Toggle(isOn: usesOverride) {
                Text(label).frame(width: 120, alignment: .leading)
            }
            .toggleStyle(.checkbox)
            Slider(value: value, in: 0...maximumCornerRadius, step: 1) {
                Text(label)
            }
            .labelsHidden()
            .disabled(!usesOverride.wrappedValue)
            Text("\(Int(effective)) pt")
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func contentInsetRow(label: String, value: Binding<CGFloat>) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = CGFloat($0) }
                ),
                in: rangeIncludingCurrent(
                    0...16,
                    current: Double(value.wrappedValue)
                ),
                step: 1
            ) {
                Text(label)
            }
            .labelsHidden()
            Text("\(Int(value.wrappedValue)) pt")
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private enum DividerImageSlot {
        case global, left, right
    }

    private func chooseDividerImage(slot: DividerImageSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose Image"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            switch slot {
            case .global:
                guard let path = await preferences.importUserAssetPath(
                    from: url,
                    slot: "appearance:divider-global"
                ) else {
                    return
                }
                preferences.commitImportedUserAssetPath(
                    path,
                    slot: "appearance:divider-global"
                ) {
                    preferences.dividerImagePath = $0
                }
            case .left:
                guard let path = await preferences.importUserAssetPath(
                    from: url,
                    slot: "appearance:divider-left"
                ) else {
                    return
                }
                preferences.commitImportedUserAssetPath(
                    path,
                    slot: "appearance:divider-left"
                ) {
                    preferences.leftDividerImagePath = $0
                }
            case .right:
                guard let path = await preferences.importUserAssetPath(
                    from: url,
                    slot: "appearance:divider-right"
                ) else {
                    return
                }
                preferences.commitImportedUserAssetPath(
                    path,
                    slot: "appearance:divider-right"
                ) {
                    preferences.rightDividerImagePath = $0
                }
            }
        }
    }
}
