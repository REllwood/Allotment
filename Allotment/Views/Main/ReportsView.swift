import Charts
import SwiftUI

enum RangePreset: String, CaseIterable, Identifiable {
    case thisWeek = "This week"
    case lastWeek = "Last week"
    case thisMonth = "This month"
    case lastMonth = "Last month"
    case last30 = "Last 30 days"
    case thisYear = "This year"
    case custom = "Custom range"

    var id: Self { self }

    func interval(schedule: WorkSchedule, now: Date, customStart: Date, customEnd: Date) -> DateInterval {
        let cal = schedule.calendar
        switch self {
        case .thisWeek: return schedule.week(containing: now)
        case .lastWeek: return schedule.period(.week, containing: now, offset: -1)
        case .thisMonth: return schedule.month(containing: now)
        case .lastMonth: return schedule.period(.month, containing: now, offset: -1)
        case .last30:
            let end = schedule.day(containing: now).end
            return DateInterval(start: cal.date(byAdding: .day, value: -30, to: end) ?? end, end: end)
        case .thisYear:
            return cal.dateInterval(of: .year, for: now) ?? schedule.month(containing: now)
        case .custom:
            let start = cal.startOfDay(for: min(customStart, customEnd))
            let end = schedule.day(containing: max(customStart, customEnd)).end
            return DateInterval(start: start, end: end)
        }
    }
}

struct ReportsView: View {
    enum Breakdown: String, CaseIterable, Identifiable {
        case client = "Clients"
        case project = "Projects"
        case activity = "Activities"
        var id: Self { self }
    }

