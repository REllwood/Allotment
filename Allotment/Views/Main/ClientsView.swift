import SwiftUI

struct ClientsView: View {
    @Environment(TimeStore.self) private var store
    @State private var selection: UUID?
    @State private var showArchived = false

    var body: some View {
        let clients = store.clients
            .filter { showArchived || !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(clients) { client in
                    ClientListRow(client: client)
                        .tag(client.id)
                }
            }
            .listStyle(.inset)
            .fadeUnderBars()
            .frame(width: 260)
            .overlay {
                if clients.isEmpty {
                    EmptyStateView(symbol: "person.2", title: "No clients", message: "Add a client to start tracking time for them.")
                }
            }

            Divider()

            Group {
                if let id = selection ?? clients.first?.id, store.client(id) != nil {
                    ClientDetail(clientID: id, onDelete: { selection = nil })
                        .id(id)
                } else {
                    EmptyStateView(symbol: "person.crop.circle.badge.plus", title: "Select a client",
                                   message: "Choose a client to edit their rate, allocation, projects and calendar matching.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Clients")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showArchived) {
                    Label("Show archived", systemImage: "archivebox")
                }
                .help("Show archived clients")
            }
            ToolbarItem {
                Button {
                    selection = store.newClient().id
                } label: {
                    Label("New client", systemImage: "plus")
                }
                .help("Add a client")
            }
        }
        .onAppear {
            // A client created from the menu bar arrives here selected and ready to name.
            if selection == nil {
                let newest = store.clients.last.flatMap { $0.name == "New client" ? $0 : nil }
                selection = newest?.id ?? clients.first?.id
            }
        }
    }
}

