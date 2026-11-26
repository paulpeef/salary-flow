import AppKit
import CryptoKit
import Network

// A desktop OAuth client is supplied by the account owner. Credentials and the
// short-lived access token stay in memory. The callback listens only on loopback.
@MainActor final class MeetSignIn {
    struct Client: Decodable {
        struct Installed: Decodable { let client_id: String; let client_secret: String? }
        let installed: Installed
    }
    private var listener: NWListener?
    private var waiting: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    private var redirect = ""
    private let state = UUID().uuidString
    private let verifier = UUID().uuidString + UUID().uuidString

    private func finish(_ result: Result<String, Error>) {
        listener?.cancel()
        listener = nil
        timer?.cancel()
        timer = nil
        waiting?.resume(with: result)
        waiting = nil
    }

    func cancel() { finish(.failure(MeetingIssue("Вход отменён."))) }

    private func receive(_ connection: NWConnection, previous: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, closed, error in
            Task { @MainActor in
                let request = previous + (data ?? Data())
                guard error == nil, request.count <= 16384 else { connection.cancel(); return }
                guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if closed { connection.cancel() } else { self.receive(connection, previous: request) }
                    return
                }
                let fields = text.prefix(while: { !$0.isNewline }).split(separator: " ")
                let url = fields.count == 3 ? URLComponents(string: String(fields[1])) : nil
                let valid = fields.first == "GET" && url?.path == "/callback" &&
                    url?.queryItems?.first(where: { $0.name == "state" })?.value == self.state
                let code = url?.queryItems?.first(where: { $0.name == "code" })?.value
                let status = valid ? "200 OK" : "400 Bad Request"
                let body = valid ? "You can return to Salary Flow." : "Invalid callback."
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if valid {
                    if let code, !code.isEmpty { self.finish(.success(code)) } else { self.cancel() }
                }
            }
        }
    }

    func token(credentials: Data) async throws -> String {
        let client = try JSONDecoder().decode(Client.self, from: credentials).installed
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let code: String = try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            server.newConnectionHandler = { connection in
                Task { @MainActor in
                    connection.start(queue: .main)
                    self.receive(connection)
                }
            }
            server.stateUpdateHandler = { status in
                Task { @MainActor in
                    guard self.waiting != nil else { return }
                    if case .failed(let error) = status { self.finish(.failure(error)) }
                    if case .ready = status, let port = server.port {
                        self.redirect = "http://127.0.0.1:\(port.rawValue)/callback"
                        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                        url.queryItems = ["client_id": client.client_id, "response_type": "code", "redirect_uri": self.redirect,
                            "scope": "https://www.googleapis.com/auth/meetings.space.readonly",
                            "state": self.state, "code_challenge": challenge, "code_challenge_method": "S256"]
                            .map { URLQueryItem(name: $0.key, value: $0.value) }
                        guard let link = url.url, NSWorkspace.shared.open(link) else {
                            self.finish(.failure(MeetingIssue("Не удалось открыть браузер для входа в Google."))); return
                        }
                    }
                }
            }
            timer = Task { try? await Task.sleep(nanoseconds: 180_000_000_000); if !Task.isCancelled { cancel() } }
            server.start(queue: .main)
        }
        var form = URLComponents()
        var values = ["client_id": client.client_id, "code": code, "redirect_uri": redirect,
                      "grant_type": "authorization_code", "code_verifier": verifier]
        values["client_secret"] = client.client_secret
        form.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        struct Token: Decodable { let access_token: String }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MeetingIssue("Google отклонил вход. Проверь OAuth-клиент типа Desktop app.") }
        return try JSONDecoder().decode(Token.self, from: data).access_token
    }
}

struct GoogleMeetAPI {
    let token: String
    var session = URLSession(configuration: .ephemeral)
    struct Record: Decodable, Identifiable { let name, startTime: String; let endTime: String?; var id: String { name } }
    struct Transcript: Decodable { let name, state: String }
    struct Participant: Decodable {
        struct Person: Decodable { let displayName: String? }
        let name: String
        let signedinUser, anonymousUser, phoneUser: Person?
        var display: String? { (signedinUser ?? anonymousUser ?? phoneUser)?.displayName }
    }
    struct Entry: Decodable { let name, participant, startTime, text: String }