    @Environment(TimeStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    @State private var preset: RangePreset = .thisMonth
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -13, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var clientFilter: Set<UUID> = []
    @State private var billable: BillableFilter = .all
    @State private var breakdown: Breakdown = .client

    private var filter: ReportFilter {
        ReportFilter(
            interval: preset.interval(schedule: store.schedule, now: .now, customStart: customStart, customEnd: customEnd),
            clientIDs: clientFilter.isEmpty ? nil : clientFilter,
            billable: billable
        )
    }

    var body: some View {
        let report = ReportBuilder.build(filter, store: store)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filterBar

                HStack(spacing: 14) {
                    StatTile(title: "Total", value: Fmt.hm(report.totalHours * 3600),
                             detail: "\(report.rows.count) entries", symbol: "clock.fill", tint: .blue)
                    StatTile(title: "Billable", value: Fmt.hm(report.billableHours * 3600),
                             detail: "\(Fmt.percent(report.billableShare)) of tracked time", symbol: "dollarsign.circle.fill", tint: .green)
                    StatTile(title: "Admin", value: Fmt.hm(report.adminHours * 3600),
                             detail: "Non-billable: \(Fmt.hm(report.nonBillableHours * 3600))", symbol: "tray.full.fill", tint: .gray)
                    StatTile(title: "Utilisation", value: Fmt.percent(report.utilization),
                             detail: report.isInProgress ? "of \(Fmt.hours(report.capacityToDate)) so far" : "of \(Fmt.hours(report.capacityToDate)) capacity", symbol: "gauge.with.dots.needle.50percent", tint: .orange)
                    if report.hasRates {
                        StatTile(title: "Billable amount", value: Fmt.money(report.amount, code: report.currencyCode),
                                 detail: "At each client's rate", symbol: "banknote.fill", tint: .purple)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    HoursChart(report: report)
                        .frame(maxWidth: .infinity)
                    ClientDonut(report: report)
                        .frame(width: 300)
                }

                breakdownCard(report)
                EntriesTable(report: report)
            }
            .padding(24)
        }
        .fadeUnderBars()
        .navigationTitle("Reports")
        .navigationSubtitle(Fmt.range(filter.interval))
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            exporting { try ExportService.export(ReportBuilder.build(filter, store: store), as: format) }
                        } label: {
                            Label(format.title, systemImage: format.symbol)
                        }
                    }
                    if store.workday.isEnabled {
                        Section("For Workday") {
                            Button {
                                exporting { try ExportService.exportWorkday(WorkdayBuilder.build(filter.interval, store: store), excel: true) }
                            } label: {
                                Label("Workday import sheet (.xlsx)", systemImage: "briefcase")
                            }
                            Button {
                                exporting { try ExportService.exportWorkday(WorkdayBuilder.build(filter.interval, store: store), excel: false) }
                            } label: {
                                Label("Workday import sheet (.csv)", systemImage: "briefcase")
                            }
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export this report as Excel, PDF or CSV")
            }
        }
    }

    private func exporting(_ export: () throws -> URL?) {
        do {
            _ = try export()
        } catch {
            dialogs.present(.problem("The file could not be saved", error: error))
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $preset) {
                ForEach(RangePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            if preset == .custom {
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                    .fixedSize()
                DatePicker("To", selection: $customEnd, displayedComponents: .date)
                    .fixedSize()
            }
            Menu {
                Button("All clients") { clientFilter = [] }
                Divider()
                ForEach(store.clients.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { client in
                    Toggle(client.isArchived ? "\(client.name) (archived)" : client.name, isOn: Binding(
                        get: { clientFilter.contains(client.id) },
                        set: { isOn in
                            if isOn { clientFilter.insert(client.id) } else { clientFilter.remove(client.id) }
                        }
                    ))
                }
            } label: {
                Label(clientFilterTitle, systemImage: "person.2")
            }
            .fixedSize()
            Picker("Time", selection: $billable) {
                ForEach(BillableFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if store.settings.rounding != .none {
                Label(store.settings.rounding.title, systemImage: "arrow.trianglehead.2.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Report totals use this rounding. Change it in Settings.")
            }
        }
    }

    private var clientFilterTitle: String {
        switch clientFilter.count {
        case 0: "All clients"
        case 1: store.client(clientFilter.first)?.name ?? "1 client"
        default: "\(clientFilter.count) clients"
        }
    }

    private func breakdownCard(_ report: Report) -> some View {
        let groups: [ReportGroup] = switch breakdown {
        case .client: report.byClient
        case .project: report.byProject
        case .activity: report.byActivity
        }
        let maxHours = max(groups.map(\.hours).max() ?? 0, groups.compactMap(\.allocated).max() ?? 0, 0.01)
        let showAllocation = breakdown == .client && groups.contains { $0.allocated != nil }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Breakdown")
                    .font(.headline)
                Spacer()
                Picker("Breakdown", selection: $breakdown) {
                    ForEach(Breakdown.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if groups.isEmpty {
                Text("No time in this period.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Name")
                        Text("")
                        Text("Hours").gridColumnAlignment(.trailing)
                        Text("Billable").gridColumnAlignment(.trailing)
                        if showAllocation {
                            Text(report.isInProgress ? "Allocated to date" : "Allocated").gridColumnAlignment(.trailing)
                            Text("Variance").gridColumnAlignment(.trailing)
                        }
                        if report.hasRates { Text("Amount").gridColumnAlignment(.trailing) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(groups) { group in
                        GridRow {
                            HStack(spacing: 8) {
                                ClientDot(color: Color(hex: group.colorHex))
                                Text(group.name).lineLimit(1)
                            }
                            .frame(minWidth: 180, alignment: .leading)
                            AllocationBar(actual: group.hours, allocation: group.allocated ?? maxHours,
                                          color: Color(hex: group.colorHex),
                                          status: report.isOver(group) ? .over : .onTrack)
                                .frame(minWidth: 120, maxWidth: .infinity)
                            Text(Fmt.hours(group.hours))
                            Text(Fmt.hours(group.billableHours)).foregroundStyle(.secondary)
                            if showAllocation {
                                Text(group.allocated.map { Fmt.hours($0) } ?? "")
                                    .foregroundStyle(.secondary)
                                Text(group.variance.map { ($0 > 0 ? "+" : "−") + Fmt.hours(abs($0)) } ?? "")
                                    .foregroundStyle(varianceColor(group, in: report))
                            }
                            if report.hasRates {
                                Text(group.amount > 0 ? Fmt.money(group.amount, code: report.currencyCode) : "")
                            }
                        }
                        .monospacedDigit()
                    }
                }
            }
        }
        .padding(18)
        .cardBackground()
    }

    private func varianceColor(_ group: ReportGroup, in report: Report) -> Color {
        if group.variance == nil { return .secondary }
        if report.isOver(group) { return .red }
        if report.isUnder(group) { return .blue }
        return .green
    }
}

private struct HoursChart: View {
    let report: Report

    var body: some View {
        let unit: Calendar.Component = report.days.count <= 45 ? .day : report.days.count <= 130 ? .weekOfYear : .month
        let groups = report.byClient.filter { $0.hours > 0 }

        VStack(alignment: .leading, spacing: 12) {
            Text(unit == .day ? "Hours by day" : unit == .weekOfYear ? "Hours by week" : "Hours by month")
                .font(.headline)
            Chart {
                ForEach(report.days) { day in
                    ForEach(day.byClient.sorted(by: { $0.key < $1.key }), id: \.key) { name, hours in
                        BarMark(x: .value("Date", day.date, unit: unit), y: .value("Hours", hours))
                            .foregroundStyle(by: .value("Client", name))
                    }
                }
            }
            .chartForegroundStyleScale(domain: groups.map(\.name), range: groups.map { Color(hex: $0.colorHex) })
            .chartXScale(domain: report.filter.interval.start...report.filter.interval.end)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) { Text("\(Int(hours))h") }
                    }
                }
            }
            .chartLegend(position: .bottom, spacing: 12)
            .frame(height: 230)
        }
        .padding(18)
        .cardBackground()
    }
}

