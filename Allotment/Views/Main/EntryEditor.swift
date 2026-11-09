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
    /// Whether the entry is saved as a running timer, with no end time. Only offered for a timer that is running.
    @State private var isRunning = false
    @State private var mode = Mode.loading
    @State private var billable = BillableChoice.automatic
    @State private var dialogs = DialogPresenter()

    /// What the editor is doing.
    ///
    ///     loading ──the entry is found──▶ editing
    ///     loading ──no entry, or a new one──▶ adding
    private enum Mode {
        case loading
        case adding
        case editing
    }

    /// Who decides whether the entry is billable.
    ///
    ///     automatic ──you flip the Billable switch──▶ chosen
    ///
    /// While automatic, it follows the client, project and activity you pick. Existing entries start as chosen,
    /// so opening one never changes how it was billed.
    private enum BillableChoice {
        case automatic
        case chosen
    }

    var body: some View {
        Group {
            if mode == .loading { ProgressView().frame(height: 300) } else { form }
        }
        // The form scrolls under the buttons and fades out beneath them.
        .safeAreaBar(edge: .bottom) { buttonBar }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .frame(width: 480)
        .appDialogHost(dialogs)
        .task {
            if mode == .loading { load() }
            #if DEBUG
            if LaunchOptions.previewDialog == "entry-delete" { confirmDelete() }
            #endif
        }
    }

    private var buttonBar: some View {
        HStack {
            if mode == .editing {
                Button("Delete", role: .destructive) { confirmDelete() }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mode == .adding ? "Add entry" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!isValid)
        }
        .padding(16)
    }

    private func confirmDelete() {
        dialogs.present(AppDialog(
            symbol: "trash.fill", tone: .destructive,
            title: "Delete this entry?",
            message: "This removes \(Fmt.hm(draft.duration())) from your timesheet.",
            actions: [AppDialog.Action(title: "Delete entry", isDestructive: true) {
                store.deleteEntry(draft.id)
                dismiss()
            }]
        ))
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
                    set: { draft.isBillable = $0; billable = .chosen }
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
        guard billable == .automatic else { return }
        draft.isBillable = store.defaultBillable(clientID: draft.clientID, projectID: draft.projectID, activityID: draft.activityID)
    }

    // MARK: - Load and save

    private func load() {
        if let id = target.entryID, let entry = store.entry(id) {
            draft = entry
            mode = .editing
            isRunning = entry.isRunning
            billable = .chosen
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
            mode = .adding
        }
        syncDurationText()
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
