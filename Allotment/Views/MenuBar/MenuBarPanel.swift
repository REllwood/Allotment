import SwiftUI

struct MenuBarPanel: View {
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var draftNotes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem = store.storageProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.clients.isEmpty {
                WelcomeCard(open: open)
            }

            if let running = store.runningEntry {
                RunningTimerCard(entry: running)
            } else {
                IdleTimerCard(notes: $draftNotes)
            }

            SummaryCard()
            PanelNoticeRow(open: open)
            StartList(notes: $draftNotes, open: open)

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button {
                open(.overview)
            } label: {
                Label("Open Allotment", systemImage: "macwindow")
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            FooterIconButton(symbol: "plus", help: "Add time by hand") {
                router.editing = EntryEditTarget(entryID: nil, day: .now)
                open(.timesheet)
            }
            FooterIconButton(symbol: "gearshape", help: "Settings") {
                open(.settings)
            }
            FooterIconButton(symbol: "power", help: "Quit Allotment") {
                store.saveNow()
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func open(_ item: SidebarItem) {
        router.selection = item
        dismiss()
        openWindow(id: AppWindow.main)
        NSApp.activate()
    }
}

// MARK: - Timer cards

private struct RunningTimerCard: View {
    let entry: TimeEntry
    @Environment(TimeStore.self) private var store
    @Environment(Ticker.self) private var ticker
    @State private var isEditingNotes = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        let client = store.client(entry.clientID)
        let color = store.color(for: entry.clientID)
        let subtitle = store.subtitle(for: entry)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PulsingDot(color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(client?.name ?? store.title(for: entry))
                        .font(.headline)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                adjustMenu
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.clock(entry.duration(at: ticker.now), showSeconds: true))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Since \(Fmt.time(entry.start))\(entry.isBillable ? " · Billable" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { store.stopTimer() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(RoundActionButtonStyle(tint: .red))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Stop the timer (⌘↩)")
            }

            notesField
        }
        .padding(14)
        .background(
            LinearGradient(colors: [color.opacity(0.26), color.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color.opacity(0.32))
        )
    }

    /// Notes show as text until clicked, so opening the panel never selects them and lets a keystroke replace them.
    @ViewBuilder
    private var notesField: some View {
        if isEditingNotes {
            TextField("What are you working on?", text: Binding(
                get: { store.runningEntry?.notes ?? "" },
                set: { value in store.updateRunning { $0.notes = value } }
            ))
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($notesFocused)
            .onSubmit { isEditingNotes = false }
            .onChange(of: notesFocused) { _, focused in if !focused { isEditingNotes = false } }
            .onAppear { notesFocused = true }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Button {
                isEditingNotes = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(.tertiary)
                    Text(entry.notes.isEmpty ? "Add a note" : entry.notes)
                        .foregroundStyle(entry.notes.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "pencil")
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.background.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit the note for this timer")
        }
    }

    private var adjustMenu: some View {
        Menu {
            Section("Started earlier") {
                ForEach([5, 15, 30], id: \.self) { minutes in
                    Button("\(minutes) minutes earlier") {
                        store.updateRunning { $0.start = $0.start.addingTimeInterval(TimeInterval(-minutes * 60)) }
                    }
                }
            }
            Section("Activity") {
                ForEach(store.activities) { activity in
                    Button {
                        store.updateRunning {
                            $0.activityID = activity.id
                            $0.isBillable = store.defaultBillable(clientID: $0.clientID, projectID: $0.projectID, activityID: activity.id)
                        }
                    } label: {
                        Label(activity.name, systemImage: entry.activityID == activity.id ? "checkmark" : activity.symbol)
                    }
                }
            }
            if !store.projects(for: entry.clientID).isEmpty {
                Section("Project") {
                    ForEach(store.projects(for: entry.clientID)) { project in
                        Button {
                            store.updateRunning {
                                $0.projectID = project.id
                                $0.isBillable = store.defaultBillable(clientID: $0.clientID, projectID: project.id, activityID: $0.activityID)
                            }
                        } label: {
                            Label(project.name, systemImage: entry.projectID == project.id ? "checkmark" : "folder")
                        }
                    }
                }
            }
            Divider()
            Button(entry.isBillable ? "Mark as non-billable" : "Mark as billable") {
                store.updateRunning { $0.isBillable.toggle() }
            }
            Button("Discard this timer", role: .destructive) {
                store.discardRunningTimer()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Adjust this timer")
    }
}

private struct IdleTimerCard: View {
    @Binding var notes: String
    @Environment(TimeStore.self) private var store
    @Environment(Ticker.self) private var ticker
    @State private var showDetails = false
    @State private var clientID: UUID?
    @State private var projectID: UUID?
    @State private var activityID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not tracking")
                        .font(.headline)
                    Text(lastStopped)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: startFromDetails) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(RoundActionButtonStyle(tint: .accentColor))
                .help(clientID == nil ? "Start a timer with no client" : "Start the timer")
            }

            HStack(spacing: 8) {
                TextField("What are you working on?", text: $notes)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit(startFromDetails)
                Button {
                    withAnimation(.snappy) { showDetails.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(showDetails ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Choose client, project and activity")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            if showDetails {
                VStack(spacing: 8) {
                    Picker("Client", selection: $clientID) {
                        Text("No client").tag(UUID?.none)
                        ForEach(store.activeClients) { client in
                            Text(client.name).tag(Optional(client.id))
                        }
                    }
                    Picker("Project", selection: $projectID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.projects(for: clientID)) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .disabled(store.projects(for: clientID).isEmpty)
                    Picker("Activity", selection: $activityID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.activities) { activity in
                            Text(activity.name).tag(Optional(activity.id))
                        }
                    }
                }
                .pickerStyle(.menu)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .onChange(of: clientID) { projectID = nil }
            }
        }
        .padding(14)
        .cardBackground(cornerRadius: 16)
    }

    private var lastStopped: String {
        let _ = ticker.minute
        if let end = store.recentWork(limit: 1).first?.end, store.schedule.calendar.isDateInToday(end) {
            return "Last timer stopped at \(Fmt.time(end))"
        }
        return "Pick a client below, or press play"
    }

    private func startFromDetails() {
        withAnimation(.snappy) {
            _ = store.startTimer(clientID: clientID, projectID: projectID, activityID: activityID, notes: notes)
        }
        notes = ""
        showDetails = false
    }
}

private struct WelcomeCard: View {
    let open: (SidebarItem) -> Void
    @Environment(TimeStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Allotment")
                .font(.headline)
            Text("Add your clients to get one-click tracking from the menu bar. Everything stays on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add a client") {
                    _ = store.newClient()
                    open(.clients)
                }
                .buttonStyle(.glassProminent)
                Button("Try sample data") {
                    store.loadSampleData()
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16)
    }
}

// MARK: - Today and this week

private struct SummaryCard: View {
    @Environment(TimeStore.self) private var store
    @Environment(Ticker.self) private var ticker

    var body: some View {
        let now = ticker.minute
        let schedule = store.schedule
        let week = schedule.week(containing: now)
        let days = schedule.days(in: week)
        let hours = days.map { store.totalHours(in: schedule.day(containing: $0), now: now) }
        let todayIndex = days.firstIndex { schedule.calendar.isDate($0, inSameDayAs: now) }
        let today = todayIndex.map { hours[$0] } ?? 0
        let todayTarget = schedule.isWorkday(now) ? schedule.dailyTarget : 0

        HStack(alignment: .bottom, spacing: 16) {
            stat("Today", hours: today, target: todayTarget)
            stat("This week", hours: hours.reduce(0, +), target: schedule.capacityHours(in: week))
            Spacer(minLength: 0)
            WeekBars(days: days, hours: hours, todayIndex: todayIndex, target: schedule.dailyTarget, calendar: schedule.calendar)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardBackground(cornerRadius: 14)
    }

    private func stat(_ title: String, hours: Double, target: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Fmt.hm(hours * 3600))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(target > 0 ? "of \(Fmt.hm(target * 3600))" : "Day off")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

/// Seven small bars, one for each day of this week, with today highlighted.
private struct WeekBars: View {
    let days: [Date]
    let hours: [Double]
    let todayIndex: Int?
    let target: Double
    let calendar: Calendar

    private let barHeight: CGFloat = 34

    var body: some View {
        let top = max(target, hours.max() ?? 0, 0.1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(days.indices, id: \.self) { index in
                let isToday = index == todayIndex
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(.primary.opacity(0.07))
                            .frame(width: 7, height: barHeight)
                        if hours[index] > 0 {
                            Capsule()
                                .fill(isToday ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.32)))
                                .frame(width: 7, height: max(5, barHeight * min(1, hours[index] / top)))
                        }
                    }
                    Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: days[index]) - 1])
                        .font(.system(size: 9, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? .primary : .tertiary)
                }
                .frame(width: 11)
                .help("\(Fmt.day(days[index])): \(Fmt.hm(hours[index] * 3600))")
            }
        }
    }
}