private struct ClientDonut: View {
    let report: Report

    var body: some View {
        let groups = report.byClient.filter { $0.hours > 0 }
        VStack(alignment: .leading, spacing: 12) {
            Text("Share by client")
                .font(.headline)
            if groups.isEmpty {
                Text("No time in this period.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart(groups) { group in
                    SectorMark(angle: .value("Hours", group.hours), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(Color(hex: group.colorHex))
                        .cornerRadius(4)
                }
                .frame(height: 170)
                .overlay {
                    VStack(spacing: 0) {
                        Text(Fmt.hours(report.totalHours))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        Text("tracked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups.prefix(5)) { group in
                        HStack(spacing: 6) {
                            ClientDot(color: Color(hex: group.colorHex), size: 7)
                            Text(group.name).lineLimit(1)
                            Spacer()
                            Text(Fmt.percent(report.totalHours > 0 ? group.hours / report.totalHours : 0))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(18)
        .cardBackground()
    }
}

private struct EntriesTable: View {
    let report: Report
    private let limit = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Entries")
                    .font(.headline)
                Spacer()
                if report.rows.count > limit {
                    Text("Showing the latest \(limit) of \(report.rows.count). Export to see them all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if report.rows.isEmpty {
                Text("No entries match these filters.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("Date")
                        Text("Time")
                        Text("Client")
                        Text("Project")
                        Text("Activity")
                        Text("Notes")
                        Text("Hours").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(report.rows.suffix(limit).reversed()) { row in
                        GridRow {
                            Text(Fmt.shortDay(row.start))
                            Text("\(Fmt.time(row.start)) to \(row.end.map(Fmt.time) ?? "now")")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                ClientDot(color: Color(hex: row.clientColorHex), size: 7)
                                Text(row.clientName)
                            }
                            Text(row.projectName).foregroundStyle(.secondary)
                            Text(row.activityName).foregroundStyle(.secondary)
                            Text(row.notes)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Fmt.hours(row.hours))
                                .monospacedDigit()
                                .foregroundStyle(row.isBillable ? .primary : .secondary)
                        }
                        .lineLimit(1)
                        .font(.callout)
                    }
                }
            }
        }
        .padding(18)
        .cardBackground()
    }
}
