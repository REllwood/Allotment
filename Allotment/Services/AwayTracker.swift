import Foundation

/// A stretch of time away from the Mac while a timer kept running.
struct AwayPeriod: Equatable, Sendable {
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Decides when to ask about time spent away from the Mac while a timer runs. It is a pure state machine:
/// `IdleMonitor` feeds it events from the system and shows the prompt it asks for, so every rule here can be
/// tested without a Mac going to sleep.
///
///     present ──input idle for the threshold──▶ away(since)
///     present ──Mac sleeps──▶ asleep(since: sleep time)
///     away ──Mac sleeps──▶ asleep(since: when you left)
///     away ──input resumes──▶ asking   (asks about since → when input resumed)
///     asleep ──wakes after at least the threshold──▶ asking   (asks about since → wake)
///     asleep ──wakes sooner──▶ present
///     asking ──answered──▶ present
///
/// While asking, nothing else changes the state, so a second absence cannot replace the question on screen.
/// With no timer running, or the threshold turned off, the tracker goes back to present.
struct AwayTracker: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case present
        case away(since: Date)
        case asleep(since: Date)
        case asking(AwayPeriod)
    }

    enum Event: Sendable {
        /// The system's seconds since the last keyboard or mouse input, sampled at `at`.
        case inputIdle(seconds: TimeInterval, at: Date)
        case willSleep(at: Date)
        case didWake(at: Date)
        /// The prompt was answered or dismissed.
        case answered
    }

    /// What the tracker needs to know about the app when an event arrives.
    struct Context: Sendable {
        /// Seconds of no input that count as being away. 0 turns the feature off.
        var threshold: TimeInterval
        /// Start of the running timer, or nil when no timer runs.
        var timerStart: Date?
    }

    private(set) var state: State = .present

    /// Moves to the next state. Returns the period to ask about when the move means asking.
    mutating func handle(_ event: Event, context: Context) -> AwayPeriod? {
        if case .asking = state {
            if case .answered = event { state = .present }
            return nil
        }
        guard context.threshold > 0, let timerStart = context.timerStart else {
            state = .present
            return nil
        }

        switch (state, event) {
        case (.present, .inputIdle(let seconds, let at)) where seconds >= context.threshold:
            state = .away(since: max(timerStart, at.addingTimeInterval(-seconds)))

        case (.away(let since), .inputIdle(let seconds, let at)) where seconds < context.threshold:
            return ask(AwayPeriod(start: max(since, timerStart), end: at.addingTimeInterval(-seconds)))

        case (.present, .willSleep(let at)):
            state = .asleep(since: max(timerStart, at))

        case (.away(let since), .willSleep):
            // Keep the moment you left, not the moment the Mac went to sleep.
            state = .asleep(since: since)

        case (.asleep(let since), .didWake(let at)):
            if at.timeIntervalSince(since) >= context.threshold {
                return ask(AwayPeriod(start: max(since, timerStart), end: at))
            }
            state = .present

        default:
            // Input while present, more idle while away, a second sleep, polls while asleep,
            // a wake that was never preceded by sleep, and answers with nothing asked: no change.
            break
        }
        return nil
    }

    /// Periods start no earlier than the running timer, so a timer started after you came back is left alone.
    private mutating func ask(_ period: AwayPeriod) -> AwayPeriod? {
        guard period.end > period.start else {
            state = .present
            return nil
        }
        state = .asking(period)
        return period
    }
}
