//
//  ProfilesSettingsView.swift
//  Docky
//
//  Manages dock profiles — create / rename / duplicate / delete / switch.
//  Each profile owns its own tile-store (pinned, trailing, widgets, app
//  widget displays, hidden apps). Everything else (theme, sizing, etc.)
//  stays global.
//

import AppKit
import SwiftUI

private func profileLayoutSummary(
    _ profile: DockProfile,
    runningApps: [RunningApp] = []
) -> String {
    let appNames = profile.pinnedItems.compactMap {
        item -> String? in
        guard let bundleIdentifier = item.bundleIdentifier else {
            return nil
        }
        if let runningApp = runningApps.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            return runningApp.localizedName
        }
        return bundleIdentifier.split(separator: ".").last
            .map(String.init)
            ?? bundleIdentifier
    }
    let preview = appNames.prefix(3).joined(separator: ", ")
    let pinnedDescription: String
    if profile.pinnedItems.isEmpty {
        pinnedDescription = "empty"
    } else if preview.isEmpty {
        pinnedDescription =
            "\(profile.pinnedItems.count) pinned item\(profile.pinnedItems.count == 1 ? "" : "s")"
    } else {
        pinnedDescription =
            "\(profile.pinnedItems.count) pinned: \(preview)\(appNames.count > 3 ? ", …" : "")"
    }
    let accessoryCount =
        profile.trailingItems.count
        + profile.widgetPlacements.count
    guard accessoryCount > 0 else {
        return pinnedDescription
    }
    return "\(pinnedDescription) · \(accessoryCount) trailing/widget item\(accessoryCount == 1 ? "" : "s")"
}

struct ProfilesSettingsView: View {
    @Bindable private var profileService = ProfileService.shared
    @Bindable private var preferences = DockyPreferences.shared

