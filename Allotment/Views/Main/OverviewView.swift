import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Ticker.self) private var ticker

    var body: some View {
        // Refresh once a minute rather than every second. The sidebar shows the live clock.
        let now = ticker.minute
        let schedule = store.schedule
        let today = schedule.day(containing: now)
        let week = schedule.week(containing: now)
        let month = schedule.month(containing: now)
        let weekReport = ReportBuilder.build(ReportFilter(interval: week), store: store, now: now)
        let monthReport = ReportBuilder.build(ReportFilter(interval: month), store: store, now: now)
        let todayHours = store.totalHours(in: today, now: now)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(now: now)

                if store.clients.isEmpty {
                    GettingStartedCard()
                }

                HStack(alignment: .top, spacing: 14) {
                    OverviewTimerCard()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            StatTile(title: "Today", value: Fmt.hm(todayHours * 3600),
                                     detail: schedule.isWorkday(now) ? "of \(Fmt.hours(schedule.dailyTarget)) target" : "Not a working day",
                                     symbol: "sun.max.fill", tint: .orange)
                            StatTile(title: "This week", value: Fmt.hm(weekReport.totalHours * 3600),
                                     detail: "\(Fmt.percent(weekReport.capacityHours > 0 ? weekReport.totalHours / weekReport.capacityHours : 0)) of \(Fmt.hours(weekReport.capacityHours))",
                                     symbol: "calendar", tint: .blue)
                        }
                        GridRow {
                            StatTile(title: "Billable", value: Fmt.percent(weekReport.billableShare),
                                     detail: "\(Fmt.hm(weekReport.billableHours * 3600)) this week",
                                     symbol: "dollarsign.circle.fill", tint: .green)
                            StatTile(title: "This month", value: monthReport.hasRates ? Fmt.money(monthReport.amount, code: monthReport.currencyCode) : Fmt.hm(monthReport.totalHours * 3600),
                                     detail: monthReport.hasRates ? "\(Fmt.hm(monthReport.billableHours * 3600)) billable" : "Set rates to see earnings",
                                     symbol: "chart.line.uptrend.xyaxis", tint: .purple)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 14) {
                    WeekChartCard(report: weekReport, target: schedule.dailyTarget)
                        .frame(maxWidth: .infinity)
                    AllocationsCard(now: now)
                        .frame(width: 360)
                }

                TodayEntriesCard(now: now)
            }
            .padding(24)
        }
        .fadeUnderBars()
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button {
                    router.editing = EntryEditTarget(entryID: nil, day: .now)
                } label: {
                    Label("Add time", systemImage: "plus")
                }
                .help("Add time manually")
            }
        }
    }

    private func header(now: Date) -> some View {
        let hour = Calendar.current.component(.hour, from: now)
        let greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let firstName = store.settings.userName.split(separator: " ").first.map(String.init) ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(firstName.isEmpty ? greeting : "\(greeting), \(firstName)")
                .font(.largeTitle.weight(.semibold))
            Text(Fmt.day(now))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct GettingStartedCard: View {
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "timer")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up your clients")
                    .font(.title3.weight(.semibold))
                Text("Add each client with an hourly rate and the hours you are allocated, then start timers from the menu bar. You can also load sample data to look around first.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Add a client") {
                _ = store.newClient()
                router.selection = .clients
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button("Load sample data") { store.loadSampleData() }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(20)
        .cardBackground()
    }
}

private struct WeekChartCard: View {
    let report: Report
    let target: Double

    var body: some View {
        let names = report.byClient.filter { $0.hours > 0 }.map(\.name)
        let colors = report.byClient.filter { $0.hours > 0 }.map { Color(hex: $0.colorHex) }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This week")
                    .font(.headline)
                Spacer()
                Text(Fmt.range(report.filter.interval))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(report.days) { day in
                    ForEach(day.byClient.sorted(by: { $0.key < $1.key }), id: \.key) { name, hours in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Hours", hours)
                        )
                        .foregroundStyle(by: .value("Client", name))
                        .cornerRadius(3)
                    }
                }
                if target > 0 {
                    RuleMark(y: .value("Daily target", target))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Target \(Fmt.hours(target))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartXScale(domain: report.filter.interval.start...report.filter.interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) { Text("\(Int(hours))h") }
                    }
                }
            }
            .chartLegend(position: .bottom, spacing: 12)
            .frame(height: 240)
        }
        .padding(18)
        .cardBackground()
    }
}

