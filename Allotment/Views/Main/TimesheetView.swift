import SwiftUI

struct TimesheetView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        var id: Self { self }
    }

    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @State private var mode: Mode = .day

    var body: some View {
        @Bindable var router = router
        let schedule = store.schedule
        let week = schedule.week(containing: router.timesheetDate)

        VStack(spacing: 0) {
            WeekStrip(week: week, selected: $router.timesheetDate)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            Divider()
            switch mode {
            case .day: DayEntriesList(day: schedule.day(containing: router.timesheetDate))
            case .week: WeekGrid(week: week)
            }
        }
        .navigationTitle("Timesheet")
        .navigationSubtitle(mode == .day ? Fmt.day(router.timesheetDate) : Fmt.range(week))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help(mode == .day ? "Previous day" : "Previous week")
                Button("Today") { router.timesheetDate = .now }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help(mode == .day ? "Next day" : "Next week")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            ToolbarItem {
                Button {
                    router.editing = EntryEditTarget(entryID: nil, day: router.timesheetDate)
                } label: {
                    Label("New entry", systemImage: "plus")
                }
                .help("Add time manually")
            }
        }
    }

    private func shift(_ steps: Int) {
        let component: Calendar.Component = mode == .day ? .day : .weekOfYear
        router.timesheetDate = store.schedule.calendar.date(byAdding: component, value: steps, to: router.timesheetDate) ?? router.timesheetDate
    }
}

private struct WeekStrip: View {
    let week: DateInterval
    @Binding var selected: Date
    @Environment(TimeStore.self) private var store
    @Environment(Ticker.self) private var ticker

