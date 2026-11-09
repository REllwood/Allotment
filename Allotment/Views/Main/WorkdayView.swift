import AppKit
import SwiftUI

/// Each week's time laid out the way Workday's Enter Time screen wants it, ready to copy, export or send.
struct WorkdayView: View {
    @Environment(TimeStore.self) private var store
    @Environment(WorkdaySync.self) private var sync
    @Environment(Ticker.self) private var ticker
    @State private var weekDate = WorkdayView.defaultWeekDate()
    @State private var showSetup = LaunchOptions.opensWorkdaySetup
    @Environment(DialogPresenter.self) private var dialogs
    @State private var copied: String?

    /// Opens on last week early in the week, when that is the one most likely to need submitting.
    private static func defaultWeekDate() -> Date {
        let weekday = Calendar.current.component(.weekday, from: .now)
        return weekday == 2 ? Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now : .now
    }

    var body: some View {
        let week = store.schedule.week(containing: weekDate)
        let period = WorkdayBuilder.build(week, store: store, now: ticker.minute)
        let status = WorkdayWeekStatus(period: period, submission: store.workdaySubmission(forWeekStarting: week.start))

        Group {
            if store.workday.isEnabled {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RecentWeeksStrip(selected: $weekDate)
                        statusCard(period: period, status: status)
                        if !period.issues.isEmpty { IssuesCard(issues: period.issues, openSetup: { showSetup = true }) }
                        SyncMessage()
                        if period.isEmpty {
                            EmptyStateView(symbol: "briefcase", title: "No time this week",
                                           message: "Hours you track for this week will appear here, grouped the way Workday wants them.")
                                .frame(height: 220)
                        } else {
                            gridCard(period)
                        }
                    }
                    .padding(24)
                }
                .fadeUnderBars()
            } else {
                WorkdayIntro(setUp: {
                    store.workday.isEnabled = true
                    showSetup = true
                })
            }
        }
        .navigationTitle("Workday")
        .navigationSubtitle(Fmt.range(week))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous week")
                Button("This week") { weekDate = .now }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next week")
            }
            ToolbarItem {
                Button {
                    showSetup = true
                } label: {
                    Label("Workday setup", systemImage: "slider.horizontal.3")
                }
                .help("Codes, projects and the Workday connection")
            }
        }
        .sheet(isPresented: $showSetup) {
            WorkdaySetupView()
        }
    }

    private func shift(_ weeks: Int) {
        weekDate = store.schedule.calendar.date(byAdding: .weekOfYear, value: weeks, to: weekDate) ?? weekDate
    }

    // MARK: - Status

    private func statusCard(period: WorkdayPeriod, status: WorkdayWeekStatus) -> some View {
        let scheduled = store.schedule.capacityHours(in: period.interval)
        let color: Color = switch status {
        case .submitted: .green
        case .changedSinceSubmitted, .partlySent: .orange
        case .notSubmitted: .blue
        case .empty: .secondary
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Fmt.decimal(period.total))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("hours for Workday")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(Fmt.decimalHours(scheduled)) scheduled · \(period.blocks.count) time \(period.blocks.count == 1 ? "block" : "blocks") · \(Fmt.range(period.interval))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(status.title, systemImage: status.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(color.opacity(0.13), in: Capsule())
            }

            HStack(spacing: 10) {
                Button {
                    copy(period.tableText, key: "week")
                } label: {
                    Label(copied == "week" ? "Copied" : "Copy week", systemImage: copied == "week" ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the week as a table, to paste into a spreadsheet or keep beside Workday")

                Menu {
                    Button("Excel workbook (.xlsx)") { exportForAdmin(period, excel: true) }
                    Button("CSV file") { exportForAdmin(period, excel: false) }
                } label: {
                    Label("Export for admin", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .help("An import sheet in the column order of Workday's Import Reported Time Blocks")

                // Shown once direct sync has been started in setup. Until it is signed in, the button finishes setup
                // instead of offering a send that would fail.
                if store.workday.api.isConfigured {
                    switch sync.connection(for: store.workday.api).stage {
                    case .signedIn:
                        Button {
                            confirmSend(period, status: status)
                        } label: {
                            Label(status.needsAttention && store.workdaySubmission(forWeekStarting: period.interval.start)?.method == .api
                                  ? "Send changes" : "Send to Workday", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(period.isEmpty || sync.isWorking || sync.pendingBlocks(in: period, store: store).isEmpty)
                    case .signedOut:
                        Button { showSetup = true } label: {
                            Label("Sign in to send", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .help("Sign in to Workday to send this week straight from here")
                    case .incomplete:
                        Button { showSetup = true } label: {
                            Label("Finish setup to send", systemImage: "slider.horizontal.3")
                        }
                        .help("Direct sync needs a few more details before it can send")
                    }
                }

                Spacer()

                switch status {
                case .submitted:
                    Button("Mark as not submitted") { store.clearWorkdaySubmission(forWeekStarting: period.interval.start) }
                        .buttonStyle(.link)
                case .empty:
                    EmptyView()
                default:
                    Button {
                        store.recordWorkdaySubmission(WorkdaySubmission(
                            weekStart: period.interval.start, submittedAt: .now, method: .manual,
                            hours: period.total, fingerprint: period.fingerprint))
                    } label: {
                        Label("Mark as entered in Workday", systemImage: "checkmark.circle")
                    }
                    .help("Tick this week off once its hours are in Workday")
                }
            }
            .controlSize(.large)
        }
        .padding(20)
        .cardBackground()
    }

    private func confirmSend(_ period: WorkdayPeriod, status: WorkdayWeekStatus) {
        dialogs.present(AppDialog(
            symbol: "paperplane.fill",
            title: sendTitle(period),
            message: sendMessage(period, status: status),
            actions: [AppDialog.Action(title: "Send to Workday") {
                Task { await sync.send(period, store: store) }
            }]
        ))
    }

    private func exportForAdmin(_ period: WorkdayPeriod, excel: Bool) {
        let saved: URL?
        do {
            saved = try ExportService.exportWorkday(period, excel: excel)
        } catch {
            dialogs.present(.problem("The file could not be saved", error: error))
            return
        }
        guard saved != nil else { return }
        if store.workdaySubmission(forWeekStarting: period.interval.start) == nil {
            store.recordWorkdaySubmission(WorkdaySubmission(
                weekStart: period.interval.start, submittedAt: .now, method: .export,
                hours: period.total, fingerprint: period.fingerprint))
        }
    }

    private func sendTitle(_ period: WorkdayPeriod) -> String {
        let count = sync.pendingBlocks(in: period, store: store).count
        return "Send \(count) time \(count == 1 ? "block" : "blocks") to Workday?"
    }

    private func sendMessage(_ period: WorkdayPeriod, status: WorkdayWeekStatus) -> String {
        var message = "Hours for \(Fmt.range(period.interval)) go to Workday as \(store.workday.api.workerName.isEmpty ? "the signed-in worker" : store.workday.api.workerName)."
        if case .changedSinceSubmitted = status {
            message += " This week changed after it was sent. Changed days are sent as new time blocks, so remove or edit the old ones in Workday to avoid counting them twice."
        }
        if period.hasRunningTimer {
            message += " A timer is still running, so today's hours may still change."
        }
        return message
    }

    // MARK: - Grid

    private func gridCard(_ period: WorkdayPeriod) -> some View {
        let target = store.schedule.dailyTarget
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Enter Time")
                    .font(.headline)
                Spacer()
                Text("Click any number to copy it. Comments show when you hover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Time entry code and project")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(period.days, id: \.self) { day in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            Text(day.formatted(.dateTime.day().month(.abbreviated)))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 62, alignment: .trailing)
                    }
                    Text("Total").frame(width: 70, alignment: .trailing)
                    Color.clear.frame(width: 36, height: 1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(period.lines) { line in
                    GridRow {
                        lineLabel(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(period.days, id: \.self) { day in
                            hoursCell(line: line, day: day)
                        }
                        Text(Fmt.decimal(line.total))
                            .font(.body.monospacedDigit().weight(.semibold))
                            .frame(width: 70, alignment: .trailing)
                        Button {
                            copy(([line.timeCode, line.project, line.task] + period.days.map { line.hours[$0].map { Fmt.decimal($0) } ?? "" })
                                    .joined(separator: "\t"), key: line.id)
                        } label: {
                            Image(systemName: copied == line.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 36)
                        .help("Copy this line")
                    }
                    .padding(.vertical, 8)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }

                GridRow {
                    Text("Day total")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(period.days, id: \.self) { day in
                        let total = period.dayTotal(day)
                        Text(total > 0 ? Fmt.decimal(total) : "")
                            .foregroundStyle(total > target * 1.25 ? .orange : .primary)
                            .frame(width: 62, alignment: .trailing)
                            .help(total > target * 1.25 ? "More than your usual \(Fmt.decimalHours(target)) day" : "")
                    }
                    Text(Fmt.decimal(period.total))
                        .frame(width: 70, alignment: .trailing)
                    Color.clear.frame(width: 36, height: 1)
                }
                .font(.body.monospacedDigit().weight(.semibold))
                .padding(.top, 10)
            }
        }
        .padding(18)
        .cardBackground()
    }

    private func lineLabel(_ line: WorkdayLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.timeCode.isEmpty ? "No time entry code" : line.timeCode)
                .font(.callout.weight(.semibold).monospaced())
                .foregroundStyle(line.timeCode.isEmpty ? .orange : .primary)
            if !line.project.isEmpty || !line.task.isEmpty {
                Text([line.project, line.task].filter { !$0.isEmpty }.joined(separator: " › "))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(line.title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func hoursCell(line: WorkdayLine, day: Date) -> some View {
        let key = "\(line.id)@\(day.timeIntervalSince1970)"
        if let hours = line.hours[day] {
            Button {
                copy(Fmt.decimal(hours), key: key)
            } label: {
                Text(copied == key ? "Copied" : Fmt.decimal(hours))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(copied == key ? Color.green : .primary)
                    .frame(width: 56, height: 26, alignment: .trailing)
                    .padding(.trailing, 6)
                    .background(Color.accentColor.opacity(copied == key ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 62, alignment: .trailing)
            .help(line.comments[day].map { "Comment: \($0)" } ?? "No comment")
            .contextMenu {
                Button("Copy hours") { copy(Fmt.decimal(hours), key: key) }
                if let comment = line.comments[day] {
                    Button("Copy comment") { copy(comment, key: key) }
                }
            }
        } else {
            Text("")
                .frame(width: 62)
        }
    }

    private func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.snappy) { copied = key }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copied == key { withAnimation(.snappy) { copied = nil } }
        }
    }
}

/// The last few weeks with their Workday status, so anything outstanding stands out.
private struct RecentWeeksStrip: View {
    @Binding var selected: Date
    @Environment(TimeStore.self) private var store
    @Environment(Ticker.self) private var ticker

    var body: some View {
        let schedule = store.schedule
        let selectedWeek = schedule.week(containing: selected)
        HStack(spacing: 8) {
            ForEach((0..<6).reversed(), id: \.self) { back in
                let week = schedule.period(.week, containing: ticker.minute, offset: -back)
                let period = WorkdayBuilder.build(week, store: store, now: ticker.minute)
                let status = WorkdayWeekStatus(period: period, submission: store.workdaySubmission(forWeekStarting: week.start))
                let isSelected = week.start == selectedWeek.start
                Button {
                    selected = week.start
                } label: {
                    VStack(spacing: 4) {
                        Text(back == 0 ? "This week" : back == 1 ? "Last week" : week.start.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(period.isEmpty ? "–" : Fmt.decimal(period.total, digits: 1))
                            .font(.title3.weight(.semibold).monospacedDigit())
                        let tint: Color = status.needsAttention ? (back == 0 ? .secondary : .orange) : status == .empty ? .secondary : .green
                        Label(back == 0 && status == .notSubmitted ? "In progress" : status.shortTitle, systemImage: status.symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.13), in: Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(Fmt.range(week)): \(status.title)")
            }
        }
    }
}

private struct IssuesCard: View {
    let issues: [WorkdayIssue]
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(issue.severity == .warning ? .orange : .secondary)
                    Text(issue.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if issues.contains(where: { $0.severity == .warning }) {
                Button("Open Workday setup", action: openSetup)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }
}

/// Progress and results from the Workday API.
struct SyncMessage: View {
    @Environment(WorkdaySync.self) private var sync

    var body: some View {
        switch sync.phase {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(cornerRadius: 12)
        case .succeeded(let text):
            outcome(text, details: [], failed: false)
        case .failed(let text, let details):
            outcome(text, details: details, failed: true)
        }
    }

    private func outcome(_ text: String, details: [String], failed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(text, systemImage: failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { sync.dismissMessage() }
                    .buttonStyle(.link)
            }
            ForEach(details, id: \.self) { detail in
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 12)
    }
}

private struct WorkdayIntro: View {
    let setUp: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.tint)
                VStack(spacing: 6) {
                    Text("Get your hours into Workday")
                        .font(.title2.weight(.semibold))
                    Text("Match your clients and activities to Workday's time entry codes and projects once. Allotment then lays out each week the way Workday wants it.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                }
                HStack(alignment: .top, spacing: 14) {
                    option("tablecells", "Workday-ready timesheet",
                           "Each week grouped by time entry code and project, rounded to Workday's increments, with one-click copy and a tick-off for submitted weeks.")
                    option("square.and.arrow.up", "Import sheet for admins",
                           "Export hours-only time blocks in the column order of Workday's Import Reported Time Blocks, for an admin to load.")
                    option("paperplane", "Direct sync",
                           "Send time blocks straight to Workday through its API, once your Workday admin registers an API client for Allotment.")
                }
                .frame(maxWidth: 820)
                Button("Set up Workday", action: setUp)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .fadeUnderBars()
    }

    private func option(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }
}