    var body: some View {
        Form {
            Section {
                Text("Dock profiles each keep their own pinned apps, trailing items, widgets, and hidden-app list. Switch between them from the small ball at the leading edge of the dock.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let persistenceError = profileService.lastPersistenceError {
                Section {
                    Label("Profile changes could not be saved", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(persistenceError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Switcher") {
                Toggle(isOn: $preferences.hidesProfileStrip) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide profile switcher")
                        Text("Suppress the hover strip entirely. With multiple profiles you can still switch from Settings or via triggers. With only one profile the strip is always hidden.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Profiles") {
                ForEach(profileService.profiles) { profile in
                    ProfileRow(profile: profile)
                        .padding(.vertical, 2)
                }

                Button {
                    addProfile()
                } label: {
                    Label(
                        "Add Empty Profile",
                        systemImage: "plus.circle"
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addProfile() {
        let baseName = "Profile"
        let existingNames = Set(profileService.profiles.map(\.name))
        var name = baseName
        var counter = 1
        while existingNames.contains(name) {
            counter += 1
            name = "\(baseName) \(counter)"
        }
        // Creation is deliberately inactive. A new empty profile must never
        // make the current dock appear erased or replace another profile.
        _ = profileService.createProfile(name: name)
    }
}

private struct ProfileRow: View {
    let profile: DockProfile
    @Bindable private var profileService = ProfileService.shared
    @ObservedObject private var workspace = WorkspaceService.shared
    @State private var nameDraft: String
    @State private var isShowingDeleteConfirmation = false
    @FocusState private var isNameFocused: Bool

    init(profile: DockProfile) {
        self.profile = profile
        _nameDraft = State(initialValue: profile.name)
    }

    static let symbolOptions: [String] = [
        "house.fill",
        "briefcase.fill",
        "person.fill",
        "gamecontroller.fill",
        "moon.stars.fill",
        "sparkles",
        "paintbrush.fill",
        "music.note",
        "film.fill",
        "book.fill",
        "airplane",
        "car.fill",
        "leaf.fill",
        "flame.fill",
        "bolt.fill",
        "heart.fill"
    ]

    private var isActive: Bool {
        profileService.activeProfileID == profile.id
    }

    private var isDefault: Bool {
        profileService.defaultProfileID == profile.id
    }

    private var canDelete: Bool {
        profileService.profiles.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                symbolPicker

                TextField("Profile name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .focused($isNameFocused)
                    .onSubmit {
                        commitName()
                    }
                    .onChange(of: isNameFocused) { _, isFocused in
                        if !isFocused {
                            commitName()
                        }
                    }
                    .onChange(of: profile.name) { _, newName in
                        if !isNameFocused {
                            nameDraft = newName
                        }
                    }

                if isActive && isDefault {
                    Label(
                        "Active now · Default",
                        systemImage: "checkmark.circle.fill"
                    )
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.subheadline)
                } else if isActive {
                    Label(
                        "Active now",
                        systemImage: "checkmark.circle.fill"
                    )
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    Button("Make Default") {
                        profileService.setActiveProfile(id: profile.id)
                    }
                } else {
                    Button("Switch") {
                        profileService.setActiveProfile(id: profile.id)
                    }
                    if isDefault {
                        Text("Default")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu {
                    Button {
                        duplicate()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!canDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Text(
                profileLayoutSummary(
                    profile,
                    runningApps: workspace.runningApps
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 40)

            ProfileTriggersSection(profile: profile)
                .padding(.leading, 40)
        }
        .confirmationDialog(
            "Delete “\(profile.name)”?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "Delete “\(profile.name)”",
                role: .destructive
            ) {
                profileService.deleteProfile(id: profile.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteSummary)
        }
    }

    private var symbolPicker: some View {
        Menu {
            ForEach(Self.symbolOptions, id: \.self) { symbol in
                Button {
                    profileService.updateProfileSymbol(id: profile.id, symbolName: symbol)
                } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: profile.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var deleteSummary: String {
        let assignments =
            profileService.spaceAssignments(for: profile.id).count
        let appNames = profile.pinnedItems.compactMap {
            item -> String? in
            guard let bundleIdentifier = item.bundleIdentifier else {
                return nil
            }
            if let running = workspace.runningApps.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) {
                return running.localizedName
            }
            return bundleIdentifier.split(separator: ".").last
                .map(String.init)
                ?? bundleIdentifier
        }
        let namedApps = appNames.prefix(4).joined(separator: ", ")
        let appDetail = namedApps.isEmpty
            ? ""
            : " (\(namedApps)\(appNames.count > 4 ? ", …" : ""))"
        return """
        This permanently deletes \(profile.pinnedItems.count) pinned item\(profile.pinnedItems.count == 1 ? "" : "s")\(appDetail), \(profile.trailingItems.count) trailing item\(profile.trailingItems.count == 1 ? "" : "s"), \(profile.widgetPlacements.count) widget placement\(profile.widgetPlacements.count == 1 ? "" : "s"), and \(assignments) Desktop assignment\(assignments == 1 ? "" : "s"). No other profile is changed.
        """
    }

    private func commitName() {
        guard nameDraft != profile.name else { return }
        if !profileService.renameProfile(
            id: profile.id,
            to: nameDraft
        ) {
            nameDraft = profile.name
        }
    }

    private func duplicate() {
        let base = profile.name
        let existingNames = Set(profileService.profiles.map(\.name))
        var name = "\(base) Copy"
        var counter = 1
        while existingNames.contains(name) {
            counter += 1
            name = "\(base) Copy \(counter)"
        }
        profileService.createProfile(
            name: name,
            symbolName: profile.symbolName,
            basedOn: profile
        )
    }
}

// MARK: - Triggers

private struct ProfileTriggersSection: View {
    let profile: DockProfile
    @Bindable private var profileService = ProfileService.shared
    @Bindable private var triggerEngine = ProfileTriggerEngine.shared
    @ObservedObject private var workspace = WorkspaceService.shared
    @State private var assignmentProposal:
        CurrentSpaceAssignmentProposal?
    @State private var isPreparingAssignment = false
    @State private var isShowingAssignmentError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(
                profileService.spaceAssignments(for: profile.id)
            ) { assignment in
                SpaceAssignmentRow(
                    profile: profile,
                    assignment: assignment
                )
            }

            Button {
                prepareAssignment()
            } label: {
                Label(
                    currentSpaceAssignmentLabel,
                    systemImage: "rectangle.inset.filled"
                )
                .font(.caption)
            }
            .buttonStyle(.link)
            .disabled(
                !triggerEngine.isRunning
                    || isPreparingAssignment
                    || currentSpaceIsKnownNonassignable
            )

            if profile.triggers.isEmpty {
                Text(
                    profileService
                        .spaceAssignments(for: profile.id)
                        .isEmpty
                        ? "No automatic rules — this profile only activates when picked manually."
                        : "No additional app or time rules."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profile.triggers) { trigger in
                    TriggerRow(profile: profile, trigger: trigger)
                }
            }

            Menu {
                Button {
                    profileService.addTrigger(.timeOfDay(TimeOfDayTrigger()), to: profile.id)
                } label: {
                    Label("Time of Day", systemImage: "clock")
                }
                Button {
                    profileService.addTrigger(
                        .frontmostApp(FrontmostAppTrigger(bundleIdentifier: "")),
                        to: profile.id
                    )
                } label: {
                    Label("Frontmost App", systemImage: "app.dashed")
                }
                Button {
                    profileService.addTrigger(
                        .space(SpaceTrigger(bundleIdentifier: "")),
                        to: profile.id
                    )
                } label: {
                    Label("Space with App…", systemImage: "rectangle.3.group")
                }
            } label: {
                Label("Add Trigger…", systemImage: "plus.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .confirmationDialog(
            assignmentDialogTitle,
            isPresented: assignmentProposalIsPresented,
            titleVisibility: .visible
        ) {
            if let assignmentProposal {
                Button(
                    assignmentActionLabel(assignmentProposal),
                    role: isReassignment(assignmentProposal)
                        ? .destructive
                        : nil
                ) {
                    commitAssignment(assignmentProposal)
                }
            }
            Button("Cancel", role: .cancel) {
                assignmentProposal = nil
            }
        } message: {
            if let assignmentProposal {
                Text(assignmentMessage(assignmentProposal))
            }
        }
        .alert(
            "Desktop assignment unchanged",
            isPresented: $isShowingAssignmentError
        ) {
            Button("OK") {}
        } message: {
            Text(
                triggerEngine.assignmentFailureMessage
                    ?? "The current Desktop could not be verified safely."
            )
        }
    }

    private var currentSpaceAssignmentLabel: String {
        if isPreparingAssignment {
            return "Checking current Desktop…"
        }
        guard triggerEngine.isRunning else {
            return "Space automation is stopped"
        }
        guard !triggerEngine.spaceTransitionPending,
              let snapshot =
                triggerEngine.settledSpaceSnapshot
        else {
            return "Identify and assign current Desktop…"
        }
        if snapshot.rawType == 4 {
            return "Fullscreen Spaces can’t be assigned — use Space with App"
        }
        guard let identity = snapshot.assignableIdentity else {
            return "Current Space can’t be assigned"
        }
        let desktopName = triggerEngine.spaceDisplayName(
            for: snapshot
        )
        let existingProfileID =
            profileService.profileIDAssigned(to: identity)
        if existingProfileID == profile.id {
            return "\(desktopName) uses \(profile.name)"
        }
        if let existingProfileID,
           let existingName = profileName(existingProfileID) {
            return "Move \(desktopName) from \(existingName)…"
        }
        return "Assign \(desktopName) to \(profile.name)…"
    }

    private var currentSpaceIsKnownNonassignable: Bool {
        guard !triggerEngine.spaceTransitionPending,
              let snapshot = triggerEngine.settledSpaceSnapshot
        else {
            return false
        }
        return snapshot.rawType != 0
    }

    private var assignmentProposalIsPresented: Binding<Bool> {
        Binding(
            get: { assignmentProposal != nil },
            set: { isPresented in
                if !isPresented {
                    assignmentProposal = nil
                }
            }
        )
    }

    private var assignmentDialogTitle: String {
        guard let assignmentProposal else {
            return "Review Desktop assignment"
        }
        return assignmentActionLabel(assignmentProposal)
    }

    private func prepareAssignment() {
        isPreparingAssignment = true
        Task { @MainActor in
            let proposal = await triggerEngine
                .prepareSpaceAssignment(to: profile.id)
            isPreparingAssignment = false
            if let proposal {
                assignmentProposal = proposal
            } else {
                isShowingAssignmentError = true
            }
        }
    }

    private func commitAssignment(
        _ proposal: CurrentSpaceAssignmentProposal
    ) {
        assignmentProposal = nil
        isPreparingAssignment = true
        Task { @MainActor in
            let didCommit = await triggerEngine
                .commitSpaceAssignment(proposal)
            isPreparingAssignment = false
            if !didCommit {
                isShowingAssignmentError = true
            }
        }
    }

    private func assignmentActionLabel(
        _ proposal: CurrentSpaceAssignmentProposal
    ) -> String {
        let desktopName = triggerEngine.spaceDisplayName(
            for: proposal.snapshot
        )
        if proposal.existingProfileID == proposal.targetProfileID {
            return "Keep \(desktopName) on \(profile.name)"
        }
        if let existingProfileID = proposal.existingProfileID,
           let existingName = profileName(existingProfileID) {
            return "Move \(desktopName) from \(existingName) to \(profile.name)"
        }
        return "Assign \(desktopName) to \(profile.name)"
    }

    private func assignmentMessage(
        _ proposal: CurrentSpaceAssignmentProposal
    ) -> String {
        let targetSummary = profileLayoutSummary(
            profile,
            runningApps: workspace.runningApps
        )
        let timing =
            "The dock visible now will not switch. This takes effect after you leave and return to this Desktop, or after Docky restarts."
        if proposal.existingProfileID == proposal.targetProfileID {
            return "Docky will verify the Desktop again. The assignment and every profile’s contents remain unchanged. “\(profile.name)” contains \(targetSummary). \(timing)"
        }
        if let existingProfileID = proposal.existingProfileID,
           let existingProfile = profileService.profiles.first(where: {
               $0.id == existingProfileID
           }) {
            let existingSummary = profileLayoutSummary(
                existingProfile,
                runningApps: workspace.runningApps
            )
            return "This moves only this Desktop’s assignment from “\(existingProfile.name)” (\(existingSummary)) to “\(profile.name)” (\(targetSummary)). Neither profile is renamed, deleted, copied, or edited. \(timing)"
        }
        return "This assigns only the verified current Desktop to “\(profile.name)” (\(targetSummary)). No profile contents are copied, replaced, or edited. \(timing)"
    }

    private func isReassignment(
        _ proposal: CurrentSpaceAssignmentProposal
    ) -> Bool {
        proposal.existingProfileID != nil
            && proposal.existingProfileID
                != proposal.targetProfileID
    }

    private func profileName(_ profileID: String) -> String? {
        profileService.profiles.first {
            $0.id == profileID
        }?.name
    }
}

private struct SpaceAssignmentRow: View {
    let profile: DockProfile
    let assignment: SpaceProfileAssignment
    @Bindable private var profileService = ProfileService.shared
    @Bindable private var triggerEngine = ProfileTriggerEngine.shared
    @State private var isShowingRemovalConfirmation = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.inset.filled")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.caption)
                Text("Exact Space assignment")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isShowingRemovalConfirmation = true
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove only this Space assignment")
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Unassign \(displayName)?",
            isPresented: $isShowingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unassign \(displayName)", role: .destructive) {
                profileService.removeSpaceAssignment(
                    assignment.identity,
                    from: profile.id
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes only the Desktop assignment from “\(profile.name)”. The profile and all of its pinned apps, widgets, and other contents remain unchanged. The dock visible now will not switch."
            )
        }
    }

    private var displayName: String {
        triggerEngine.spaceDisplayName(
            for: assignment.identity
        )
    }
}

private struct TriggerRow: View {
    let profile: DockProfile
    let trigger: ProfileTrigger
    @Bindable private var profileService = ProfileService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)

            editor
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                profileService.removeTrigger(trigger.id, from: profile.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch trigger {
        case .timeOfDay: return "clock"
        case .frontmostApp: return "app.dashed"
        case .space: return "rectangle.3.group"
        case .exactSpace: return "rectangle.inset.filled"
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch trigger {
        case .timeOfDay:
            TimeOfDayTriggerEditor(
                profileID: profile.id,
                triggerID: trigger.id
            )
        case .frontmostApp:
            FrontmostAppTriggerEditor(
                profileID: profile.id,
                triggerID: trigger.id
            )
        case .space:
            SpaceTriggerEditor(
                profileID: profile.id,
                triggerID: trigger.id
            )
        case .exactSpace(let t):
            ExactSpaceTriggerEditor(profile: profile, triggerID: trigger.id, model: t)
        }
    }
}

private struct TimeOfDayTriggerEditor: View {
    let profileID: String
    let triggerID: String
    @Bindable private var profileService = ProfileService.shared

    private static let weekdays: [(symbol: String, label: String)] = [
        (symbol: "1", label: "Sun"),
        (symbol: "2", label: "Mon"),
        (symbol: "3", label: "Tue"),
        (symbol: "4", label: "Wed"),
        (symbol: "5", label: "Thu"),
        (symbol: "6", label: "Fri"),
        (symbol: "7", label: "Sat")
    ]

    var body: some View {
        Group {
            if let model = canonicalModel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        DatePicker(
                            "From",
                            selection: startBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()

                        Text("to")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        DatePicker(
                            "To",
                            selection: endBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }

                    HStack(spacing: 4) {
                        ForEach(Self.weekdays, id: \.label) { day in
                            let weekdayIndex = Int(day.symbol) ?? 1
                            let isOn =
                                model.weekdays.contains(weekdayIndex)
                            Button {
                                updateCanonicalModel { candidate in
                                    if candidate.weekdays.contains(
                                        weekdayIndex
                                    ) {
                                        candidate.weekdays.remove(
                                            weekdayIndex
                                        )
                                    } else {
                                        candidate.weekdays.insert(
                                            weekdayIndex
                                        )
                                    }
                                }
                            } label: {
                                Text(day.label)
                                    .font(.caption2)
                                    .frame(minWidth: 30)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(
                                                isOn
                                                    ? Color.accentColor.opacity(
                                                        0.25
                                                    )
                                                    : Color.secondary.opacity(
                                                        0.1
                                                    )
                                            )
                                    )
                                    .foregroundStyle(
                                        isOn
                                            ? Color.accentColor
                                            : Color.secondary
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: {
                Self.date(
                    from: canonicalModel?.startMinuteOfDay ?? 0
                )
            },
            set: { date in
                updateCanonicalModel {
                    $0.startMinuteOfDay =
                        Self.minutesFrom(date: date)
                }
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: {
                Self.date(
                    from: canonicalModel?.endMinuteOfDay ?? 0
                )
            },
            set: { date in
                updateCanonicalModel {
                    $0.endMinuteOfDay =
                        Self.minutesFrom(date: date)
                }
            }
        )
    }

    private static func date(from minutes: Int) -> Date {
        let calendar = Calendar.current
        let components = DateComponents(hour: minutes / 60, minute: minutes % 60)
        return calendar.date(from: components) ?? Date()
    }

    private static func minutesFrom(date: Date) -> Int {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var canonicalModel: TimeOfDayTrigger? {
        guard let profile = profileService.profiles.first(where: {
            $0.id == profileID
        }),
              case .timeOfDay(let model) =
                ProfileTriggerEditorIdentity(
                    profileID: profileID,
                    triggerID: triggerID
                ).resolve(
                    canonicalProfileID: profile.id,
                    triggers: profile.triggers
                )
        else {
            return nil
        }
        return model
    }

    private func updateCanonicalModel(
        _ update: (inout TimeOfDayTrigger) -> Void
    ) {
        guard var candidate = canonicalModel else {
            return
        }
        update(&candidate)
        _ = profileService.updateTrigger(
            .timeOfDay(candidate),
            in: profileID
        )
    }
}

private struct FrontmostAppTriggerEditor: View {
    let profileID: String
    let triggerID: String
    @State private var resolvedApplicationName:
        ProfileApplicationNameResolution?
    @Bindable private var profileService = ProfileService.shared
    @ObservedObject private var workspace = WorkspaceService.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("When")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(availableApps, id: \.bundleIdentifier) { app in
                    Button {
                        updateCanonicalModel {
                            $0.bundleIdentifier =
                                app.bundleIdentifier
                        }
                    } label: {
                        Text(app.localizedName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(displayLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Text("is frontmost")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: canonicalModel?.bundleIdentifier) {
            resolvedApplicationName = nil
            guard let bundleIdentifier =
                    canonicalModel?.bundleIdentifier
            else {
                return
            }
            let displayName = await ProfileApplicationMetadataLoader
                .displayName(for: bundleIdentifier)
            guard !Task.isCancelled,
                  canonicalModel?.bundleIdentifier
                    == bundleIdentifier else {
                return
            }
            resolvedApplicationName = ProfileApplicationNameResolution(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
        }
    }

    private var displayLabel: String {
        guard let bundleIdentifier =
                canonicalModel?.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else {
            return "Pick app…"
        }
        if let running = workspace.runningApps.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            return running.localizedName
        }
        if let displayName = resolvedApplicationName?.displayName(
            forCanonicalBundleIdentifier: bundleIdentifier
        ) {
            return displayName
        }
        return bundleIdentifier
    }

    private var availableApps: [RunningApp] {
        workspace.runningApps.sorted(by: ProfileApplicationMetadataLoader.sort)
    }

    private var canonicalModel: FrontmostAppTrigger? {
        guard let profile = profileService.profiles.first(where: {
            $0.id == profileID
        }),
              case .frontmostApp(let model) =
                ProfileTriggerEditorIdentity(
                    profileID: profileID,
                    triggerID: triggerID
                ).resolve(
                    canonicalProfileID: profile.id,
                    triggers: profile.triggers
                )
        else {
            return nil
        }
        return model
    }

    private func updateCanonicalModel(
        _ update: (inout FrontmostAppTrigger) -> Void
    ) {
        guard var candidate = canonicalModel else {
            return
        }
        update(&candidate)
        _ = profileService.updateTrigger(
            .frontmostApp(candidate),
            in: profileID
        )
    }
}

private struct SpaceTriggerEditor: View {
    let profileID: String
    let triggerID: String
    @State private var resolvedApplicationName:
        ProfileApplicationNameResolution?
    @Bindable private var profileService = ProfileService.shared
    @ObservedObject private var workspace = WorkspaceService.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("When on space with")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(availableApps, id: \.bundleIdentifier) { app in
                    Button {
                        updateCanonicalModel {
                            $0.bundleIdentifier =
                                app.bundleIdentifier
                        }
                    } label: {
                        Text(app.localizedName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(displayLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .task(id: canonicalModel?.bundleIdentifier) {
            resolvedApplicationName = nil
            guard let bundleIdentifier =
                    canonicalModel?.bundleIdentifier
            else {
                return
            }
            let displayName = await ProfileApplicationMetadataLoader
                .displayName(for: bundleIdentifier)
            guard !Task.isCancelled,
                  canonicalModel?.bundleIdentifier
                    == bundleIdentifier else {
                return
            }
            resolvedApplicationName = ProfileApplicationNameResolution(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
        }
    }

    private var displayLabel: String {
        guard let bundleIdentifier =
                canonicalModel?.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else {
            return "Pick app…"
        }
        if let running = workspace.runningApps.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            return running.localizedName
        }
        if let displayName = resolvedApplicationName?.displayName(
            forCanonicalBundleIdentifier: bundleIdentifier
        ) {
            return displayName
        }
        return bundleIdentifier
    }

    private var availableApps: [RunningApp] {
        workspace.runningApps.sorted(by: ProfileApplicationMetadataLoader.sort)
    }

    private var canonicalModel: SpaceTrigger? {
        guard let profile = profileService.profiles.first(where: {
            $0.id == profileID
        }),
              case .space(let model) =
                ProfileTriggerEditorIdentity(
                    profileID: profileID,
                    triggerID: triggerID
                ).resolve(
                    canonicalProfileID: profile.id,
                    triggers: profile.triggers
                )
        else {
            return nil
        }
        return model
    }

    private func updateCanonicalModel(
        _ update: (inout SpaceTrigger) -> Void
    ) {
        guard var candidate = canonicalModel else {
            return
        }
        update(&candidate)
        _ = profileService.updateTrigger(
            .space(candidate),
            in: profileID
        )
    }
}

private enum ProfileApplicationMetadataLoader {
    nonisolated static func displayName(
        for bundleIdentifier: String
    ) async -> String? {
        guard !bundleIdentifier.isEmpty,
              let url = await ApplicationURLResolver.shared.applicationURL(
                for: bundleIdentifier
              ),
              !Task.isCancelled else {
            return nil
        }

        let displayName = await Task.detached(priority: .utility) {
            FileManager.default.displayName(atPath: url.path)
        }.value
        return Task.isCancelled ? nil : displayName
    }

    nonisolated static func sort(
        _ lhs: RunningApp,
        _ rhs: RunningApp
    ) -> Bool {
        let nameComparison = lhs.localizedName.localizedCaseInsensitiveCompare(
            rhs.localizedName
        )
        if nameComparison == .orderedSame {
            return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(
                rhs.bundleIdentifier
            ) == .orderedAscending
        }
        return nameComparison == .orderedAscending
    }
}

private struct ExactSpaceTriggerEditor: View {
    let profile: DockProfile
    let triggerID: String
    @State var model: ExactSpaceTrigger
    @Bindable private var profileService = ProfileService.shared
    @Bindable private var triggerEngine = ProfileTriggerEngine.shared
    @State private var currentDesktopProposal:
        CurrentSpaceAssignmentProposal?
    @State private var savedIdentityReview:
        SavedIdentityReview?
    @State private var isPreparing = false
    @State private var isShowingError = false

    private struct SavedIdentityReview {
        let identity: MissionControlSpaceIdentity
        let existingProfileID: String?
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(
                model.identity == nil
                    ? "Legacy numeric Desktop binding — inactive"
                    : "Saved legacy Desktop binding — inactive"
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(
                model.identity == nil
                    ? "Repair Using Current Desktop…"
                    : "Review Saved Binding…"
            ) {
                if let identity = model.identity {
                    savedIdentityReview = SavedIdentityReview(
                        identity: identity,
                        existingProfileID:
                            profileService.profileIDAssigned(
                                to: identity
                            )
                    )
                } else {
                    prepareCurrentDesktopRepair()
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(isPreparing)
        }
        .confirmationDialog(
            "Repair using the verified current Desktop?",
            isPresented: currentProposalIsPresented,
            titleVisibility: .visible
        ) {
            if let currentDesktopProposal {
                Button(
                    currentRepairAction(currentDesktopProposal),
                    role:
                        currentDesktopProposal.existingProfileID != nil
                        && currentDesktopProposal.existingProfileID
                            != profile.id
                        ? .destructive
                        : nil
                ) {
                    commitCurrentDesktopRepair(
                        currentDesktopProposal
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                currentDesktopProposal = nil
            }
        } message: {
            Text(
                "Docky will verify the current Desktop again, atomically change only its assignment, then remove this inactive numeric legacy row. No profile contents are edited, and the dock visible now will not switch."
            )
        }
        .confirmationDialog(
            savedReviewTitle,
            isPresented: savedReviewIsPresented,
            titleVisibility: .visible
        ) {
            if let savedIdentityReview {
                Button(
                    savedReviewAction(savedIdentityReview),
                    role:
                        savedIdentityReview.existingProfileID != nil
                        && savedIdentityReview.existingProfileID
                            != profile.id
                        ? .destructive
                        : nil
                ) {
                    commitSavedReview(savedIdentityReview)
                }
            }
            Button("Cancel", role: .cancel) {
                savedIdentityReview = nil
            }
        } message: {
            Text(savedReviewMessage)
        }
        .alert(
            "Legacy binding unchanged",
            isPresented: $isShowingError
        ) {
            Button("OK") {}
        } message: {
            Text(
                triggerEngine.assignmentFailureMessage
                    ?? profileService.lastPersistenceError
                    ?? "The binding could not be changed safely."
            )
        }
    }

    private var currentProposalIsPresented: Binding<Bool> {
        Binding(
            get: { currentDesktopProposal != nil },
            set: {
                if !$0 {
                    currentDesktopProposal = nil
                }
            }
        )
    }

    private var savedReviewIsPresented: Binding<Bool> {
        Binding(
            get: { savedIdentityReview != nil },
            set: {
                if !$0 {
                    savedIdentityReview = nil
                }
            }
        )
    }

    private var savedReviewTitle: String {
        guard let savedIdentityReview else {
            return "Review saved Desktop binding"
        }
        return savedReviewAction(savedIdentityReview)
    }

    private var savedReviewMessage: String {
        guard let savedIdentityReview else { return "" }
        if savedIdentityReview.existingProfileID == profile.id {
            return "This saved Desktop already belongs to “\(profile.name)”. Docky will atomically remove only the redundant inactive legacy row. The dock visible now will not switch."
        }
        if let existingID = savedIdentityReview.existingProfileID,
           let existingName = profileName(existingID) {
            return "This atomically moves only the saved Desktop assignment from “\(existingName)” to “\(profile.name)” and removes the inactive legacy row. Neither profile’s contents are edited, and the dock visible now will not switch."
        }
        return "This atomically assigns only the saved Desktop to “\(profile.name)” and removes the inactive legacy row. No profile contents are edited, and the dock visible now will not switch."
    }

    private func prepareCurrentDesktopRepair() {
        isPreparing = true
        Task { @MainActor in
            let proposal = await triggerEngine
                .prepareSpaceAssignment(to: profile.id)
            isPreparing = false
            if let proposal {
                currentDesktopProposal = proposal
            } else {
                isShowingError = true
            }
        }
    }

    private func commitCurrentDesktopRepair(
        _ proposal: CurrentSpaceAssignmentProposal
    ) {
        currentDesktopProposal = nil
        isPreparing = true
        Task { @MainActor in
            let didRepair = await triggerEngine
                .commitLegacySpaceRepair(
                    proposal,
                    triggerID: triggerID,
                    in: profile.id
                )
            isPreparing = false
            if !didRepair {
                isShowingError = true
            }
        }
    }

    private func commitSavedReview(
        _ review: SavedIdentityReview
    ) {
        savedIdentityReview = nil
        guard profileService.profileIDAssigned(to: review.identity)
                == review.existingProfileID,
              profileService.repairLegacyExactSpaceBinding(
                  triggerID: triggerID,
                  in: profile.id,
                  assigning: review.identity,
                  expectedOwnerProfileID:
                      review.existingProfileID
              )
        else {
            isShowingError = true
            return
        }
    }

    private func currentRepairAction(
        _ proposal: CurrentSpaceAssignmentProposal
    ) -> String {
        let desktopName = triggerEngine.spaceDisplayName(
            for: proposal.snapshot
        )
        if let existingID = proposal.existingProfileID,
           existingID != profile.id,
           let existingName = profileName(existingID) {
            return "Move \(desktopName) from \(existingName) to \(profile.name)"
        }
        return "Assign \(desktopName) to \(profile.name)"
    }

    private func savedReviewAction(
        _ review: SavedIdentityReview
    ) -> String {
        let desktopName = savedIdentityDisplayName(review.identity)
        if let existingID = review.existingProfileID,
           existingID != profile.id,
           let existingName = profileName(existingID) {
            return "Move \(desktopName) from \(existingName) to \(profile.name)"
        }
        return "Assign \(desktopName) to \(profile.name)"
    }

    private func savedIdentityDisplayName(
        _ identity: MissionControlSpaceIdentity
    ) -> String {
        triggerEngine.spaceDisplayName(for: identity)
    }

    private func profileName(_ id: String) -> String? {
        profileService.profiles.first { $0.id == id }?.name
    }

}
