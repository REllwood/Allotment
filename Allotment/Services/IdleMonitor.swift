import AppKit
import CoreGraphics

/// Notices when you step away with a timer running, and asks what to do with that time when you return.
@MainActor
final class IdleMonitor {
    private let store: TimeStore
    private var idleStart: Date?
    private var sleptAt: Date?
    private var isPrompting = false
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(store: TimeStore) {
        self.store = store
    }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.poll()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleptAt = .now }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
    }

    private var threshold: TimeInterval { TimeInterval(store.settings.idleThresholdMinutes * 60) }

    private func poll() {
        guard threshold > 0, let running = store.runningEntry else {
            idleStart = nil
            return
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= threshold {
            if idleStart == nil { idleStart = max(running.start, Date.now.addingTimeInterval(-idle)) }
        } else if let start = idleStart {
            idleStart = nil
            prompt(idleFrom: start, until: Date.now.addingTimeInterval(-idle))
        }
    }

    private func handleWake() {
        defer { sleptAt = nil }
        guard threshold > 0, let slept = sleptAt, let running = store.runningEntry,
              Date.now.timeIntervalSince(slept) >= threshold else { return }
        idleStart = nil
        prompt(idleFrom: max(slept, running.start), until: .now)
    }

    private func prompt(idleFrom start: Date, until end: Date) {
        guard !isPrompting, let running = store.runningEntry, end > start else { return }
        isPrompting = true
        defer { isPrompting = false }

        let name = store.client(running.clientID)?.name ?? "your timer"
        let alert = NSAlert()
        alert.messageText = "You were away for \(Fmt.hm(end.timeIntervalSince(start)))"
        alert.informativeText = "The timer for \(name) kept running from \(Fmt.time(start)) to \(Fmt.time(end)). What should happen to that time?"
        alert.addButton(withTitle: "Keep the time")
        alert.addButton(withTitle: "Remove the idle time")
        alert.addButton(withTitle: "Stop the timer at \(Fmt.time(start))")
        alert.alertStyle = .informational
        NSApp.activate()

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            // Split the timer around the gap, so the work after you came back is still tracked.
            store.stopTimer(at: start)
            store.startTimer(clientID: running.clientID, projectID: running.projectID, activityID: running.activityID,
                             notes: running.notes, at: end)
        case .alertThirdButtonReturn:
            store.stopTimer(at: start)
        default:
            break
        }
    }
}