    var body: some View {
        let schedule = store.schedule
        let days = schedule.days(in: week)
        let weekTotal = store.totalHours(in: week, now: ticker.now)

        HStack(spacing: 8) {
            ForEach(days, id: \.self) { day in
                let hours = store.totalHours(in: schedule.day(containing: day), now: ticker.now)
                let isSelected = schedule.calendar.isDate(day, inSameDayAs: selected)
                let isToday = schedule.calendar.isDateInToday(day)
                Button {
                    selected = day
                } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isToday ? Color.accentColor : .secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.title3.weight(.semibold))
                        Text(hours > 0 ? Fmt.hm(hours * 3600) : "–")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(hours > 0 ? .primary : .tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(schedule.isWorkday(day) ? 0.04 : 0.015),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 3) {
                Text("Week")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(Fmt.hm(weekTotal * 3600))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("of \(Fmt.hours(schedule.weeklyCapacity))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90)
            .padding(.vertical, 8)
        }
    }
}

private struct DayEntriesList: View {
    let day: DateInterval
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Ticker.self) private var ticker
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        let entries = store.entries(in: day)
        let total = entries.reduce(0) { $0 + $1.duration(at: ticker.now) }
        let billable = entries.filter(\.isBillable).reduce(0) { $0 + $1.duration(at: ticker.now) }

        if entries.isEmpty {
            EmptyStateView(symbol: "clock.badge.questionmark", title: "No time on this day",
                           message: "Start a timer from the menu bar, log a meeting from your calendar, or add an entry with the plus button.")
        } else {
            List {
                DayTimeline(day: day, entries: entries, events: calendar.timelineEvents(in: day, settings: store.settings), now: ticker.minute)
                    .padding(.vertical, 10)
                    .listRowSeparator(.hidden)
                ForEach(entries) { entry in
                    EntryRow(entry: entry, showsActions: true)
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                    Spacer()
                    Text("Billable \(Fmt.hm(billable))")
                    Text("Total \(Fmt.hm(total))")
                        .fontWeight(.semibold)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}

/// One time entry, used in the timesheet and the overview.
struct EntryRow: View {
    let entry: TimeEntry
    var showsActions = false
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Ticker.self) private var ticker

    var body: some View {
        let color = store.color(for: entry.clientID)
        let subtitle = store.subtitle(for: entry)

        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.gradient)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(store.title(for: entry))
                        .font(.body.weight(.medium))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                if !entry.notes.isEmpty {
                    Text(entry.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if entry.source == .calendar {
                    Image(systemName: "calendar")
                        .help("Logged from your calendar")
                }
                if entry.isBillable {
                    Image(systemName: "dollarsign.circle")
                        .help("Billable")
                }
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            Text(entry.isRunning ? "\(Fmt.time(entry.start)) to now" : "\(Fmt.time(entry.start)) to \(Fmt.time(entry.end ?? entry.start))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            Text(entry.isRunning ? Fmt.clock(entry.duration(at: ticker.now), showSeconds: true) : Fmt.hm(entry.duration()))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(entry.isRunning ? color : .primary)
                .frame(width: 70, alignment: .trailing)
            if showsActions {
                if entry.isRunning {
                    Button {
                        store.stopTimer()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Stop")
                } else {
                    Button {
                        store.resume(entry)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Start a new timer for this work")
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit() }
        .contextMenu {
            Button("Edit…") { edit() }
            Button(entry.isRunning ? "Stop timer" : "Resume") {
                if entry.isRunning { store.stopTimer() } else { store.resume(entry) }
            }
            Button("Duplicate") {
                var copy = entry
                copy.id = UUID()
                copy.source = .manual
                copy.calendarEventKey = nil
                if copy.end == nil { copy.end = .now }
                store.save(copy)
            }
            Divider()
            Button("Delete", role: .destructive) { store.deleteEntry(entry.id) }
        }
    }

    private func edit() {
        router.editing = EntryEditTarget(entryID: entry.id, day: entry.start)
    }
}

/// Hours per client and project for each day of the week, like a paper timesheet.
private struct WeekGrid: View {
    let week: DateInterval
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Ticker.self) private var ticker

    private struct RowKey: Hashable {
        let clientID: UUID?
        let projectID: UUID?
    }

    var body: some View {
        let schedule = store.schedule
        let days = schedule.days(in: week)
        let entries = store.entries(in: week)
        let rows = Dictionary(grouping: entries) { RowKey(clientID: $0.clientID, projectID: $0.projectID) }
        let keys = rows.keys.sorted { label(for: $0) < label(for: $1) }

        if entries.isEmpty {
            EmptyStateView(symbol: "tablecells", title: "No time this week", message: "Time you track will add up here by client and day.")
        } else {
            ScrollView {
                Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Text("Client and project")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(days, id: \.self) { day in
                            Text(day.formatted(.dateTime.weekday(.abbreviated).day()))
                                .frame(width: 74, alignment: .trailing)
                        }
                        Text("Total")
                            .frame(width: 84, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(keys, id: \.self) { key in
                        let rowEntries = rows[key] ?? []
                        GridRow {
                            HStack(spacing: 8) {
                                ClientDot(color: store.color(for: key.clientID))
                                Text(label(for: key))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(days, id: \.self) { day in
                                let seconds = rowEntries
                                    .filter { schedule.calendar.isDate($0.start, inSameDayAs: day) }
                                    .reduce(0) { $0 + $1.duration(at: ticker.now) }
                                Button {
                                    router.timesheetDate = day
                                } label: {
                                    Text(seconds > 0 ? Fmt.hm(seconds) : "")
                                        .frame(width: 74, height: 28, alignment: .trailing)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Text(Fmt.hm(rowEntries.reduce(0) { $0 + $1.duration(at: ticker.now) }))
                                .fontWeight(.semibold)
                                .frame(width: 84, alignment: .trailing)
                        }
                        .font(.body.monospacedDigit())
                        .padding(.vertical, 4)
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }

                    GridRow {
                        Text("Total")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(days, id: \.self) { day in
                            Text(Fmt.hm(entries.filter { schedule.calendar.isDate($0.start, inSameDayAs: day) }
                                .reduce(0) { $0 + $1.duration(at: ticker.now) }))
                                .frame(width: 74, alignment: .trailing)
                        }
                        Text(Fmt.hm(entries.reduce(0) { $0 + $1.duration(at: ticker.now) }))
                            .frame(width: 84, alignment: .trailing)
                    }
                    .font(.body.monospacedDigit().weight(.semibold))
                    .padding(.vertical, 10)
                }
                .padding(24)
            }
        }
    }

    private func label(for key: RowKey) -> String {
        let client = store.client(key.clientID)?.name ?? "No client"
        guard let project = store.project(key.projectID)?.name else { return client }
        return "\(client): \(project)"
    }
}