// MARK: - The one thing that needs attention

/// A single row for whichever matters most right now, so the panel stays short.
private struct PanelNoticeRow: View {
    let open: (SidebarItem) -> Void
    @Environment(TimeStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(Ticker.self) private var ticker

    private struct Notice {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let actionTitle: String
        let action: () -> Void
    }

    var body: some View {
        if let notice = currentNotice() {
            HStack(spacing: 10) {
                Image(systemName: notice.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(notice.tint)
                    .frame(width: 28, height: 28)
                    .background(notice.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(notice.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(notice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Button(notice.actionTitle) {
                    withAnimation(.snappy) { notice.action() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .cardBackground(cornerRadius: 12)
        }
    }

    /// In order: a meeting on now, a client over its allocation, weeks missing from Workday,
    /// a finished meeting to log, a client trending over, then the offer to connect a calendar.
    private func currentNotice() -> Notice? {
        let now = ticker.minute
        var finishedMeetings: [CalendarEvent] = []

        if calendar.hasAccess {
            let _ = calendar.revision
            let logged = store.loggedEventKeys
            let dismissed = store.dismissedEventKeys
            let events = calendar.events(in: store.schedule.day(containing: now), settings: store.settings)
                .filter { !logged.contains($0.id) && !dismissed.contains($0.id) && !$0.isDeclined && !$0.isAllDay }
            if let meeting = events.first(where: { $0.isHappening(at: now) }), store.runningEntry?.notes != meeting.title {
                let client = EventMatcher.client(for: meeting, in: store.activeClients)
                return Notice(symbol: "person.2.fill", tint: .accentColor, title: meeting.title,
                              detail: "On now until \(Fmt.time(meeting.end))\(client.map { " · \($0.name)" } ?? "")",
                              actionTitle: "Track") {
                    _ = store.startTimer(clientID: client?.id, activityID: store.meetingActivity?.id, notes: meeting.title)
                }
            }
            finishedMeetings = events.filter { $0.end <= now }
        }

        let forecasts = ForecastEngine(store: store)
            .forecasts(for: store.activeClients.filter { $0.allocationHours != nil }, at: now)
            .sorted { $0.progress > $1.progress }
        if let over = forecasts.first(where: { $0.status == .over }) {
            return Notice(symbol: over.status.symbol, tint: over.status.color, title: "\(over.client.name) is over",
                          detail: allocationDetail(over), actionTitle: "Forecast") { open(.forecast) }
        }

        if store.workday.isEnabled {
            let outstanding = WorkdayBuilder.outstandingWeeks(store: store, now: now)
            if let latest = outstanding.first {
                return Notice(symbol: "briefcase.fill", tint: .orange,
                              title: outstanding.count == 1 ? "A week is not in Workday yet" : "\(outstanding.count) weeks are not in Workday yet",
                              detail: "\(Fmt.range(latest.interval)) · \(Fmt.hm(latest.total * 3600))",
                              actionTitle: "Open") { open(.workday) }
            }
        }

        if let meeting = finishedMeetings.last {
            let client = EventMatcher.client(for: meeting, in: store.activeClients)
            let more = finishedMeetings.count - 1
            return Notice(symbol: "calendar.badge.clock", tint: .accentColor, title: meeting.title,
                          detail: "\(Fmt.time(meeting.start)) to \(Fmt.time(meeting.end))\(client.map { " · \($0.name)" } ?? "")\(more > 0 ? " · \(more) more" : "")",
                          actionTitle: "Log") {
                store.logEvent(meeting, clientID: client?.id)
            }
        }

        if let trending = forecasts.first(where: { $0.status == .trendingOver }) {
            return Notice(symbol: trending.status.symbol, tint: trending.status.color, title: "\(trending.client.name) is trending over",
                          detail: "\(allocationDetail(trending)) · heading for \(Fmt.hm(trending.projected * 3600))",
                          actionTitle: "Forecast") { open(.forecast) }
        }

        if calendar.canRequestAccess {
            return Notice(symbol: "calendar.badge.plus", tint: .accentColor, title: "Connect your calendar",
                          detail: "Log meetings in one click", actionTitle: "Connect") { calendar.requestAccess() }
        }
        return nil
    }

    private func allocationDetail(_ forecast: ClientForecast) -> String {
        "\(Fmt.hm(forecast.actual * 3600)) of \(Fmt.hm((forecast.allocation ?? 0) * 3600)) this \(forecast.client.allocationPeriod.title.lowercased())"
    }
}

// MARK: - Start or switch

private struct StartList: View {
    @Binding var notes: String
    let open: (SidebarItem) -> Void
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Ticker.self) private var ticker
    @State private var tab: Tab?

    private enum Tab: String, CaseIterable, Identifiable {
        case clients = "Clients"
        case recent = "Recent"
        var id: Self { self }
    }

    /// Rows beyond this scroll, so a long client list cannot stretch the panel.
    private let visibleRows = 6
    private let rowHeight: CGFloat = 40

    var body: some View {
        let recent = store.recentWork(limit: 5)
        let current = tab ?? (store.favoriteClients.isEmpty && !recent.isEmpty ? .recent : .clients)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(store.runningEntry == nil ? "START" : "SWITCH TO")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Tab.allCases) { item in
                        Button(item.rawValue) {
                            withAnimation(.snappy) { tab = item }
                        }
                        .buttonStyle(TabPillStyle(isSelected: item == current))
                    }
                }
                .padding(2)
                .background(.primary.opacity(0.05), in: Capsule())
            }

            switch current {
            case .clients:
                rows(count: store.favoriteClients.count + 1) {
                    ForEach(store.favoriteClients) { client in
                        clientRow(client)
                    }
                    adminRow
                }
                if store.favoriteClients.isEmpty && !store.clients.isEmpty {
                    Button("Choose favourite clients…") { open(.clients) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            case .recent:
                if recent.isEmpty {
                    Text("Work you track shows here, ready to start again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    rows(count: recent.count) {
                        ForEach(recent) { entry in
                            recentRow(entry)
                        }
                    }
                }
            }
        }
    }

    /// Rows reach a little past the panel's margins, so their hover highlight lines up with the cards above.
    @ViewBuilder
    private func rows<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        if count > visibleRows {
            ScrollView { VStack(spacing: 0) { content() } }
                .frame(height: CGFloat(visibleRows) * rowHeight)
                .padding(.horizontal, -8)
        } else {
            VStack(spacing: 0) { content() }
                .padding(.horizontal, -8)
        }
    }

    private func clientRow(_ client: Client) -> some View {
        let running = store.runningEntry
        let isRunning = running?.clientID == client.id
        let color = Color(hex: client.colorHex)
        let forecast = client.allocationHours == nil ? nil : ForecastEngine(store: store).forecasts(for: [client], at: ticker.minute).first
        let detail: String
        var detailTint: Color?
        if isRunning {
            detail = "Tracking now"
            detailTint = color
        } else if let forecast, let allocation = forecast.allocation {
            detail = "\(Fmt.hm(forecast.actual * 3600)) of \(Fmt.hm(allocation * 3600)) this \(client.allocationPeriod.title.lowercased())"
            if forecast.status == .over || forecast.status == .trendingOver { detailTint = forecast.status.color }
        } else {
            detail = "\(Fmt.hm(store.hours(clientID: client.id, in: store.schedule.week(containing: ticker.minute), now: ticker.minute) * 3600)) this week"
        }

        return StartRow(title: client.name, detail: detail, detailTint: detailTint, tint: color, isActive: isRunning) {
            start(clientID: client.id)
        }
        .help("Start tracking \(client.name). Right-click for projects and activities.")
        .contextMenu { clientMenu(client) }
    }

    private var adminRow: some View {
        let running = store.runningEntry
        let isActive = running != nil && running?.clientID == nil && store.activity(running?.activityID)?.isAdmin == true
        return StartRow(title: "Admin", detail: "Internal, not for a client", tint: .gray, symbol: "tray.full", isActive: isActive) {
            start(clientID: nil, activityID: store.adminActivity?.id)
        }
        .help("Track internal admin that is not for any client")
    }

    private func recentRow(_ entry: TimeEntry) -> some View {
        let running = store.runningEntry
        let isActive = running.map {
            $0.clientID == entry.clientID && $0.projectID == entry.projectID && $0.activityID == entry.activityID && $0.notes == entry.notes
        } ?? false
        let detail = [store.subtitle(for: entry), entry.notes].filter { !$0.isEmpty }.joined(separator: " · ")
        return StartRow(title: store.title(for: entry), detail: detail, trailing: Fmt.hm(entry.duration()),
                        tint: store.color(for: entry.clientID), isActive: isActive) {
            withAnimation(.snappy) { store.resume(entry) }
        }
        .help("Start this again")
    }

    @ViewBuilder
    private func clientMenu(_ client: Client) -> some View {
        let projects = store.projects(for: client.id)
        if !projects.isEmpty {
            Section("Start on a project") {
                ForEach(projects) { project in
                    Button(project.name) { start(clientID: client.id, projectID: project.id) }
                }
            }
        }
        Section("Start an activity") {
            ForEach(store.activities) { activity in
                Button {
                    start(clientID: client.id, activityID: activity.id)
                } label: {
                    Label("\(activity.name) for \(client.name)", systemImage: activity.symbol)
                }
            }
        }
        Divider()
        Button("Edit \(client.name)…") {
            router.selection = .clients
            open(.clients)
        }
    }

    private func start(clientID: UUID?, projectID: UUID? = nil, activityID: UUID? = nil) {
        withAnimation(.snappy) {
            _ = store.startTimer(clientID: clientID, projectID: projectID, activityID: activityID, notes: notes)
        }
        notes = ""
    }
}

/// One row of the start list: the whole row starts the timer, and the round button shows what will happen.
private struct StartRow: View {
    let title: String
    let detail: String
    var detailTint: Color?
    var trailing: String?
    let tint: Color
    var symbol: String?
    var isActive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        ClientDot(color: tint)
                    }
                }
                .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(detailTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(HierarchicalShapeStyle.secondary))
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ZStack {
                    Circle()
                        .fill(tint.opacity(isActive || hovering ? 0.24 : 0.13))
                    if isActive {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .offset(x: 1)
                    }
                }
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The small Clients and Recent switch.
private struct TabPillStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isSelected ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(Color.clear), in: Capsule())
            .contentShape(Capsule())
    }
}

private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .onHover { hovering = $0 }
        .help(help)
    }
}
