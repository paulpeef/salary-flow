import AppKit

struct MeetingChatMessage: Codable, Hashable {
    let clock, author, body: String
}

enum MeetingChat {
    // The cell's AX description contains author, complete multiline body, and
    // Zoom's send time. Expanded threads can append a reply count after the time.
    private static let cellPattern = try! NSRegularExpression(
        pattern: #"(?s)^([^,\n]+),\s+(.+),\s+((?:[01]?\d|2[0-3]):[0-5]\d(?:\s*[AP]M)?)(?:,\s*\d+ (?:repl(?:y|ies)|ответ[^,]*)(?:, [^\n,]+)?)?$"#,
        options: [.caseInsensitive])

    static func message(_ description: String) -> MeetingChatMessage? {
        // Zoom inserts the historical date between body and clock in persistent chats.
        if description.range(of: #",\s+(?:\d{1,2}\s+\p{L}{3,}\.?|\p{L}{3,}\.?\s+\d{1,2}),\s+\d{1,2}:\d{2}(?:\s*[AP]M)?(?:,\s*\d+ (?:repl|ответ).*)?$"#,
                             options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let string = description as NSString
        guard let match = cellPattern.firstMatch(in: description, range: NSRange(location: 0, length: string.length)) else { return nil }
        func field(_ i: Int) -> String { string.substring(with: match.range(at: i)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let author = field(1), body = field(2)
        guard !author.isEmpty, !body.isEmpty else { return nil }
        return MeetingChatMessage(clock: field(3), author: author, body: body)
    }

    // Zoom sometimes omits the repeated sender and time in consecutive rows.
    // Verify the description against the body element before accepting one.
    static func continuation(_ description: String, body: String, after previous: MeetingChatMessage?) -> MeetingChatMessage? {
        guard let previous, !body.isEmpty, description.trimmingCharacters(in: .whitespacesAndNewlines) == body + "," else { return nil }
        return MeetingChatMessage(clock: "", author: previous.author, body: body)
    }

    // Only a system cell may establish a session boundary. Zoom prefixes
    // earlier dates before the clock in historical meeting-start prompts.
    static func sessionBoundary(_ prompt: String) -> Bool? {
        let parts = prompt.lowercased().components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }
        if parts[1].hasPrefix("meeting ended") || parts[1].hasPrefix("конференция завершена") { return false }
        guard ["meeting started", "конференция началась", "конференция начата"].contains(parts[1]) else { return nil }
        return minuteOfDay(parts[0]) != nil
    }

    private static func minuteOfDay(_ clock: String) -> Int? {
        let compact = clock.uppercased().filter { !$0.isWhitespace }
        let meridiem = compact.hasSuffix("PM") || compact.hasSuffix("AM")
        let time = meridiem ? String(compact.dropLast(2)) : compact
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<60).contains(minute) else { return nil }
        if meridiem {
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + (compact.hasSuffix("PM") ? 12 : 0)) * 60 + minute
        }
        return (0..<24).contains(hour) ? hour * 60 + minute : nil
    }

    static func inRecording(_ clock: String, from start: Date, to end: Date, calendar: Calendar = .current) -> Bool {
        guard let minute = minuteOfDay(clock), start <= end else { return false }
        let floor = calendar.dateInterval(of: .minute, for: start)?.start ?? start
        let match = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        guard let date = calendar.nextDate(after: floor.addingTimeInterval(-1), matching: match,
                                           matchingPolicy: .strict) else { return false }
        return date <= end
    }

    static func load(_ directory: URL) throws -> [MeetingChatMessage] {
        let url = directory.appending(path: "chat.json")
        if !FileManager.default.fileExists(atPath: url.path) { return [] }
        return try JSONDecoder().decode([MeetingChatMessage].self, from: Data(contentsOf: url))
    }

    static func merged(_ saved: [MeetingChatMessage], _ snapshot: [MeetingChatMessage]) -> [MeetingChatMessage] {
        // Anchor older rows discovered by scrolling before the next known row.
        // Occurrence counts preserve identical messages shown twice in a minute.
        var offsets: [MeetingChatMessage: [Int]] = [:]
        for (i, message) in saved.enumerated() { offsets[message, default: []].append(i) }
        var occurrences: [MeetingChatMessage: Int] = [:], pending = [MeetingChatMessage]()
        var before: [Int: [MeetingChatMessage]] = [:]
        for message in snapshot {
            let n = occurrences[message, default: 0]
            occurrences[message] = n + 1
            if let matches = offsets[message], n < matches.count {
                if !pending.isEmpty {
                    before[matches[n], default: []] += pending
                    pending.removeAll(keepingCapacity: true)
                }
            } else { pending.append(message) }
        }
        if before.isEmpty { return saved + pending }
        var result = [MeetingChatMessage]()
        for (i, message) in saved.enumerated() {
            result += before[i] ?? []
            result.append(message)
        }
        return result + pending
    }

    static func section(_ messages: [MeetingChatMessage]) -> String {
        guard !messages.isEmpty else { return "" }
        let lines = messages.map { ($0.clock.isEmpty ? "" : "[\($0.clock)] ") + "\($0.author) — \($0.body)" }
        return "\n\nЧат встречи\n" + lines.joined(separator: "\n")
    }

