import Foundation
import Security

enum WorkdayError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidEndpoint(String)
    case missingSecret(String)
    case http(status: Int, message: String)
    case invalidTemplate(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): "Workday is not set up yet: \(what)."
        case .invalidEndpoint(let text): "That does not look like a Workday address: \(text)"
        case .missingSecret(let what): "The \(what) is missing. Add it in Workday setup."
        case let .http(status, message):
            switch status {
            case 401: "Workday did not accept the sign-in (401). Sign in again or check the client secret. \(message)"
            case 403: "Workday refused access (403). The API client may be missing the Time Tracking scope. \(message)"
            case 404: "Workday could not find that address (404). Check the paths in Workday setup. \(message)"
            default: "Workday answered with an error (\(status)). \(message)"
            }
        case .invalidTemplate(let detail): "The time block template is not valid JSON: \(detail)"
        case .invalidResponse: "Workday sent a reply Allotment could not read."
        }
    }
}

/// The parts of a Workday REST endpoint such as https://wd2-impl-services1.workday.com/ccx/api/v1/acme
struct WorkdayEndpoint: Equatable, Sendable {
    let base: URL
    let tenant: String

    init(restEndpoint: String) throws {
        let text = restEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme, scheme == "https", let host = url.host() else {
            throw WorkdayError.invalidEndpoint(text.isEmpty ? "nothing entered" : text)
        }
        let parts = url.path().split(separator: "/").map(String.init)
        guard let tenant = parts.last, parts.contains("ccx"), tenant != "ccx", tenant != "api" else {
            throw WorkdayError.invalidEndpoint(text)
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        base = components.url ?? url
        self.tenant = tenant
    }

    /// Builds https://host/ccx/api/<path>, filling in {tenant} and {worker}.
    func url(for pathTemplate: String, worker: String = "") throws -> URL {
        let path = pathTemplate
            .replacingOccurrences(of: "{tenant}", with: tenant)
            .replacingOccurrences(of: "{worker}", with: worker)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "ccx/api/\(path)", relativeTo: base)?.absoluteURL else {
            throw WorkdayError.invalidEndpoint(pathTemplate)
        }
        return url
    }
}

/// Fills the time block JSON template. Placeholders: {{date}}, {{dateTime}}, {{hours}}, {{timeCode}}, {{project}},
/// {{task}}, {{comment}}, {{worker}} and {{employeeID}}. A value that is exactly "{{hours}}" becomes a number, and
/// anything left empty is removed, so a block with no project simply has no project field.
enum WorkdayTemplate {
    static func render(_ template: String, values: [String: String], hours: Double) throws -> Data {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(template.utf8))
        } catch {
            throw WorkdayError.invalidTemplate(error.localizedDescription)
        }
        guard let filled = fill(parsed, values: values, hours: hours) as? [String: Any] else {
            throw WorkdayError.invalidTemplate("the template must be a JSON object")
        }
        return try JSONSerialization.data(withJSONObject: filled, options: [.sortedKeys])
    }

    private static func fill(_ node: Any, values: [String: String], hours: Double) -> Any? {
        switch node {
        case let text as String:
            if text == "{{hours}}" { return hours }
            var result = text
            for (key, value) in values {
                result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
            return result.isEmpty ? nil : result
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, value) in object {
                if let filled = fill(value, values: values, hours: hours) { result[key] = filled }
            }
            return result.isEmpty ? nil : result
        case let array as [Any]:
            let result = array.compactMap { fill($0, values: values, hours: hours) }
            return result.isEmpty ? nil : result
        default:
            return node
        }
    }
}

