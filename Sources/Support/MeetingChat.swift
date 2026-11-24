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
        guard !body.isEmpty, description.trimmingCharacters(in: .whitespacesAndNewlines) == body + "," else { return nil }
        return MeetingChatMessage(clock: "", author: previous?.author ?? "Автор не указан", body: body)
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
    static func snapshot() -> [MeetingChatMessage]? {
        guard AXIsProcessTrusted() else { return nil }
        for id in MeetingAX.zoomIDs {
            for process in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                let app = AXUIElementCreateApplication(process.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.15)
                for window in MeetingAX.children(app, "AXWindows") {
                    let title = MeetingAX.text(window, "AXTitle").lowercased()
                    guard MeetingAX.text(window, "AXIdentifier") == "zm.meeting.window.main" ||
                            ["zoom meeting", "конференция zoom", "meeting chat", "чат конференции"].contains(title) else { continue }
                    if let messages = snapshot(window) { return messages }
                }
            }
        }
        return nil
    }

    private static func snapshot(_ window: AXUIElement) -> [MeetingChatMessage]? {
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
        let rows = visibleRows.isEmpty ? MeetingAX.children(table) : visibleRows
        var messages = [MeetingChatMessage]()
        var previous: MeetingChatMessage?
        for row in rows {
            guard let cell = MeetingAX.children(row).first(where: { MeetingAX.text($0, "AXIdentifier") == "ZMTextMessageCellView" }) else {
                previous = nil
                continue
            }
            previous = readCell(cell, after: previous)
            if let previous { messages.append(previous) }
        }
        return publicTab(controls[0]) ? messages : nil
    }
}