    private static func labels(_ node: AXUIElement) -> [String] {
        [MeetingAX.text(node, "AXTitle"), MeetingAX.text(node, "AXDescription"), MeetingAX.text(node, "AXValue"), MeetingAX.text(node, "AXRoleDescription")]
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func everyoneTab(_ labels: [String], selected: Bool?) -> Bool {
        let fields = labels.flatMap { $0.lowercased().components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let isPublic = ["everyone", "все", "всем"].contains { fields.contains($0) || fields.contains("tab " + $0) || fields.contains("вкладка " + $0) }
        return isPublic && (selected ?? fields.contains(where: { ["selected", "выбрано", "выбрана", "выбран"].contains($0) }))
    }

    private static func publicTab(_ control: AXUIElement) -> Bool {
        let selected = MeetingAX.children(control, "AXSelectedChildren")
        // Zoom reserves the first tab for Everyone. A private tab can have
        // an arbitrary display name, including the localized public label.
        guard let tab = MeetingAX.children(control).first else { return false }
        let flag = (MeetingAX.value(tab, "AXSelected") as? NSNumber)?.boolValue ??
                   (MeetingAX.value(tab, "AXValue") as? NSNumber)?.boolValue
        let state = selected.isEmpty ? flag : selected.contains(where: { CFEqual($0, tab) })
        var names = labels(tab)
        // Some versions put the tab name in a nested static text.
        for child in MeetingAX.children(tab) {
            names += labels(child)
            for leaf in MeetingAX.children(child) { names += labels(leaf) }
        }
        return everyoneTab(names, selected: state)
    }

    private static func readCell(_ cell: AXUIElement, after previous: MeetingChatMessage?) -> MeetingChatMessage? {
        let description = MeetingAX.text(cell, "AXDescription")
        let children = MeetingAX.children(cell)
        let grouped = { children.lazy.compactMap { continuation(description, body: MeetingAX.text($0, "AXDescription"), after: previous) }.first }
        guard let message = message(description) ?? grouped() else { return nil }
        // Only follow links inside the message body. Sender profile links are
        // separate siblings of that element in Zoom's accessibility tree.
        var nodes = children.filter { MeetingAX.text($0, "AXDescription") == message.body }
        var links = [String](), i = 0
        while i < nodes.count && i < 150 {
            let node = nodes[i]
            i += 1
            if MeetingAX.text(node, "AXRole") == "AXLink" {
                let raw = MeetingAX.value(node, "AXURL")
                let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
                if let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                   !message.body.contains(url.absoluteString), !links.contains(url.absoluteString) { links.append(url.absoluteString) }
            } else { nodes += MeetingAX.children(node) }
        }
        return MeetingChatMessage(clock: message.clock, author: message.author, body: ([message.body] + links).joined(separator: "\n"))
    }

    // A nil snapshot means the public conversation could not be verified.
    static func snapshot(recordingStart: Date) -> [MeetingChatMessage]? {
        guard AXIsProcessTrusted() else { return nil }
        for id in MeetingAX.zoomIDs {
            for process in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                let app = AXUIElementCreateApplication(process.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.15)
                for window in MeetingAX.children(app, "AXWindows") {
                    let title = MeetingAX.text(window, "AXTitle").lowercased()
                    guard MeetingAX.text(window, "AXIdentifier") == "zm.meeting.window.main" ||
                            ["zoom meeting", "конференция zoom", "meeting chat", "чат конференции"].contains(title) else { continue }
                    if let messages = snapshot(window, recordingStart: recordingStart) { return messages }
                }
            }
        }
        return nil
    }

    private static func snapshot(_ window: AXUIElement, recordingStart: Date) -> [MeetingChatMessage]? {
        var queue = [window], index = 0, controls = [AXUIElement](), tables = [AXUIElement]()
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        while index < queue.count && index < 300 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let node = queue[index]
            index += 1
            let role = MeetingAX.text(node, "AXRole")
            if ["AXTextField", "AXTextArea", "AXWebArea", "AXButton", "AXRow", "AXMenu", "AXStaticText"].contains(role) { continue }
            let names = labels(node)
            if names.contains(where: { $0.hasPrefix("meeting chat tab control") || $0.hasPrefix("вкладки чата конференции") }) {
                controls.append(node)
            } else if role == "AXTable" {
                if names.contains(where: { $0.hasPrefix("chat list") || $0.hasPrefix("список сообщений") || $0.hasPrefix("список чата") }) { tables.append(node) }
            } else { queue.append(contentsOf: MeetingAX.children(node)) }
        }
        guard index == queue.count, controls.count == 1, tables.count == 1, publicTab(controls[0]) else { return nil }
        let table = tables[0]
        let visibleRows = MeetingAX.children(table, "AXVisibleRows")
        let allRows = MeetingAX.children(table, "AXRows")
        let rows = allRows.isEmpty ? (visibleRows.isEmpty ? MeetingAX.children(table) : visibleRows) : allRows
        let visible = Set(visibleRows)
        var messages = [MeetingChatMessage]()
        var previous: MeetingChatMessage?
        let now = Date()
        var first = rows.startIndex
        var currentSession: Bool?
        // Start at the newest row so scrolling up to a different call cannot
        // make its start prompt the current boundary.
        for i in rows.indices.reversed() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let prompt = MeetingAX.children(rows[i]).first(where: { MeetingAX.text($0, "AXIdentifier") == "ZMPromptMessageCellView" }),
               let boundary = sessionBoundary(MeetingAX.text(prompt, "AXDescription")) {
                first = i + 1
                if !boundary || !allRows.isEmpty { currentSession = boundary }
                break
            }
        }
        for row in rows[first...] where visible.isEmpty || visible.contains(row) {
            let cells = MeetingAX.children(row)
            guard currentSession != false,
                  let cell = cells.first(where: { MeetingAX.text($0, "AXIdentifier") == "ZMTextMessageCellView" }),
                  let message = readCell(cell, after: previous),
                  currentSession == true || message.clock.isEmpty || inRecording(message.clock, from: recordingStart, to: now)
            else { previous = nil; continue }
            previous = message
            messages.append(message)
        }
        return publicTab(controls[0]) ? messages : nil
    }
}
