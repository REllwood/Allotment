import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(TimeStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(DialogPresenter.self) private var dialogs
    @State private var loginItem = LoginItem.state
    /// Confirms a backup or restore that worked. Failures are shown in a dialog instead.
    @State private var dataDone: String?

    private static let weekdaySymbols = Calendar.current.weekdaySymbols

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Working week") {
                LabeledContent("Weekly capacity") {
                    HStack {
                        TextField("Hours", value: $store.settings.weeklyCapacityHours, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("hours, about \(Fmt.hours(store.settings.dailyTargetHours)) a day")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Working days") {
                    HStack(spacing: 4) {
                        ForEach(orderedWeekdays, id: \.self) { weekday in
                            let isOn = store.settings.workdays.contains(weekday)
                            Button {
                                if isOn { store.settings.workdays.remove(weekday) } else { store.settings.workdays.insert(weekday) }
                            } label: {
                                Text(String(Self.weekdaySymbols[weekday - 1].prefix(3)))
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 38, height: 24)
                                    .foregroundStyle(isOn ? Color.white : .secondary)
                                    .background(isOn ? Color.accentColor : Color.primary.opacity(0.07),
                                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                            .help(isOn ? "Working day. Click to turn off." : "Day off. Click to make it a working day.")
                        }
                    }
                }
                LabeledContent("Working hours") {
                    HStack {
                        DatePicker("Start", selection: minutesBinding(\.workdayStartMinutes), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("to")
                        DatePicker("End", selection: minutesBinding(\.workdayEndMinutes), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                Picker("Week starts on", selection: $store.settings.firstWeekday) {
                    ForEach(1...7, id: \.self) { Text(Self.weekdaySymbols[$0 - 1]).tag($0) }
                }
            }

            Section {
                Toggle("Show the running time in the menu bar", isOn: $store.settings.showTimerInMenuBar)
                Picker("Ask about idle time after", selection: $store.settings.idleThresholdMinutes) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Open Allotment when you log in", isOn: Binding(get: { loginItem != .off }, set: setLoginItem))
                if loginItem == .needsApproval {
                    HStack {
                        Label("macOS needs you to allow this in Login Items.", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Tracking")
            } footer: {
                Text("When you step away or your Mac sleeps with a timer running, Allotment asks whether to keep that time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Your name", text: $store.settings.userName)
                Picker("Currency", selection: $store.settings.currencyCode) {
                    ForEach(currencies, id: \.self) { code in
                        Text("\(code) · \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
                    }
                }
                LabeledContent("Default hourly rate") {
                    TextField("Rate", value: $store.settings.defaultHourlyRate, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                Picker("Round entries in reports", selection: $store.settings.rounding) {
                    ForEach(RoundingRule.allCases) { Text($0.title).tag($0) }
                }
                Picker("Counts as on track within", selection: $store.settings.tolerancePercent) {
                    ForEach([0.0, 5, 10, 15, 20, 25], id: \.self) { Text("\(Int($0))% of the allocation").tag($0) }
                }
            } header: {
                Text("Billing and reports")
            } footer: {
                Text("Your name appears on exported timesheets. Rounding only changes reports and exports, never the time you tracked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            calendarSection

            ActivitiesSection()

            Section {
                LabeledContent("Data file") {
                    HStack {
                        Text(store.fileURL?.path(percentEncoded: false) ?? "In memory (demo mode)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        if let url = store.fileURL {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
                HStack {
                    Button("Back up…", action: exportBackup)
                    Button("Restore from backup…", action: importBackup)
                    Spacer()
                    Button("Load sample data…") { confirmSampleData() }
                    Button("Erase all data…", role: .destructive) { confirmErase() }
                }
                if let dataDone {
                    Label(dataDone, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your data")
            } footer: {
                Text("Everything is stored in one file on this Mac. Nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fadeUnderBars()
        .navigationTitle("Settings")
        // Approval happens in System Settings, so look again whenever you come back to Allotment.
        .onAppear { loginItem = LoginItem.state }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = LoginItem.state
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
        } catch {
            dialogs.present(.problem(enabled ? "Allotment could not be set to open at login" : "Allotment could not be removed from login",
                                     error: error))
        }
        loginItem = LoginItem.state
    }

    private func confirmErase() {
        dialogs.present(AppDialog(
            symbol: "trash.fill", tone: .destructive,
            title: "Erase all clients and time?",
            message: "Your settings are kept. Back up first if you might want this data again.",
            actions: [AppDialog.Action(title: "Erase everything", isDestructive: true) { store.eraseAllData() }]
        ))
    }

    private func confirmSampleData() {
        dialogs.present(AppDialog(
            symbol: "wand.and.stars", tone: .destructive,
            title: "Replace your data with sample data?",
            message: "This replaces every client and entry. Back up first to keep your own data.",
            actions: [AppDialog.Action(title: "Replace with sample data", isDestructive: true) { store.loadSampleData() }]
        ))
    }

    private var orderedWeekdays: [Int] {
        let first = store.settings.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var currencies: [String] {
        let common = ["GBP", "EUR", "USD", "AUD", "NZD", "CAD", "CHF", "SEK", "NOK", "DKK", "JPY", "SGD", "ZAR", "INR"]
        return common.contains(store.settings.currencyCode) ? common : [store.settings.currencyCode] + common
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(store.settings[keyPath: keyPath] * 60))
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                store.settings[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    @ViewBuilder
    private var calendarSection: some View {
        @Bindable var store = store
        Section {
            switch calendar.access {
            case .granted:
                Toggle("Ignore all-day events", isOn: $store.settings.ignoreAllDayEvents)
                ForEach(calendar.calendars) { source in
                    Toggle(isOn: Binding(
                        get: { store.settings.includedCalendarIDs?.contains(source.id) ?? true },
                        set: { isOn in
                            var ids = Set(store.settings.includedCalendarIDs ?? calendar.calendars.map(\.id))
                            if isOn { ids.insert(source.id) } else { ids.remove(source.id) }
                            store.settings.includedCalendarIDs = ids.count == calendar.calendars.count ? nil : Array(ids)
                        }
                    )) {
                        HStack(spacing: 8) {
                            ClientDot(color: Color(hex: source.colorHex))
                            Text(source.title)
                            Text(source.sourceTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .notAsked:
                LabeledContent("Calendar access") {
                    Button("Connect calendar") { calendar.requestAccess() }
                }
            case .denied:
                LabeledContent("Calendar access") {
                    HStack {
                        Text("Turned off").foregroundStyle(.secondary)
                        Button("Open Privacy Settings") { calendar.openPrivacySettings() }
                        Button("Check again") { calendar.refreshStatus() }
                    }
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Allotment only reads events, and only on this Mac. Choose which calendars to show.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Allotment backup \(Fmt.isoDay(.now)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportBackup(to: url)
            dataDone = "Backed up to \(url.lastPathComponent)."
        } catch {
            dataDone = nil
            dialogs.present(.problem("The backup could not be saved", error: error))
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dialogs.present(AppDialog(
            symbol: "clock.arrow.circlepath", tone: .warning,
            title: "Replace your data with this backup?",
            message: "Your current data is kept beside the data file as data.before-import.json.",
            actions: [AppDialog.Action(title: "Restore") { restore(from: url) }]
        ))
    }

    private func restore(from url: URL) {
        do {
            try store.importBackup(from: url)
            dataDone = "Restored from \(url.lastPathComponent)."
        } catch {
            dataDone = nil
            dialogs.present(.problem("That file could not be restored", error: error))
        }
    }
}

private struct ActivitiesSection: View {
    @Environment(TimeStore.self) private var store
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(store.allActivities) { activity in
                let binding = Binding(get: { store.activity(activity.id) ?? activity }, set: { store.save($0) })
                HStack(spacing: 10) {
                    Image(systemName: activity.symbol)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    TextField("Name", text: binding.name)
                        .labelsHidden()
                        .foregroundStyle(activity.isArchived ? .secondary : .primary)
                    Toggle("Billable", isOn: binding.isBillable)
                        .toggleStyle(.checkbox)
                    Toggle("Admin", isOn: binding.isAdmin)
                        .toggleStyle(.checkbox)
                    Menu {
                        Button(activity.isArchived ? "Unarchive" : "Archive") { binding.wrappedValue.isArchived.toggle() }
                        Button("Delete", role: .destructive) { store.deleteActivity(activity.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            HStack {
                TextField("New activity", text: $newName, prompt: Text("Add an activity, such as Design or Support"))
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Activities")
        } footer: {
            Text("Activities describe the kind of work. Admin activities are reported separately, and can be tracked for a client or on their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.save(Activity(name: name, symbol: "circle.grid.cross", isBillable: true, isAdmin: false))
        newName = ""
    }
}