/// Talks to the Workday REST API. Requests are built by small functions so they can be checked in tests.
struct WorkdayClient {
    let config: WorkdayAPIConfig
    let secrets: any SecretStore
    var session: URLSession = .shared

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
    }

    struct Worker: Equatable {
        let id: String
        let name: String
    }

    // MARK: - Requests

    func tokenRequest(form: [String: String]) throws -> URLRequest {
        guard let url = URL(string: config.tokenEndpoint.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else {
            throw WorkdayError.invalidEndpoint(config.tokenEndpoint)
        }
        guard let secret = secrets.value(for: .clientSecret), !secret.isEmpty else { throw WorkdayError.missingSecret("client secret") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let basic = Data("\(config.clientID):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)
        return request
    }

    func authorizationURL(state: String) throws -> URL {
        guard var components = URLComponents(string: config.authorizationEndpoint.trimmingCharacters(in: .whitespaces)),
              components.scheme == "https" else {
            throw WorkdayError.invalidEndpoint(config.authorizationEndpoint)
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: WorkdayAPIConfig.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw WorkdayError.invalidEndpoint(config.authorizationEndpoint) }
        return url
    }

    func timeBlockRequest(line: WorkdayLine, day: Date, worker: String, employeeID: String, accessToken: String) throws -> URLRequest {
        let endpoint = try WorkdayEndpoint(restEndpoint: config.restEndpoint)
        let hours = line.hours[day] ?? 0
        let values = [
            "date": Fmt.isoDay(day),
            "dateTime": Self.localDateTime(day),
            // A plain number, never localised, because commas would break the request.
            "hours": String(format: "%.2f", hours),
            "timeCode": line.timeCode,
            "project": line.project,
            "task": line.task,
            "comment": line.comments[day] ?? "",
            "worker": worker,
            "employeeID": employeeID,
        ]
        var request = URLRequest(url: try endpoint.url(for: config.timeBlockPath, worker: worker))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try WorkdayTemplate.render(config.bodyTemplate, values: values, hours: hours)
        return request
    }

    // MARK: - Calls

    /// Swaps the refresh token for an access token. Saves a new refresh token if Workday rotates it.
    func accessToken() async throws -> String {
        guard let refresh = secrets.value(for: .refreshToken), !refresh.isEmpty else {
            throw WorkdayError.missingSecret("refresh token (sign in with Workday or paste one)")
        }
        let response: TokenResponse = try await decode(try tokenRequest(form: ["grant_type": "refresh_token", "refresh_token": refresh]))
        if let rotated = response.refresh_token, !rotated.isEmpty, rotated != refresh {
            secrets.set(rotated, for: .refreshToken)
        }
        return response.access_token
    }

    /// Finishes "Sign in with Workday" by trading the code for tokens.
    func exchange(code: String) async throws {
        let response: TokenResponse = try await decode(try tokenRequest(form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": WorkdayAPIConfig.redirectURI,
        ]))
        guard let refresh = response.refresh_token, !refresh.isEmpty else {
            throw WorkdayError.missingSecret("refresh token. Ask your Workday admin to allow refresh tokens for this API client")
        }
        secrets.set(refresh, for: .refreshToken)
    }

    func currentWorker(accessToken: String) async throws -> Worker {
        let endpoint = try WorkdayEndpoint(restEndpoint: config.restEndpoint)
        var request = URLRequest(url: try endpoint.url(for: config.workerPath))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkdayError.invalidResponse }
        // Single resources come back as an object, collections as {"data": [...]}.
        let object = (json["data"] as? [[String: Any]])?.first ?? json
        guard let id = object["id"] as? String else { throw WorkdayError.invalidResponse }
        let name = object["descriptor"] as? String ?? object["name"] as? String ?? ""
        return Worker(id: id, name: name)
    }

    func postTimeBlock(_ request: URLRequest) async throws {
        _ = try await send(request)
    }

    // MARK: - Plumbing

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WorkdayError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkdayError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkdayError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    /// Workday errors look like {"error": "...", "errors": [{"error": "...", "field": "..."}]}.
    static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(300), as: UTF8.self)
        }
        var parts: [String] = []
        if let main = json["error"] as? String { parts.append(main) }
        if let description = json["error_description"] as? String { parts.append(description) }
        if let details = json["errors"] as? [[String: Any]] {
            parts += details.compactMap { detail in
                guard let message = detail["error"] as? String else { return nil }
                return (detail["field"] as? String).map { "\($0): \(message)" } ?? message
            }
        }
        return parts.joined(separator: " ")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    /// Local midnight with its offset, such as 2026-11-02T00:00:00+11:00.
    static func localDateTime(_ day: Date) -> String {
        day.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }
}

// MARK: - Secrets

enum SecretKey: String, CaseIterable {
    case clientSecret = "workday.client-secret"
    case refreshToken = "workday.refresh-token"
}

protocol SecretStore {
    func value(for key: SecretKey) -> String?
    func set(_ value: String?, for key: SecretKey)
    /// Whether a secret is saved, without reading it.
    func contains(_ key: SecretKey) -> Bool
}

extension SecretStore {
    func contains(_ key: SecretKey) -> Bool {
        value(for: key)?.isEmpty == false
    }
}

/// Stores Workday secrets in the login Keychain.
struct KeychainSecretStore: SecretStore {
    /// Matches the bundle identifier, which keeps the app's original name so saved data and permissions carry over.
    private let service = "com.rhysellwood.TimeTraka"

    private func query(_ key: SecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key.rawValue]
    }

    /// Asks only for the item's attributes, so checking whether a secret exists never unlocks it.
    func contains(_ key: SecretKey) -> Bool {
        var request = query(key)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }

    func value(for key: SecretKey) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: SecretKey) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Allotment Workday \(key == .clientSecret ? "client secret" : "refresh token")"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Keeps secrets in memory, for demo mode and tests.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [SecretKey: String] = [:]
    private let lock = NSLock()

    func value(for key: SecretKey) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String?, for key: SecretKey) {
        lock.withLock { values[key] = value }
    }
}
