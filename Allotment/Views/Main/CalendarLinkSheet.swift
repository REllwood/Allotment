import SwiftUI

/// Adds a calendar from a link, such as a published Outlook calendar or a Google calendar's secret address.
/// The link is downloaded and read before it is saved, so a wrong link is caught here.
struct CalendarLinkSheet: View {
    @Environment(TimeStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var phase = Phase.editing
    @FocusState private var linkFocused: Bool

    /// Where adding stands.
    ///
    ///     editing ──Add──▶ checking ──the link works──▶ the sheet closes
    ///     checking ──the link does not work──▶ failed ──you change the link──▶ editing
    enum Phase: Equatable {
        case editing
        case checking
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Link", text: $address, prompt: Text("https://…/calendar.ics"))
                    .focused($linkFocused)
                    .onChange(of: address) { if case .failed = phase { phase = .editing } }
                TextField("Name", text: $name, prompt: Text("Optional, such as Work"))
            } header: {
                Text("Calendar link")
            } footer: {
                Group {
                    if case .failed(let reason) = phase {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Anyone with this link can see the calendar, so Allotment keeps it in your Keychain. It downloads the calendar every 15 minutes and never changes it.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Steps(lines: [
                    "In Outlook on the web, open Settings, then Calendar, then Shared calendars.",
                    "Under Publish a calendar, choose your calendar and Can view all details, then choose Publish.",
                    "Copy the ICS link and paste it above.",
                ])
            } header: {
                Text("Outlook and Teams meetings")
            } footer: {
                Text("If Publish is missing, or only offers free and busy times, your organisation has limited publishing. Ask your IT team.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Google Calendar") {
                Steps(lines: [
                    "In Google Calendar on the web, open Settings.",
                    "Under Settings for my calendars, choose the calendar.",
                    "Copy Secret address in iCal format and paste it above.",
                ])
            }
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(LaunchOptions.previewScrollAnchor)
        .disabled(phase == .checking)
        // The form fades out where it meets the buttons.
        .sheetButtonBar {
            HStack(spacing: 10) {
                if phase == .checking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking the link…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .checking)
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .onAppear { linkFocused = true }
    }

    private func add() {
        phase = .checking
        Task {
            do {
                let (url, file) = try await calendar.links.check(address, against: store.settings.calendarLinks)
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let link = CalendarLink(
                    name: trimmed.isEmpty ? (file.name ?? CalendarLinkAddress.suggestedName(for: url)) : trimmed,
                    colorHex: Palette.next(after: store.settings.calendarLinks.map(\.colorHex))
                )
                try calendar.links.add(link, url: url, file: file)
                store.settings.calendarLinks.append(link)
                dismiss()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// Numbered steps, read out in order by VoiceOver.
private struct Steps: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 2)
    }
}
