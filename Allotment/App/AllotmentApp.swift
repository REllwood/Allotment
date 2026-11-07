import SwiftUI

@main
struct AllotmentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: TimeStore
    @State private var ticker = Ticker()
    @State private var calendar = CalendarService()
    @State private var router: Router
    @State private var workdaySync = WorkdaySync(secrets: LaunchOptions.usesMemoryOnly ? MemorySecretStore() : KeychainSecretStore())

    init() {
        let store = TimeStore(fileURL: LaunchOptions.usesMemoryOnly ? nil : TimeStore.defaultFileURL)
        if LaunchOptions.isDemo {
            store.loadSampleData()
            if LaunchOptions.startsIdle { store.stopTimer() }
        }
        _store = State(initialValue: store)
        let router = Router()
        if let section = LaunchOptions.section { router.selection = section }
        _router = State(initialValue: router)
        AppDelegate.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
                .environment(ticker)
                .environment(calendar)
                .environment(router)
                .environment(workdaySync)
        } label: {
            MenuBarLabel(store: store, ticker: ticker)
        }
        .menuBarExtraStyle(.window)

        Window("Allotment", id: AppWindow.main) {
            MainWindow()
                .environment(store)
                .environment(ticker)
                .environment(calendar)
                .environment(router)
                .environment(workdaySync)
        }
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)
        // Menu bar apps do not open windows at launch on their own. `MenuBarLabel` opens this one when needed.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            AllotmentCommands(store: store, router: router)
        }

        // The menu bar panel in an ordinary window, for checking its layout. Only opens with `--preview-panel`.
        Window("Menu Bar Preview", id: "panel-preview") {
            MenuBarPanel()
                .environment(store)
                .environment(ticker)
                .environment(calendar)
                .environment(router)
                .environment(workdaySync)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
    }
}

/// Command line switches, mainly for trying the app out and taking screenshots.
enum LaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    /// Runs on sample data held in memory, leaving your saved data untouched.
    static var isDemo: Bool { arguments.contains("--demo") }

    /// True when the app is hosting unit tests. The host shares the real app's container,
    /// so without this it would load your saved data and write it back when the tests finish.
    static var isHostingTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains { environment[$0] != nil }
    }

    /// Keeps data and secrets in memory, never touching the saved file or the Keychain.
    static var usesMemoryOnly: Bool { isDemo || isHostingTests }
    static var showsMainWindow: Bool { arguments.contains("--show-window") }
    static var previewsPanel: Bool { arguments.contains("--preview-panel") }
    /// With `--demo`, stops the sample timer so the panel shows its idle state.
    static var startsIdle: Bool { arguments.contains("--idle") }
    /// Opens Workday setup straight away, with `--section workday`.
    static var opensWorkdaySetup: Bool { arguments.contains("--workday-setup") }

    /// `--section reports` opens the main window on that page.
    static var section: SidebarItem? {
        guard let index = arguments.firstIndex(of: "--section"), index + 1 < arguments.count else { return nil }
        return SidebarItem(rawValue: arguments[index + 1])
    }
}

struct MenuBarLabel: View {
    let store: TimeStore
    let ticker: Ticker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            .task {
                // The label is the one view that exists at launch, so it opens any windows needed on first run.
                if store.clients.isEmpty || LaunchOptions.showsMainWindow {
                    openWindow(id: AppWindow.main)
                }
                if LaunchOptions.previewsPanel {
                    openWindow(id: "panel-preview")
                }
            }
    }

    @ViewBuilder
    private var label: some View {
        if let running = store.runningEntry {
            let elapsed = running.duration(at: ticker.now)
            let icon = Image(nsImage: MenuBarIcon.tracking(elapsed: elapsed))
            if store.settings.showTimerInMenuBar {
                Text("\(icon) \(Fmt.clock(elapsed))")
                    .monospacedDigit()
            } else {
                icon
            }
        } else {
            Image(nsImage: MenuBarIcon.idle)
        }
    }
}

struct AllotmentCommands: Commands {
    let store: TimeStore
    let router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Time Entry") {
                show(.timesheet)
                router.editing = EntryEditTarget(entryID: nil, day: router.timesheetDate)
            }
            .keyboardShortcut("n")
            Button(store.runningEntry == nil ? "Resume Last Timer" : "Stop Timer") {
                if store.runningEntry != nil {
                    store.stopTimer()
                } else if let last = store.recentWork(limit: 1).first {
                    store.resume(last)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { show(.settings) }
                .keyboardShortcut(",")
        }
        CommandMenu("Go") {
            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { show(item) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }

    private func show(_ item: SidebarItem) {
        router.selection = item
        openWindow(id: AppWindow.main)
        NSApp.activate()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var store: TimeStore?
    private var idleMonitor: IdleMonitor?
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let store = Self.store {
            idleMonitor = IdleMonitor(store: store)
            idleMonitor?.start()
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // The closing window is still visible during this notification, so check on the next turn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppWindow.updateActivationPolicy() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.store?.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
