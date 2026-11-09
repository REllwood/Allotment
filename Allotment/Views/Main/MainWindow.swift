import SwiftUI

struct MainWindow: View {
    @Environment(Router.self) private var router
    @Environment(TimeStore.self) private var store
    @State private var dialogs = DialogPresenter()

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            List(selection: Binding<SidebarItem?>(
                get: { router.selection },
                set: { if let item = $0 { router.selection = item } }
            )) {
                Section("Track") {
                    sidebarRow(.overview)
                    sidebarRow(.timesheet)
                    sidebarRow(.calendar)
                    sidebarRow(.workday)
                }
                Section("Insights") {
                    sidebarRow(.reports)
                    sidebarRow(.forecast)
                }
                Section("Manage") {
                    sidebarRow(.clients)
                    sidebarRow(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaBar(edge: .bottom) {
                SidebarTimer()
                    .padding(10)
            }
        } detail: {
            detail
                // No toolbar band with a hard bottom line. Each page fades its own content out under the toolbar
                // instead, with fadeUnderBars(), because the system's soft scroll edge does not draw here.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .defaultScrollAnchor(LaunchOptions.previewScrollAnchor)
        .appDialogHost(dialogs)
        .environment(dialogs)
        .frame(minWidth: 960, minHeight: 620)
        .sheet(item: $router.editing) { target in
            EntryEditor(target: target)
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            #if DEBUG
            if LaunchOptions.previewDialog?.hasPrefix("entry") == true, let entry = store.entries.last(where: { !$0.isRunning }) {
                router.editing = EntryEditTarget(entryID: entry.id, day: entry.start)
            }
            if LaunchOptions.previewDialog == "window", let client = store.clients.first {
                dialogs.present(AppDialog(
                    symbol: "trash.fill", tone: .destructive,
                    title: "Delete \(client.name)?",
                    message: "This cannot be undone.",
                    actions: [AppDialog.Action(title: "Delete client and \(store.entries(for: client.id).count) entries", isDestructive: true) {},
                              AppDialog.Action(title: "Archive instead") {}]
                ))
            }
            #endif
        }
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selection {
        case .overview: OverviewView()
        case .timesheet: TimesheetView()
        case .calendar: CalendarImportView()
        case .workday: WorkdayView()
        case .reports: ReportsView()
        case .forecast: ForecastView()
        case .clients: ClientsView()
        case .settings: SettingsView()
        }
    }
}

/// The running timer, pinned to the bottom of the sidebar.
private struct SidebarTimer: View {
    @Environment(TimeStore.self) private var store
    @Environment(Ticker.self) private var ticker

    var body: some View {
        if let running = store.runningEntry {
            let color = store.color(for: running.clientID)
            HStack(spacing: 10) {
                PulsingDot(color: color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.title(for: running))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(Fmt.clock(running.duration(at: ticker.now), showSeconds: true))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { store.stopTimer() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .help("Stop the timer")
            }
            .padding(10)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let last = store.recentWork(limit: 1).first {
            HStack(spacing: 10) {
                ClientDot(color: store.color(for: last.clientID))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Not tracking")
                        .font(.callout.weight(.medium))
                    Text("Last: \(store.title(for: last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { store.resume(last) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.glass)
                .help("Resume \(store.title(for: last))")
            }
            .padding(10)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