private struct AllocationsCard: View {
    let now: Date
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let engine = ForecastEngine(store: store)
        let allocated = store.activeClients.filter { $0.allocationHours != nil }
        let forecasts = engine.forecasts(for: allocated, at: now)
        let capacity = engine.capacity(for: allocated)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Allocations")
                    .font(.headline)
                Spacer()
                Button("Forecast") { router.selection = .forecast }
                    .buttonStyle(.link)
            }
            if forecasts.isEmpty {
                Text("Give clients an allocation, such as 16 hours a week, to see whether you are over or under.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(forecasts) { forecast in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            ClientDot(color: Color(hex: forecast.client.colorHex))
                            Text(forecast.client.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            StatusPill(status: forecast.status, compact: true)
                        }
                        AllocationBar(actual: forecast.actual, allocation: forecast.allocation ?? 0,
                                      expected: forecast.expectedToDate, color: Color(hex: forecast.client.colorHex),
                                      status: forecast.status)
                        Text("\(Fmt.hours(forecast.actual)) of \(Fmt.hours(forecast.allocation ?? 0)) this \(forecast.client.allocationPeriod.title.lowercased()) · heading for \(Fmt.hours(forecast.projected))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("The notch on each bar marks where you should be by now.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Divider()
                HStack {
                    Image(systemName: capacity.isOverbooked ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(capacity.isOverbooked ? .orange : .green)
                    Text(capacity.isOverbooked
                         ? "Allocations are \(Fmt.hours(-capacity.free)) a week over your \(Fmt.hours(capacity.weeklyCapacity)) capacity."
                         : "\(Fmt.hours(capacity.weeklyAllocated)) of \(Fmt.hours(capacity.weeklyCapacity)) a week is allocated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .cardBackground()
    }
}

private struct TodayEntriesCard: View {
    let now: Date
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        let day = store.schedule.day(containing: now)
        let dayEntries = store.entries(in: day)
        let entries = dayEntries.reversed()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today")
                    .font(.headline)
                Spacer()
                Button("Open timesheet") {
                    router.timesheetDate = now
                    router.selection = .timesheet
                }
                .buttonStyle(.link)
            }
            DayTimeline(day: day, entries: dayEntries, events: calendar.timelineEvents(in: day, settings: store.settings), now: now)
            if entries.isEmpty {
                Text("Nothing tracked yet today. Start a timer from the menu bar or add time here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries)) { entry in
                        EntryRow(entry: entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(18)
        .cardBackground()
    }
}

/// The running timer, large, or a quick way to start one.
private struct OverviewTimerCard: View {
    @Environment(TimeStore.self) private var store
    @Environment(Ticker.self) private var ticker

    var body: some View {
        if let running = store.runningEntry {
            runningCard(running)
        } else {
            idleCard
        }
    }

    private func runningCard(_ entry: TimeEntry) -> some View {
        let color = store.color(for: entry.clientID)
        let subtitle = [store.subtitle(for: entry), entry.notes].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PulsingDot(color: color)
                Text("TRACKING")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(color)
                Spacer()
                Text("Since \(Fmt.time(entry.start))\(entry.isBillable ? " · Billable" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title(for: entry))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                Text(Fmt.clock(entry.duration(at: ticker.now), showSeconds: true))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    withAnimation(.snappy) { store.stopTimer() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(RoundActionButtonStyle(tint: .red, size: 54))
                .help("Stop the timer")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [color.opacity(0.3), color.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(color.opacity(0.3)))
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOT TRACKING")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start a timer")
                    .font(.title2.weight(.semibold))
                Text("Pick a client, or press play to track without one.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 8) {
                // As many favourite clients as fit without cutting a name short.
                ViewThatFits(in: .horizontal) {
                    clientChips(3)
                    clientChips(2)
                    clientChips(1)
                    Color.clear.frame(height: 1)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) { _ = store.startTimer(clientID: nil) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(RoundActionButtonStyle(tint: .accentColor, size: 54))
                .help("Start a timer with no client")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(cornerRadius: 18)
    }

    private func clientChips(_ count: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(store.favoriteClients.prefix(count)) { client in
                Button {
                    withAnimation(.snappy) { _ = store.startTimer(clientID: client.id) }
                } label: {
                    HStack(spacing: 6) {
                        ClientDot(color: Color(hex: client.colorHex))
                        Text(client.name)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(hex: client.colorHex).opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Start tracking \(client.name)")
            }
        }
    }
}
