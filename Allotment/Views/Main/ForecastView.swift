import Charts
import SwiftUI

/// Allocation against actual time for each client, with a projection to the end of the period.
struct ForecastView: View {
    enum PeriodChoice: String, CaseIterable, Identifiable {
        case own = "Each client's period"
        case week = "This week"
        case month = "This month"
        var id: Self { self }

        var period: AllocationPeriod? {
            switch self {
            case .own: nil
            case .week: .week
            case .month: .month
            }
        }
    }

    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router
    @State private var choice: PeriodChoice = .own
    @State private var historyClientID: UUID?

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 14)]

    var body: some View {
        let now = Date.now
        let engine = ForecastEngine(store: store)
        let allocated = store.activeClients.filter { $0.allocationHours != nil }
        let unallocated = store.activeClients.filter { $0.allocationHours == nil }
        let forecasts = engine.forecasts(for: allocated, period: choice.period, at: now)
        let capacity = engine.capacity(for: allocated)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CapacityCard(capacity: capacity, forecasts: forecasts)

                if allocated.isEmpty {
                    EmptyStateView(symbol: "gauge.with.dots.needle.33percent", title: "No allocations yet",
                                   message: "Set how many hours a week or month each client gets in Clients. The forecast then shows whether you are heading over or under.")
                        .frame(height: 260)
                } else {
                    ForecastLegend()
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(forecasts) { forecast in
                            ForecastCard(forecast: forecast)
                                .onTapGesture { historyClientID = forecast.client.id }
                        }
                    }
                    HistoryCard(clients: allocated, selection: $historyClientID, engine: engine)
                }

                if !unallocated.isEmpty {
                    UnallocatedCard(clients: unallocated, now: now)
                }
            }
            .padding(24)
        }
        .fadeUnderBars()
        .navigationTitle("Forecast")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Period", selection: $choice) {
                    ForEach(PeriodChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

private struct CapacityCard: View {
    let capacity: CapacitySummary
    let forecasts: [ClientForecast]

    var body: some View {
        let over = forecasts.filter { $0.status == .over || $0.status == .trendingOver }
        let under = forecasts.filter { $0.status == .under || $0.status == .trendingUnder }

        HStack(alignment: .center, spacing: 24) {
            Gauge(value: min(capacity.fraction, 1.5), in: 0...1.5) {
                Text("Booked")
            } currentValueLabel: {
                Text(Fmt.percent(capacity.fraction))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(capacity.isOverbooked ? .orange : .green)
            .scaleEffect(1.4)
            .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: 4) {
                Text(capacity.isOverbooked ? "You are overbooked" : "Weekly capacity")
                    .font(.title3.weight(.semibold))
                Text(capacity.isOverbooked
                     ? "Client allocations add up to \(Fmt.hours(capacity.weeklyAllocated)) a week, \(Fmt.hours(-capacity.free)) more than your \(Fmt.hours(capacity.weeklyCapacity))."
                     : "Client allocations add up to \(Fmt.hours(capacity.weeklyAllocated)) of your \(Fmt.hours(capacity.weeklyCapacity)) a week, leaving \(Fmt.hours(capacity.free)) for admin and new work.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 22) {
                summary(count: over.count, title: "heading over", color: over.contains { $0.status == .over } ? .red : .orange, symbol: "arrow.up.right")
                summary(count: under.count, title: "heading under", color: .blue, symbol: "arrow.down.right")
                summary(count: forecasts.count - over.count - under.count, title: "on track", color: .green, symbol: "checkmark")
            }
        }
        .padding(20)
        .cardBackground()
    }

    private func summary(count: Int, title: String, color: Color, symbol: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption.weight(.bold))
                Text("\(count)").font(.title2.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(count > 0 ? color : .secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ForecastCard: View {
    let forecast: ClientForecast

    var body: some View {
        let color = Color(hex: forecast.client.colorHex)
        let allocation = forecast.allocation ?? 0

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ClientDot(color: color, size: 11)
                Text(forecast.client.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusPill(status: forecast.status)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.hours(forecast.actual))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("of \(Fmt.hours(allocation))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.range(forecast.period))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProjectionBar(forecast: forecast, color: color)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    metric("Should be at", forecast.expectedToDate.map(Fmt.hours) ?? "–")
                    metric("Projected", Fmt.hours(forecast.projected),
                           color: forecast.status == .over || forecast.status == .trendingOver ? forecast.status.color : nil)
                    metric(forecast.isComplete ? "Final variance" : "Projected variance",
                           forecast.projectedVariance.map { ($0 > 0 ? "+" : "−") + Fmt.hours(abs($0)) } ?? "–")
                }
            }

            Text(advice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .cardBackground()
        .contentShape(Rectangle())
    }

    private var advice: String {
        let allocation = forecast.allocation ?? 0
        if forecast.isComplete {
            return forecast.actual > allocation
                ? "Finished \(Fmt.hours(forecast.actual - allocation)) over the allocation."
                : "Finished \(Fmt.hours(allocation - forecast.actual)) under the allocation."
        }
        switch forecast.status {
        case .over:
            return "Already \(Fmt.hours(forecast.actual - allocation)) over. Consider pausing work or agreeing extra hours."
        case .trendingOver:
            if forecast.actual >= allocation {
                return "Already \(Fmt.hours(forecast.actual - allocation)) past the allocation, and heading for \(Fmt.hours(forecast.projected)) at this pace."
            }
            return "At this pace you will finish around \(Fmt.hours(forecast.projected)). Only \(Fmt.hours(allocation - forecast.actual)) left in the allocation."
        case .trendingUnder:
            if let perDay = forecast.neededPerDay {
                return "Behind plan. About \(Fmt.hours(perDay)) a day for the rest of the period would hit the allocation."
            }
            return "Behind plan for this period."
        case .onTrack:
            if let perDay = forecast.neededPerDay {
                return "On pace. Roughly \(Fmt.hours(perDay)) a day keeps you on target."
            }
            return "On pace."
        case .under, .unallocated:
            return ""
        }
    }

    private func metric(_ title: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(color ?? .primary)
        }
    }
}

/// Logged time as a solid bar and the projection as a faded extension. Hours past the allocation turn the over colour,
/// a dark line marks the allocation and a notch marks where you should be by now.
private struct ProjectionBar: View {
    let forecast: ClientForecast
    let color: Color

    var body: some View {
        let allocation = forecast.allocation ?? 0
        let scale = max(allocation, forecast.projected, forecast.actual) * 1.06
        let over = forecast.status.overrunColor
        GeometryReader { proxy in
            let width = proxy.size.width
            let x: (Double) -> CGFloat = { scale > 0 ? width * $0 / scale : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.07))
                if forecast.projected > allocation {
                    Capsule()
                        .fill(over.opacity(0.3))
                        .frame(width: max(10, x(forecast.projected)))
                }
                Capsule()
                    .fill(color.opacity(0.3))
                    .frame(width: max(10, x(min(forecast.projected, allocation))))
                if forecast.actual > allocation {
                    Capsule()
                        .fill(over.gradient)
                        .frame(width: max(10, x(forecast.actual)))
                }
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(10, x(min(forecast.actual, allocation))))
                Capsule()
                    .fill(.primary)
                    .frame(width: 2.5, height: 22)
                    .offset(x: x(allocation) - 1.25)
                if let expected = forecast.expectedToDate, !forecast.isComplete, expected > 0 {
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 2, height: 16)
                        .offset(x: x(expected) - 1)
                }
            }
        }
        .frame(height: 12)
        .padding(.vertical, 5)
    }
}

