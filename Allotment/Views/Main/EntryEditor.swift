import SwiftUI

/// Adds or edits one time entry.
struct EntryEditor: View {
    let target: EntryEditTarget
    @Environment(TimeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = TimeEntry(start: .now, isBillable: false)
    @State private var day = Date.now
    @State private var startTime = Date.now
    @State private var endTime = Date.now
    @State private var durationText = ""
    @State private var isRunning = false
    @State private var isNew = true
    @State private var billableTouched = false
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if loaded { form } else { ProgressView().frame(height: 300) }
            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add entry" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 480)
        .task { if !loaded { load() } }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete) {
            Button("Delete entry", role: .destructive) {
                store.deleteEntry(draft.id)
                dismiss()
            }
        } message: {
            Text("This removes \(Fmt.hm(draft.duration())) from your timesheet.")
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Client", selection: $draft.clientID) {
                    Text("No client").tag(UUID?.none)
                    ForEach(store.activeClients) { client in
                        Label {
                            Text(client.name)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: client.colorHex))
                        }
                        .tag(Optional(client.id))
                    }
                    if let id = draft.clientID, let archived = store.client(id), archived.isArchived {
                        Text("\(archived.name) (archived)").tag(Optional(archived.id))
                    }
                }
                .onChange(of: draft.clientID) { _, newValue in
                    if store.project(draft.projectID)?.clientID != newValue { draft.projectID = nil }
                    refreshBillable()
                }
                Picker("Project", selection: $draft.projectID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.projects(for: draft.clientID)) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .disabled(store.projects(for: draft.clientID).isEmpty)
                .onChange(of: draft.projectID) { refreshBillable() }
                Picker("Activity", selection: $draft.activityID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.activities) { activity in
                        Label(activity.name, systemImage: activity.symbol).tag(Optional(activity.id))
                    }
                }
                .onChange(of: draft.activityID) { refreshBillable() }
                TextField("Notes", text: $draft.notes, prompt: Text("What did you work on?"), axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                DatePicker("Date", selection: $day, displayedComponents: .date)
                DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    .onChange(of: startTime) { syncDurationText() }
                if draft.isRunning || isRunning {
                    Toggle("Timer still running", isOn: $isRunning)
                }
                if !isRunning {
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                        .onChange(of: endTime) { syncDurationText() }
                    LabeledContent("Duration") {
                        TextField("Duration", text: $durationText, prompt: Text("1:30"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit(applyDurationText)
                    }
                    if endsNextDay {
                        Text("Ends the next day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Type a duration such as 1:30, 1.5 or 90m and press Return to set the end time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Billable", isOn: Binding(
                    get: { draft.isBillable },
                    set: { draft.isBillable = $0; billableTouched = true }
                ))
                if draft.source == .calendar {
                    LabeledContent("Source", value: "Logged from your calendar")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Times

    private var calendar: Calendar { store.schedule.calendar }

    private func combine(_ day: Date, _ time: Date) -> Date {
        let t = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? day
    }

    private var startDate: Date { combine(day, startTime) }

    private var endsNextDay: Bool { combine(day, endTime) <= startDate }

    private var endDate: Date {
        let end = combine(day, endTime)
        return end <= startDate ? calendar.date(byAdding: .day, value: 1, to: end) ?? end : end
    }

    private var isValid: Bool {
        isRunning || endDate.timeIntervalSince(startDate) >= 60
    }

    private func syncDurationText() {
        durationText = Fmt.clock(endDate.timeIntervalSince(startDate))
    }

    private func applyDurationText() {
        guard let seconds = Fmt.parseDuration(durationText), seconds > 0 else {
            syncDurationText()
            return
        }
        endTime = startDate.addingTimeInterval(seconds)
        syncDurationText()
    }

    private func refreshBillable() {
        guard !billableTouched else { return }
        draft.isBillable = store.defaultBillable(clientID: draft.clientID, projectID: draft.projectID, activityID: draft.activityID)
    }

    // MARK: - Load and save

    private func load() {
        if let id = target.entryID, let entry = store.entry(id) {
            draft = entry
            isNew = false
            isRunning = entry.isRunning
            billableTouched = true
            day = entry.start
            startTime = entry.start
            endTime = entry.end ?? .now
        } else {
            let base = calendar.isDateInToday(target.day)
                ? Date.now.addingTimeInterval(-3600)
                : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: target.day) ?? target.day
            // Round to the quarter hour so new entries start on tidy times.
            let rounded = Date(timeIntervalSince1970: (base.timeIntervalSince1970 / 900).rounded(.down) * 900)
            let last = store.recentWork(limit: 1).first
            draft = TimeEntry(clientID: last?.clientID, projectID: last?.projectID, activityID: last?.activityID ?? Activity.clientWorkID,
                              start: rounded, end: rounded.addingTimeInterval(3600), isBillable: false, source: .manual)
            draft.isBillable = store.defaultBillable(clientID: draft.clientID, projectID: draft.projectID, activityID: draft.activityID)
            day = rounded
            startTime = rounded
            endTime = rounded.addingTimeInterval(3600)
        }
        syncDurationText()
        loaded = true
    }

    private func save() {
        applyDurationTextIfEdited()
        var entry = draft
        entry.start = startDate
        entry.end = isRunning ? nil : endDate
        entry.notes = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(entry)
        dismiss()
    }

    /// Picks up a typed duration even when Return was not pressed.
    private func applyDurationTextIfEdited() {
        guard !isRunning, let seconds = Fmt.parseDuration(durationText), seconds > 0,
              abs(seconds - endDate.timeIntervalSince(startDate)) >= 60 else { return }
        endTime = startDate.addingTimeInterval(seconds)
    }
}
