import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(TimeStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var confirmErase = false
    @State private var confirmSample = false
    @State private var dataMessage: String?

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
                Toggle("Open Allotment when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
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
                    Button("Load sample data…") { confirmSample = true }
                    Button("Erase all data…", role: .destructive) { confirmErase = true }
                }
                if let dataMessage {
                    Text(dataMessage).font(.caption).foregroundStyle(.secondary)
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
        .navigationTitle("Settings")
        .onAppear { launchAtLogin = LoginItem.isEnabled }
        .confirmationDialog("Erase all clients and time?", isPresented: $confirmErase) {
            Button("Erase everything", role: .destructive) { store.eraseAllData() }
        } message: {
            Text("Your settings are kept. Back up first if you might want this data again.")
        }
        .confirmationDialog("Replace your data with sample data?", isPresented: $confirmSample) {
            Button("Replace with sample data", role: .destructive) { store.loadSampleData() }
        } message: {
            Text("This replaces every client and entry. Back up first to keep your own data.")
        }
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
            if calendar.hasAccess {
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
            } else if calendar.canRequestAccess {
                LabeledContent("Calendar access") {
                    Button("Connect calendar") { calendar.requestAccess() }
                }
            } else {
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
            dataMessage = "Backed up to \(url.lastPathComponent)."
        } catch {
            dataMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Replace your data with this backup?"
        alert.informativeText = "Your current data is kept beside the data file as data.before-import.json."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.importBackup(from: url)
            dataMessage = "Restored from \(url.lastPathComponent)."
        } catch {
            dataMessage = "That file could not be restored: \(error.localizedDescription)"
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
