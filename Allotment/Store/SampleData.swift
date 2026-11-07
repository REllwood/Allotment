import Foundation

/// A few weeks of realistic time for trying Allotment out. The same data comes back every time.
enum SampleData {
    static func make(now: Date = .now, settings: AppSettings = AppSettings()) -> AppData {
        var data = AppData()
        data.settings = settings
        if data.settings.defaultHourlyRate == 0 { data.settings.defaultHourlyRate = 80 }

        let acme = Client(name: "Acme Studio", colorHex: Palette.colors[3], hourlyRate: 85, allocationHours: 16, allocationPeriod: .week,
                          matchKeywords: ["acme", "acmestudio.com"])
        let northwind = Client(name: "Northwind Retail", colorHex: Palette.colors[2], hourlyRate: 95, allocationHours: 50, allocationPeriod: .month,
                               matchKeywords: ["northwind"])
        let globex = Client(name: "Globex Health", colorHex: Palette.colors[4], hourlyRate: 110, allocationHours: 8, allocationPeriod: .week,
                            matchKeywords: ["globex"])
        let brightside = Client(name: "Brightside Trust", colorHex: Palette.colors[1], hourlyRate: 60)
        data.clients = [acme, northwind, globex, brightside]

        let projects = [
            Project(clientID: acme.id, name: "Website redesign", budgetHours: 120),
            Project(clientID: acme.id, name: "Brand refresh", budgetHours: 40),
            Project(clientID: northwind.id, name: "Checkout rebuild", budgetHours: 200),
            Project(clientID: northwind.id, name: "Support retainer"),
            Project(clientID: globex.id, name: "Patient portal", budgetHours: 60),
            Project(clientID: brightside.id, name: "Donations page", budgetHours: 20),
        ]
        data.projects = projects

        var rng = SeededGenerator(seed: 42)
        let schedule = WorkSchedule(settings: data.settings)
        let calendar = schedule.calendar
        let firstDay = calendar.date(byAdding: .day, value: -27, to: calendar.startOfDay(for: now)) ?? now
        let researchID = data.activities.first { $0.name == "Research" }?.id
        let emailID = data.activities.first { $0.name == "Email and comms" }?.id

        // Weights tilt Acme over its allocation so the forecast has something to show.
        let picks: [(Client?, Double)] = [(acme, 0.40), (northwind, 0.28), (globex, 0.14), (brightside, 0.06), (nil, 0.12)]
        let notesByClient: [UUID: [String]] = [
            acme.id: ["Homepage hero layout", "Component library", "Design review", "Navigation tweaks", "Content migration"],
            northwind.id: ["Payment flow", "Basket API", "Bug triage", "Release prep", "Performance pass"],
            globex.id: ["Appointment booking", "Accessibility fixes", "Stakeholder demo"],
            brightside.id: ["Gift Aid form", "Copy updates"],
        ]

        // Stop generating 47 minutes ago so a running timer can fill the gap up to now.
        let limit = now.addingTimeInterval(-47 * 60)
        for day in schedule.days(in: DateInterval(start: firstDay, end: max(firstDay, limit))) where schedule.isWorkday(day) {
            var cursor = day.addingTimeInterval(TimeInterval(data.settings.workdayStartMinutes * 60 + Int.random(in: 0...20, using: &rng) * 60))
            let dayEnd = day.addingTimeInterval(TimeInterval(data.settings.workdayEndMinutes * 60))
            while cursor < dayEnd {
                let minutes = Double([30, 45, 60, 75, 90, 120, 150].randomElement(using: &rng) ?? 60)
                var end = min(cursor.addingTimeInterval(minutes * 60), dayEnd)
                if end > limit { end = limit }
                guard end.timeIntervalSince(cursor) > 300 else { break }

                let client = weightedPick(picks, using: &rng)
                var entry = TimeEntry(start: cursor, end: end, isBillable: false, source: .timer)
                if let client {
                    let clientProjects = projects.filter { $0.clientID == client.id }
                    entry.clientID = client.id
                    entry.projectID = clientProjects.randomElement(using: &rng)?.id
                    let roll = Double.random(in: 0..<1, using: &rng)
                    entry.activityID = roll < 0.65 ? Activity.clientWorkID : roll < 0.85 ? Activity.meetingID : roll < 0.93 ? researchID : Activity.adminID
                    entry.notes = notesByClient[client.id]?.randomElement(using: &rng) ?? ""
                    entry.isBillable = entry.activityID != Activity.adminID
                } else {
                    entry.activityID = Bool.random(using: &rng) ? Activity.adminID : emailID
                    entry.notes = ["Invoicing", "Inbox zero", "Planning the week", "Bookkeeping"].randomElement(using: &rng) ?? ""
                }
                entry.source = Double.random(in: 0..<1, using: &rng) < 0.2 ? .manual : .timer
                data.entries.append(entry)

                if end >= limit { break }
                cursor = end.addingTimeInterval(Double(Int.random(in: 0...3, using: &rng) * 5 * 60))
            }
        }

        // Leave a timer running so the menu bar shows live tracking.
        if schedule.isWorkday(now) {
            let lastEnd = data.entries.last?.end ?? limit
            data.entries.append(TimeEntry(clientID: acme.id, projectID: projects[0].id, activityID: Activity.clientWorkID,
                                          notes: "Homepage hero layout", start: max(lastEnd, limit),
                                          end: nil, isBillable: true, source: .timer))
        }
        return data
    }

    /// Example Workday codes for the sample clients, keeping any connection details already set up.
    static func workday(for data: AppData, keeping existing: WorkdayConfig) -> WorkdayConfig {
        var config = WorkdayConfig()
        config.api = existing.api
        config.isEnabled = true
        config.employeeID = existing.employeeID.isEmpty ? "21004" : existing.employeeID
        config.defaultTimeCode = "Regular_Hours"
        config.activityCodes[Activity.adminID.uuidString] = "Internal_Admin"
        if let email = data.activities.first(where: { $0.name == "Email and comms" }) {
            config.activityCodes[email.id.uuidString] = "Internal_Admin"
        }
        if let travel = data.activities.first(where: { $0.name == "Travel" }) {
            config.activityCodes[travel.id.uuidString] = "Travel_Time"
        }
        let codes = ["Acme Studio": "PRJ-1042", "Northwind Retail": "PRJ-0987", "Globex Health": "PRJ-1110"]
        for client in data.clients {
            if let code = codes[client.name] { config.clientProjects[client.id.uuidString] = code }
        }
        for project in data.projects where project.name == "Website redesign" {
            config.projectCodes[project.id.uuidString] = WorkdayProjectCode(project: "PRJ-1042", task: "Build")
        }
        return config
    }

    private static func weightedPick(_ items: [(Client?, Double)], using rng: inout SeededGenerator) -> Client? {
        let roll = Double.random(in: 0..<1, using: &rng)
        var running = 0.0
        for (client, weight) in items {
            running += weight
            if roll < running { return client }
        }
        return items.last?.0
    }
}

/// SplitMix64, so sample data is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension TimeStore {
    func loadSampleData() {
        var sample = SampleData.make(settings: settings)
        sample.workday = SampleData.workday(for: sample, keeping: workday)
        replaceAll(with: sample)
    }
}
