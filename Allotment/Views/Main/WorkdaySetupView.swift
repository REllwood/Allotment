import AuthenticationServices
import SwiftUI

/// Maps Allotment's activities, clients and projects to Workday, and sets up the optional API connection.
struct WorkdaySetupView: View {
    @Environment(TimeStore.self) private var store
    @Environment(WorkdaySync.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var clientSecret = ""
    @State private var refreshToken = ""
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Use Workday", isOn: $store.workday.isEnabled)
                    TextField("Employee ID", text: $store.workday.employeeID, prompt: Text("Used in import sheets, such as 21004"))
                    TextField("Default time entry code", text: $store.workday.defaultTimeCode, prompt: Text("Such as Regular_Hours"))
                    Picker("Round each day to", selection: $store.workday.incrementHours) {
                        ForEach(WorkdayConfig.increments, id: \.hours) { Text($0.title).tag($0.hours) }
                    }
                    Picker("Comment on each day", selection: $store.workday.commentStyle) {
                        ForEach(WorkdayCommentStyle.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Basics")
                } footer: {
                    Text("Use the reference IDs your Workday tenant shows for time entry codes and projects. Ask your Workday admin if you are not sure which to use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(store.activities) { activity in
                        LabeledContent {
                            TextField("Code", text: activityCode(activity.id), prompt: Text(store.workday.defaultTimeCode.isEmpty ? "Time entry code" : store.workday.defaultTimeCode))
                                .labelsHidden()
                                .frame(width: 240)
                        } label: {
                            Label(activity.name, systemImage: activity.symbol)
                        }
                    }
                } header: {
                    Text("Activities and time entry codes")
                } footer: {
                    Text("Leave a code empty to use the default. For example, Admin might go to Internal_Admin and everything else to Regular_Hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(store.activeClients) { client in
                        LabeledContent {
                            TextField("Project", text: clientProject(client.id), prompt: Text("Workday project"))
                                .labelsHidden()
                                .frame(width: 240)
                        } label: {
                            HStack(spacing: 8) {
                                ClientDot(color: Color(hex: client.colorHex))
                                Text(client.name).fontWeight(.medium)
                            }
                        }
                        ForEach(store.projects(for: client.id)) { project in
                            LabeledContent {
                                HStack(spacing: 6) {
                                    TextField("Project", text: projectCode(project.id, \.project), prompt: Text("Same as client"))
                                        .labelsHidden()
                                    TextField("Task", text: projectCode(project.id, \.task), prompt: Text("Task or phase"))
                                        .labelsHidden()
                                }
                                .frame(width: 240)
                            } label: {
                                Text(project.name)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 18)
                            }
                        }
                    }
                } header: {
                    Text("Clients, projects and Workday projects")
                } footer: {
                    Text("An Allotment project can point at its own Workday project and task, otherwise its client's Workday project is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                connectionSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Changes are saved as you type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding(16)
        }
        .frame(width: 700, height: 580)
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        @Bindable var store = store
        Section {
            TextField("REST API endpoint", text: $store.workday.api.restEndpoint,
                      prompt: Text("https://wd2-impl-services1.workday.com/ccx/api/v1/tenant"))
            TextField("Token endpoint", text: $store.workday.api.tokenEndpoint,
                      prompt: Text("https://wd2-impl-services1.workday.com/ccx/oauth2/tenant/token"))
            TextField("Authorization endpoint", text: $store.workday.api.authorizationEndpoint,
                      prompt: Text("https://wd2-impl.workday.com/tenant/authorize"))
            TextField("Client ID", text: $store.workday.api.clientID)
            secretRow("Client secret", key: .clientSecret, text: $clientSecret)
            secretRow("Refresh token", key: .refreshToken, text: $refreshToken)

            HStack {
                Button("Sign in with Workday") {
                    Task {
                        await sync.signIn(store: store) { url in
                            try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: WorkdayAPIConfig.callbackScheme,
                                                                            preferredBrowserSession: .ephemeral)
                        }
                    }
                }
                .disabled(sync.isWorking || store.workday.api.authorizationEndpoint.isEmpty || !store.workday.api.isConfigured
                          || !sync.hasSecret(.clientSecret))
                Button("Test connection") {
                    Task { await sync.testConnection(store: store) }
                }
                .disabled(sync.isWorking || !store.workday.api.isConfigured)
                Spacer()
                if sync.hasSecret(.refreshToken) {
                    Button("Sign out", role: .destructive) { sync.forgetSignIn(store: store) }
                        .buttonStyle(.link)
                }
            }
            if !store.workday.api.workerID.isEmpty {
                LabeledContent("Signed in as", value: store.workday.api.workerName.isEmpty ? store.workday.api.workerID : store.workday.api.workerName)
            }
            SyncMessage()

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Worker ID", text: $store.workday.api.workerID, prompt: Text("Found by Test connection"))
                    TextField("Worker lookup path", text: $store.workday.api.workerPath)
                        .font(.callout.monospaced())
                    TextField("Time block path", text: $store.workday.api.timeBlockPath)
                        .font(.callout.monospaced())
                    Text("Time block JSON")
                        .font(.callout)
                    TextEditor(text: $store.workday.api.bodyTemplate)
                        .font(.callout.monospaced())
                        .frame(height: 150)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    Text("Paths go after /ccx/api/ and can use {tenant} and {worker}. The JSON can use {{date}}, {{dateTime}}, {{hours}}, {{timeCode}}, {{project}}, {{task}}, {{comment}}, {{worker}} and {{employeeID}}. Empty values are left out. Workday's REST API reference for your tenant lists the exact resource and fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset paths and JSON to the defaults") {
                        store.workday.api.workerPath = WorkdayAPIConfig.defaultWorkerPath
                        store.workday.api.timeBlockPath = WorkdayAPIConfig.defaultTimeBlockPath
                        store.workday.api.bodyTemplate = WorkdayAPIConfig.defaultBodyTemplate
                    }
                }
                .padding(.top, 6)
            }
        } header: {
            Text("Direct sync (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("What to ask your Workday admin: register an API client for Allotment with the Authorization Code grant, redirect URI \(WorkdayAPIConfig.redirectURI), the Time Tracking and Staffing scopes, and refresh tokens turned on. They give you the client ID, client secret and the three endpoints shown on the client's page. Alternatively they can issue a refresh token for you to paste.")
                Text("Secrets are kept in your Mac's Keychain. Allotment only connects to Workday when you test the connection or send time.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
    }

    private func secretRow(_ title: String, key: SecretKey, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                SecureField(title, text: text, prompt: Text(sync.hasSecret(key) ? "Saved in Keychain" : "Not set"))
                    .labelsHidden()
                    .onSubmit { save(text, key: key) }
                Button("Save") { save(text, key: key) }
                    .disabled(text.wrappedValue.isEmpty)
            }
            .frame(width: 330)
        }
    }

    private func save(_ text: Binding<String>, key: SecretKey) {
        guard !text.wrappedValue.isEmpty else { return }
        sync.saveSecret(text.wrappedValue, for: key)
        text.wrappedValue = ""
    }

    // MARK: - Mapping bindings

    private func activityCode(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.workday.activityCodes[id.uuidString] ?? "" },
            set: { store.workday.activityCodes[id.uuidString] = $0.isEmpty ? nil : $0 }
        )
    }

    private func clientProject(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.workday.clientProjects[id.uuidString] ?? "" },
            set: { store.workday.clientProjects[id.uuidString] = $0.isEmpty ? nil : $0 }
        )
    }

    private func projectCode(_ id: UUID, _ field: WritableKeyPath<WorkdayProjectCode, String>) -> Binding<String> {
        Binding(
            get: { store.workday.projectCodes[id.uuidString]?[keyPath: field] ?? "" },
            set: { value in
                var code = store.workday.projectCodes[id.uuidString] ?? WorkdayProjectCode()
                code[keyPath: field] = value
                store.workday.projectCodes[id.uuidString] = code.project.isEmpty && code.task.isEmpty ? nil : code
            }
        )
    }
}