    private func list<T: Decodable>(_ path: String, key: String, filter: String? = nil) async throws -> [T] {
        var result = [T](), seen = Set<String>(), next: String?
        repeat {
            var url = URLComponents(string: "https://meet.googleapis.com")!
            url.path = "/v2/" + path
            url.queryItems = [("filter", filter), ("pageToken", next), ("pageSize", "100")].compactMap { name, value in
                value.map { URLQueryItem(name: name, value: $0) }
            }
            var request = URLRequest(url: url.url!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw MeetingIssue(status == 401 ? "Срок входа истёк. Подключи Google снова." :
                    "Google Meet вернул HTTP \(status). Проверь доступ к этой встрече и включение Meet REST API.")
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            if let rows = object[key] {
                result += try JSONDecoder().decode([T].self, from: JSONSerialization.data(withJSONObject: rows))
            }
            next = object["nextPageToken"] as? String
            if let token = next, !token.isEmpty, !seen.insert(token).inserted { throw MeetingIssue("Google вернул повторную страницу.") }
        } while next?.isEmpty == false
        return result
    }

    static func meetingCode(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code: String
        if let url = URL(string: text), url.host == "meet.google.com" { code = url.lastPathComponent }
        else { code = text }
        return code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) == nil ? nil : code
    }
    func records(_ input: String) async throws -> [Record] {
        guard let code = Self.meetingCode(input) else { throw MeetingIssue("Введи ссылку meet.google.com или код встречи.") }
        let records: [Record] = try await list("conferenceRecords", key: "conferenceRecords", filter: "space.meeting_code = \"\(code)\"")
        return records.filter { $0.endTime != nil }.sorted { $0.startTime > $1.startTime }
    }

    static func date(_ text: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime]
        guard let d = iso.date(from: text) else { throw CocoaError(.fileReadCorruptFile) }
        return d
    }

    static func render(_ entries: [Entry], people: [Participant], start: Date) throws -> String {
        var names = [String: String](), seen = Set<String>()
        for person in people {
            if let display = person.display, !display.isEmpty { names[person.name] = display.components(separatedBy: .newlines).joined(separator: " ") }
        }
        let ordered = try entries.map { (try date($0.startTime), $0) }.sorted { $0.0 < $1.0 }
        var rows = [String](), unknown = 0
        for (time, entry) in ordered where seen.insert(entry.name).inserted {
            let text = entry.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            if names[entry.participant] == nil { unknown += 1; names[entry.participant] = "Участник \(unknown)" }
            let sec = max(0, Int(time.timeIntervalSince(start)))
            rows.append(String(format: "[%02d:%02d:%02d] ", sec/3600, sec/60%60, sec%60) + names[entry.participant]! + " — " + text)
        }
        guard !rows.isEmpty else { throw MeetingIssue("В расшифровке Google Meet пока нет реплик.") }
        return rows.joined(separator: "\n")
    }

    func transcript(_ record: Record) async throws -> String {
        let sessions: [Transcript] = try await list(record.name + "/transcripts", key: "transcripts")
        guard !sessions.isEmpty else { throw MeetingIssue("У этой встречи нет штатной расшифровки Google Meet.") }
        guard sessions.allSatisfy({ $0.state == "FILE_GENERATED" }) else { throw MeetingIssue("Google ещё готовит расшифровку. Повтори после обработки.") }
        let people: [Participant] = try await list(record.name + "/participants", key: "participants")
        var entries = [Entry]()
        for transcript in sessions {
            let page: [Entry] = try await list(transcript.name + "/entries", key: "transcriptEntries")
            entries += page
        }
        return try Self.render(entries, people: people, start: Self.date(record.startTime))
    }
}
