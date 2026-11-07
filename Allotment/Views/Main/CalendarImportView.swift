import SwiftUI

/// Turns calendar events into time entries.
struct CalendarImportView: View {
    @Environment(TimeStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(Ticker.self) private var ticker
    @State private var date = Date.now
    /// Client choices made here for events that matched nothing, or matched the wrong client.
    @State private var overrides: [String: UUID?] = [:]
    @State private var showDismissed = false

    var body: some View {
        Group {
            if calendar.hasAccess {
                eventList
            } else {
                accessPrompt
            }
        }
        .navigationTitle("Calendar")
        .navigationSubtitle(Fmt.day(date))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous day")
                Button("Today") { date = .now }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next day")
            }
            if calendar.hasAccess {
                ToolbarItem {
                    Toggle(isOn: $showDismissed) {
                        Label("Show skipped", systemImage: "eye")
                    }
                    .help("Show events you chose to skip")
                }
                ToolbarItem {
                    Button {
                        logAllMatched()
                    } label: {
                        Label("Log all matched", systemImage: "checkmark.circle")
                    }
                    .help("Log every finished event that has a client")
                }
            }
        }
    }

    private var events: [CalendarEvent] {
        _ = calendar.revision
        return calendar.events(in: store.schedule.day(containing: date), settings: store.settings)
    }

    private func client(for event: CalendarEvent) -> Client? {
        if let choice = overrides[event.id] { return store.client(choice) }
        return EventMatcher.client(for: event, in: store.activeClients)
    }

    @ViewBuilder
    private var eventList: some View {
        let logged = store.loggedEventKeys
        let dismissed = store.dismissedEventKeys
        let visible = events.filter { showDismissed || !dismissed.contains($0.id) }

        if visible.isEmpty {
            EmptyStateView(symbol: "calendar", title: "No events",
                           message: "There is nothing on your selected calendars for this day. Choose calendars in Settings.")
        } else {
            List {
                ForEach(visible) { event in
                    CalendarEventLine(
                        event: event,
                        client: client(for: event),
                        isLogged: logged.contains(event.id),
                        isDismissed: dismissed.contains(event.id),
                        now: ticker.now,
                        chooseClient: { overrides[event.id] = .some($0) }
                    )
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) {
                Text("Events are matched to clients by name, keywords and attendee email domains. Set keywords on each client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.bar)
            }
        }
    }

    private var accessPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("Log meetings straight from your calendar")
                .font(.title2.weight(.semibold))
            Text("Allotment reads the calendars on this Mac, including Google and Outlook accounts added in System Settings. It matches events to clients so you can log them in one click. Nothing is uploaded and Allotment never changes your calendar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if calendar.canRequestAccess {
                Button("Connect calendar") { calendar.requestAccess() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            } else {
                Text("Calendar access is turned off for Allotment.")
                    .font(.callout)
                Button("Open Privacy Settings") { calendar.openPrivacySettings() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button("Check again") { calendar.refreshStatus() }
                    .buttonStyle(.link)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shift(_ days: Int) {
        date = store.schedule.calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    private func logAllMatched() {
        let logged = store.loggedEventKeys
        let dismissed = store.dismissedEventKeys
        for event in events where event.end <= .now && !event.isDeclined && !logged.contains(event.id) && !dismissed.contains(event.id) {
            if let client = client(for: event) {
                store.logEvent(event, clientID: client.id)
            }
        }
    }
}

private struct CalendarEventLine: View {
    let event: CalendarEvent
    let client: Client?
    let isLogged: Bool
    let isDismissed: Bool
    let now: Date
    let chooseClient: (UUID?) -> Void
    @Environment(TimeStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: event.calendarColorHex).gradient)
                .frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body.weight(.medium))
                    .strikethrough(event.isDeclined)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(Fmt.time(event.start)) to \(Fmt.time(event.end)) · \(Fmt.hm(event.duration))")
                    if !event.calendarTitle.isEmpty { Text("· \(event.calendarTitle)") }
                    if !event.attendeeEmails.isEmpty { Text("· \(event.attendeeEmails.count) attendees") }
                    if event.isDeclined { Text("· Declined") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()

            Menu {
                Button("No client") { chooseClient(nil) }
                Divider()
                ForEach(store.activeClients) { option in
                    Button(option.name) { chooseClient(option.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    ClientDot(color: Color(hex: client?.colorHex ?? Palette.internalHex))
                    Text(client?.name ?? "Choose client")
                }
            }
            .fixedSize()
            .disabled(isLogged)

            Group {
                if isLogged {
                    Label("Logged", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isDismissed {
                    Button("Restore") { store.restoreEvent(event.id) }
                } else {
                    Button("Log") { withAnimation { store.logEvent(event, clientID: client?.id) } }
                        .buttonStyle(.glassProminent)
                        .disabled(event.start > now)
                        .help(event.start > now ? "This event has not started yet" : "Add \(Fmt.hm(event.duration)) to your timesheet")
                    Button("Skip") { withAnimation { store.dismissEvent(event.id) } }
                        .help("Hide this event and do not log it")
                }
            }
            .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(isDismissed ? 0.5 : 1)
    }
}