/// How to read the bars, shown once above the cards.
private struct ForecastLegend: View {
    var body: some View {
        HStack(spacing: 18) {
            item { Capsule().fill(Color.accentColor.gradient).frame(width: 18, height: 8) } label: { "Logged" }
            item { Capsule().fill(Color.accentColor.opacity(0.3)).frame(width: 18, height: 8) } label: { "Projected" }
            item { Capsule().fill(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)).frame(width: 18, height: 8) } label: { "Past the allocation" }
            item { Capsule().fill(.primary).frame(width: 2.5, height: 14) } label: { "Allocation" }
            item { Capsule().fill(.primary.opacity(0.55)).frame(width: 2, height: 11) } label: { "Where you should be by now" }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(@ViewBuilder _ swatch: () -> some View, label: () -> String) -> some View {
        HStack(spacing: 6) {
            swatch()
            Text(label())
        }
    }
}

private struct HistoryCard: View {
    let clients: [Client]
    @Binding var selection: UUID?
    let engine: ForecastEngine

    var body: some View {
        let client = clients.first { $0.id == selection } ?? clients.first
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Picker("Client", selection: Binding(get: { client?.id }, set: { selection = $0 })) {
                    ForEach(clients) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let client {
                let periods = engine.history(for: client, period: client.allocationPeriod,
                                             count: client.allocationPeriod == .week ? 10 : 6)
                Chart {
                    ForEach(periods) { period in
                        BarMark(x: .value("Period", period.period.start, unit: client.allocationPeriod == .week ? .weekOfYear : .month),
                                y: .value("Hours", period.actual))
                            .foregroundStyle(barColor(period, client: client))
                            .cornerRadius(4)
                            .annotation(position: .top) {
                                Text(Fmt.hours(period.actual))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    if let allocation = client.allocationHours {
                        RuleMark(y: .value("Allocation", allocation))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .foregroundStyle(.primary.opacity(0.6))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Allocation \(Fmt.hours(allocation))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: periods.map(\.period.start)) { _ in
                        AxisValueLabel(format: client.allocationPeriod == .week ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 220)
                Text(summary(periods, client: client))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .cardBackground()
    }

    private func barColor(_ period: PeriodActual, client: Client) -> Color {
        guard let allocation = period.allocation, allocation > 0 else { return Color(hex: client.colorHex) }
        let tolerance = engine.tolerance
        if period.actual > allocation * (1 + tolerance) { return .red.opacity(0.85) }
        return Color(hex: client.colorHex)
    }

    private func summary(_ periods: [PeriodActual], client: Client) -> String {
        let completed = periods.dropLast()
        guard let allocation = client.allocationHours, !completed.isEmpty else { return "" }
        let average = completed.reduce(0) { $0 + $1.actual } / Double(completed.count)
        let overCount = completed.filter { $0.actual > allocation * (1 + engine.tolerance) }.count
        let noun = client.allocationPeriod == .week ? "weeks" : "months"
        return "Over the last \(completed.count) \(noun) you averaged \(Fmt.hours(average)) against \(Fmt.hours(allocation)), and went over in \(overCount) of them."
    }
}

private struct UnallocatedCard: View {
    let clients: [Client]
    let now: Date
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let week = store.schedule.week(containing: now)
        let month = store.schedule.month(containing: now)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clients without an allocation")
                    .font(.headline)
                Spacer()
                Button("Set allocations") { router.selection = .clients }
                    .buttonStyle(.link)
            }
            ForEach(clients) { client in
                HStack {
                    ClientDot(color: Color(hex: client.colorHex))
                    Text(client.name)
                    Spacer()
                    Text("\(Fmt.hours(store.hours(clientID: client.id, in: week, now: now))) this week")
                        .foregroundStyle(.secondary)
                    Text("\(Fmt.hours(store.hours(clientID: client.id, in: month, now: now))) this month")
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                }
                .monospacedDigit()
            }
        }
        .padding(18)
        .cardBackground()
    }
}
