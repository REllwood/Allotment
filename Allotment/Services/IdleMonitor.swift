import AppKit
import CoreGraphics

/// Connects `AwayTracker` to the Mac: it samples keyboard and mouse idle time, listens for sleep and wake,
/// and shows the prompt the tracker asks for. The rules about when to ask live in `AwayTracker`.
@MainActor
final class IdleMonitor {
    private let store: TimeStore
    private var tracker = AwayTracker()
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(store: TimeStore) {
        self.store = store
    }

    /// Where the tracker stands, for the debug state report.
    var state: AwayTracker.State { tracker.state }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.poll()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.willSleep(at: .now)) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.didWake(at: .now)) }
        })
    }

    private func poll() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        handle(.inputIdle(seconds: idle, at: .now))
    }

    private func handle(_ event: AwayTracker.Event) {
        let context = AwayTracker.Context(
            threshold: TimeInterval(store.settings.idleThresholdMinutes * 60),
            timerStart: store.runningEntry?.start
        )
        if let period = tracker.handle(event, context: context) {
            ask(about: period)
        }
    }

    /// Asks in a floating dialog, because no Allotment window may be open when you come back.
    private func ask(about period: AwayPeriod) {
        guard let running = store.runningEntry else {
            handle(.answered)
            return
        }
        let name = store.client(running.clientID)?.name ?? "your timer"
        FloatingDialog.present(AppDialog(
            symbol: "cup.and.saucer.fill",
            title: "You were away for \(Fmt.hm(period.duration))",
            message: "The timer for \(name) kept running from \(Fmt.time(period.start)) to \(Fmt.time(period.end)). What should happen to that time?",
            actions: [
                AppDialog.Action(title: "Remove the idle time") { [weak self] in
                    self?.resolve(running) { store in
                        // Split the timer around the gap, so the work after you came back is still tracked.
                        store.stopTimer(at: period.start)
                        store.startTimer(clientID: running.clientID, projectID: running.projectID, activityID: running.activityID,
                                         notes: running.notes, at: period.end)
                    }
                },
                AppDialog.Action(title: "Stop the timer at \(Fmt.time(period.start))") { [weak self] in
                    self?.resolve(running) { $0.stopTimer(at: period.start) }
                },
            ],
            cancelTitle: "Keep the time",
            onCancel: { [weak self] in self?.handle(.answered) }
        ))
    }

    /// Applies a choice from the away prompt, as long as the timer it asked about is still the one running.
    private func resolve(_ running: TimeEntry, _ change: (TimeStore) -> Void) {
        handle(.answered)
        guard store.runningEntry?.id == running.id else { return }
        change(store)
    }

    #if DEBUG
    /// Shows the away prompt as if you had just come back from 25 minutes away, for checking how it looks.
    func previewPrompt() {
        ask(about: AwayPeriod(start: Date.now.addingTimeInterval(-25 * 60), end: .now))
    }
    #endif
}