private struct ClientListRow: View {
    let client: Client
    @Environment(TimeStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            ClientDot(color: Color(hex: client.colorHex), size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name)
                    .foregroundStyle(client.isArchived ? .secondary : .primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if client.isFavorite && !client.isArchived {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Shown in the menu bar")
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        if client.isArchived { return "Archived" }
        if let hours = client.allocationHours {
            return "\(Fmt.hours(hours)) \(client.allocationPeriod.perLabel)"
        }
        return "No allocation"
    }
}

private struct ClientDetail: View {
    let clientID: UUID
    let onDelete: () -> Void
    @Environment(TimeStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    @State private var keywordsText = ""

    private var client: Binding<Client> {
        Binding(
            get: { store.client(clientID) ?? Client(name: "", colorHex: Palette.fallback) },
            set: { store.save($0) }
        )
    }

    var body: some View {
        let schedule = store.schedule
        let week = schedule.week(containing: .now)
        let month = schedule.month(containing: .now)
        let entryCount = store.entries(for: clientID).count

        Form {
            Section {
                TextField("Name", text: client.name)
                    .font(.title3)
                LabeledContent("Colour") {
                    ColorSwatchPicker(hex: client.colorHex)
                }
                Toggle("Show in the menu bar for one-click tracking", isOn: client.isFavorite)
                Toggle("Archived", isOn: client.isArchived)
            }

            Section("Billing") {
                LabeledContent("Hourly rate") {
                    HStack {
                        TextField("Rate", value: client.hourlyRate, format: .number.precision(.fractionLength(0...2)),
                                  prompt: Text(store.settings.defaultHourlyRate > 0 ? Fmt.decimal(store.settings.defaultHourlyRate) : "None"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("\(store.settings.currencyCode) an hour")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Leave empty to use the default rate from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Has an allocation", isOn: Binding(
                    get: { client.wrappedValue.allocationHours != nil },
                    set: { client.wrappedValue.allocationHours = $0 ? (client.wrappedValue.allocationHours ?? 16) : nil }
                ))
                if client.wrappedValue.allocationHours != nil {
                    LabeledContent("Allocated hours") {
                        HStack {
                            TextField("Hours", value: Binding(
                                get: { client.wrappedValue.allocationHours ?? 0 },
                                set: { client.wrappedValue.allocationHours = max(0, $0) }
                            ), format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            Picker("Period", selection: client.allocationPeriod) {
                                ForEach(AllocationPeriod.allCases) { Text($0.perLabel).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            } header: {
                Text("Allocation")
            } footer: {
                Text("The hours this client has booked with you. Allotment warns you when you are heading over or under.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("This week", value: Fmt.hm(store.hours(clientID: clientID, in: week) * 3600))
                LabeledContent("This month", value: Fmt.hm(store.hours(clientID: clientID, in: month) * 3600))
                LabeledContent("All time", value: "\(Fmt.hm(store.entries(for: clientID).reduce(0) { $0 + $1.duration() })) in \(entryCount) entries")
            } header: {
                Text("Time")
            }

            ProjectsSection(clientID: clientID)

            Section {
                TextField("Keywords", text: $keywordsText, prompt: Text("acme, acme.com, weekly sync"))
                    .onSubmit(saveKeywords)
                    .onChange(of: keywordsText) { saveKeywords() }
            } header: {
                Text("Calendar matching")
            } footer: {
                Text("Separate with commas. Events whose title or location contains a keyword, or with attendees from a listed email domain, are matched to this client. The client name is matched too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                TextField("Notes", text: client.notes, prompt: Text("Contract details, contacts, purchase order numbers"), axis: .vertical)
                    .lineLimit(3...8)
                    .labelsHidden()
            }

            Section {
                Button("Delete client…", role: .destructive) { confirmDelete(entryCount: entryCount) }
            } footer: {
                Text(entryCount > 0 ? "Deleting also removes \(entryCount) time entries. Archive the client instead to keep their history." : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fadeUnderBars()
        .onAppear {
            keywordsText = client.wrappedValue.matchKeywords.joined(separator: ", ")
        }
    }

    private func confirmDelete(entryCount: Int) {
        let current = client.wrappedValue
        let deleteTitle = switch entryCount {
        case 0: "Delete client"
        case 1: "Delete client and 1 entry"
        default: "Delete client and \(entryCount) entries"
        }
        var actions = [AppDialog.Action(title: deleteTitle, isDestructive: true) {
            store.deleteClient(clientID)
            onDelete()
        }]
        if !current.isArchived {
            actions.append(AppDialog.Action(title: "Archive instead") { client.wrappedValue.isArchived = true })
        }
        dialogs.present(AppDialog(
            symbol: "trash.fill", tone: .destructive,
            title: "Delete \(current.name)?",
            message: "This cannot be undone.",
            actions: actions
        ))
    }

    private func saveKeywords() {
        let keywords = keywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if keywords != client.wrappedValue.matchKeywords {
            client.wrappedValue.matchKeywords = keywords
        }
    }
}

private struct ProjectsSection: View {
    let clientID: UUID
    @Environment(TimeStore.self) private var store
    @State private var newProjectName = ""

    var body: some View {
        Section {
            ForEach(store.projects(for: clientID, includeArchived: true)) { project in
                ProjectRow(project: project)
            }
            HStack {
                TextField("New project", text: $newProjectName, prompt: Text("Add a project"))
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Give a project a budget to see how much of it you have used.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.save(Project(clientID: clientID, name: name))
        newProjectName = ""
    }
}

private struct ProjectRow: View {
    let project: Project
    @Environment(TimeStore.self) private var store

    private var binding: Binding<Project> {
        Binding(get: { store.project(project.id) ?? project }, set: { store.save($0) })
    }

    var body: some View {
        let used = store.projectHours(project.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Project name", text: binding.name)
                    .labelsHidden()
                    .foregroundStyle(project.isArchived ? .secondary : .primary)
                TextField("Budget", value: binding.budgetHours, format: .number.precision(.fractionLength(0...1)), prompt: Text("Budget"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("h")
                    .foregroundStyle(.secondary)
                Toggle("Billable", isOn: binding.isBillable)
                    .toggleStyle(.checkbox)
                Menu {
                    Button(project.isArchived ? "Unarchive" : "Archive") { binding.wrappedValue.isArchived.toggle() }
                    Button("Delete", role: .destructive) { store.deleteProject(project.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let budget = project.budgetHours, budget > 0 {
                HStack(spacing: 8) {
                    AllocationBar(actual: used, allocation: budget, color: Color(hex: store.client(project.clientID)?.colorHex ?? Palette.fallback),
                                  status: used > budget ? .over : .onTrack, height: 5)
                    Text("\(Fmt.hours(used)) of \(Fmt.hours(budget)) used")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(used > budget ? .red : .secondary)
                        .fixedSize()
                }
            } else if used > 0 {
                Text("\(Fmt.hours(used)) logged")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
