import AppKit
import ApplicationServices

struct MeetingIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum MeetingAX {
    static func value(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, key as CFString, &result) == .success else { return nil }
        return result
    }

    static func children(_ item: AXUIElement, _ key: String = "AXChildren") -> [AXUIElement] {
        value(item, key) as? [AXUIElement] ?? []
    }

    static func text(_ item: AXUIElement, _ key: String) -> String {
        value(item, key) as? String ?? ""
    }

    static func element(_ item: AXUIElement, _ key: String) -> AXUIElement? {
        guard let raw = value(item, key), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func permission() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    enum CommandResult { case sent, opposite }
    // Run outside the main thread. AXPress on a status item can run a nested
    // menu tracking loop in the target app until the chosen item is pressed.
    static func record(_ start: Bool, pid: pid_t) throws -> CommandResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.8)
        guard let extras = element(app, "AXExtrasMenuBar"), let icon = children(extras).first else {
            throw MeetingIssue("Включи значок Spokenly в строке меню и разреши Salary Flow универсальный доступ.")
        }
        func items() -> [AXUIElement] {
            let menus = children(icon) + children(app).filter { text($0, "AXRole") == "AXMenu" }
            return menus.flatMap { menu in
                text(menu, "AXRole") == "AXMenuItem" ? [menu] : children(menu)
            }
        }
        func matches(_ title: String, start: Bool) -> Bool {
            let s = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let titles = start ? ["record meeting", "record a meeting", "start meeting recording", "записать встречу"] :
                                  ["stop meeting recording", "остановить запись встречи"]
            return titles.contains { s == $0 || s.hasPrefix($0 + " (") || s == $0 + "…" }
        }
        if items().isEmpty {
            DispatchQueue.global().async { AXUIElementPerformAction(icon, kAXPressAction as CFString) }
        }
        for attempt in 0..<25 {
            let menu = items()
            if let target = menu.first(where: { matches(text($0, "AXTitle"), start: start) }) {
                let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
                guard result == .success || result == .cannotComplete else {
                    throw MeetingIssue("Spokenly не принял команду записи (AX \(result.rawValue)).")
                }
                return .sent
            }
            if menu.contains(where: { matches(text($0, "AXTitle"), start: !start) }) {
                for menu in children(icon) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
                return .opposite
            }
            if attempt == 8, menu.isEmpty {
                DispatchQueue.global().async { AXUIElementPerformAction(icon, kAXShowMenuAction as CFString) }
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        for menu in children(icon) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        throw MeetingIssue("Не найден пункт записи встречи в меню Spokenly. Открой Spokenly и проверь его значок в строке меню.")
    }

    static let zoomIDs = ["us.zoom.ZoomMeeting", "us.zoom.xos"]

    static func speakerName(_ label: String) -> String? {
        for prefix in ["Talking:", "Speaking:", "Говорит:", "Active speaker:", "Активный докладчик:"] {
            guard label.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let name = label.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.count <= 100, !name.contains("\n"), name != "…" { return name }
        }
        return nil
    }

    static func statusName(role: String, description: String, value: String) -> String? {
        guard ["AXStaticText", "AXGroup"].contains(role),
              ["active speaker", "speaking", "talking", "говорит", "активный докладчик"]
                .contains(description.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).lowercased())
        else { return nil }
        guard value.contains(where: \.isLetter) else { return nil }
        return speakerName("Speaking: " + value)
    }

    struct Tile {
        let name: String
        let frame, windowFrame: CGRect
        let pid: pid_t
    }

    static func tileName(role: String, labels: [String]) -> String? {
        let roles = ["video render", "обработка видео"]
        for label in labels {
            var line = String(label.prefix(while: { !$0.isNewline })).trimmingCharacters(in: .whitespacesAndNewlines)
            if let prefix = roles.first(where: { line.lowercased().hasPrefix($0 + " ") }) {
                line = String(line.dropFirst(prefix.count + 1))
            } else if !roles.contains(role.lowercased()) { continue }
            // Zoom combines the name with its audio and video state in some layouts.
            let states = [", computer audio ", ", phone audio ", ", video on", ", video off",
                          ", звук ", ", компьютерный звук", ", видео ", ", микрофон ", ", аудио"]
            let end = states.compactMap { line.range(of: $0, options: .caseInsensitive)?.lowerBound }.min() ?? line.endIndex
            let name = line[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.count <= 100, !roles.contains(name.lowercased()),
               !name.lowercased().hasPrefix("view "), !name.contains("://") { return name }
        }
        return nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, "AXPosition"), let s = value(element, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size), size.width >= 40, size.height >= 28 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    struct Layout {
        let pid: pid_t
        let frame: CGRect?
        var participantCounts = Set<Int>()
        enum Camera { case on, off, unknown }
        var roster = [String: Camera]()
        var muted = Set<String>()
        var markedSelf = Set<String>()
        var localVideo: Bool?
        var sharing = false

        mutating func inspectTile(_ rawName: String, labels: [String]) {
            var name = rawName
            for suffix in [" (me)", " (you)", " (я)", " (вы)"] where name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                markedSelf.insert(name)
            }
            let fields = labels.flatMap { $0.lowercased().components(separatedBy: CharacterSet(charactersIn: ",\n")) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let on = fields.contains("video on") || fields.contains("видео включено")
            let off = fields.contains("video off") || fields.contains("видео выключено")
            roster[name] = on == off ? .unknown : (on ? .on : .off)
            if fields.contains("computer audio muted") || fields.contains("phone audio muted") || fields.contains("микрофон выключен") {
                muted.insert(name)
            }
        }

        func peer(myName: String) -> String? {
            guard complete, participantCounts == [2], roster.count == 2, !sharing, !floating else { return nil }
            var local = markedSelf
            let configured = myName.trimmingCharacters(in: .whitespacesAndNewlines)
            local.formUnion(roster.keys.filter { $0.caseInsensitiveCompare(configured) == .orderedSame })
            if let localVideo, !roster.values.contains(.unknown) {
                let same = roster.keys.filter { roster[$0] == (localVideo ? .on : .off) }
                if same.count == 1 { local.insert(same[0]) }
            }
            guard local.count == 1 else { return nil }
            return roster.keys.first { !local.contains($0) && !muted.contains($0) }
        }

        var floating = false
        var mainMeeting = false
        enum ViewMode: String {
            case speaker, gallery, dynamicGallery, multiSpeaker, immersive, other
        }
        var viewMode: ViewMode?
        var fixedVideo = false
        var complete = false

        var canUseFeaturedTile: Bool {
            complete && !fixedVideo && (viewMode == .speaker || (viewMode == nil && mainMeeting))
        }

        mutating func inspect(role: String, labels: [String]) {
            for label in labels where !label.isEmpty {
                let lower = label.lowercased()
                let firstLine = String(lower.prefix(while: { !$0.isNewline }))
                if ["stop share", "stop sharing", "viewing ", "you are screen sharing", "остановить демонстрацию", "вы просматриваете"].contains(where: firstLine.hasPrefix)
                    || firstLine.contains("is sharing their screen") { sharing = true }
                if role == "AXButton" {
                    let control = lower.components(separatedBy: .newlines)[0].trimmingCharacters(in: .whitespaces)
                    if ["stop video", "остановить видео", "выключить видео"].contains(control.components(separatedBy: ",").first ?? "") { localVideo = true }
                    if ["start video", "начать видео", "включить видео"].contains(control.components(separatedBy: ",").first ?? "") { localVideo = false }
                    let fields = control.components(separatedBy: ", ")
                    for field in fields {
                        let parts = field.split(separator: " ")
                        if parts.count == 2, let count = Int(parts[0]),
                           ["participants", "participant", "участника", "участников", "участник"].contains(String(parts[1])) {
                            participantCounts.insert(count)
                        }
                    }
                    if fields.count >= 2, ["view options", "настройки просмотра"].contains(fields[0]) {
                        switch fields[1] {
                        case "speaker", "speaker view", "вид докладчика": viewMode = .speaker
                        case "multi-speaker", "несколько докладчиков": viewMode = .multiSpeaker
                        case "gallery", "gallery view", "галерея": viewMode = .gallery
                        case "dynamic gallery", "динамическая галерея": viewMode = .dynamicGallery
                        case "immersive", "immersive view", "иммерсивный вид": viewMode = .immersive
                        default: viewMode = .other
                        }
                    }
                    if ["show active speaker video", "показывать видеоизображение активного докладчика"].contains(control) {
                        floating = true
                    }
                }
                let fields = lower.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if fields.contains(where: { ["remove pin", "remove spotlight", "удалить закрепление"].contains($0) }) ||
                    (role != "AXButton" && fields.contains(where: { ["pinned", "spotlighted", "закреплено", "выделенные"].contains($0) })) {
                    fixedVideo = true
                }
            }
        }
    }

    struct Reading {
        func solePeer(myName: String) -> String? {
            guard !layouts.contains(where: { $0.sharing || $0.floating }) else { return nil }
            let meetings = layouts.filter { $0.mainMeeting || !$0.participantCounts.isEmpty }
            guard meetings.count == 1 else { return nil }
            return meetings[0].peer(myName: myName)
        }
        var layouts = [Layout]()
        var tiles = [Tile]()
        var names = Set<String>()
        var nodes = 0
        var windows = 0
        var status = "zoom-absent"
    }

    static func readZoom() -> Reading {
        var result = Reading()
        guard AXIsProcessTrusted() else { result.status = "access-denied"; return result }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        for id in zoomIDs {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                result.status = "no-speaker-label"
                let app = AXUIElementCreateApplication(running.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.15)
                let windows = children(app, "AXWindows")
                var queue = windows.map { window in
                    let index = result.layouts.count
                    let title = text(window, "AXTitle").lowercased()
                    result.layouts.append(Layout(pid: running.processIdentifier, frame: frame(window),
                                                 floating: title == "zoom floating video window",
                                                 mainMeeting: text(window, "AXIdentifier") == "zm.meeting.window.main"))
                    return (window, index)
                }
                result.windows += queue.count
                var index = 0
                while index < queue.count && result.nodes < 550 && ProcessInfo.processInfo.systemUptime < deadline {
                    let (node, layout) = queue[index]
                    index += 1
                    result.nodes += 1
                    let role = text(node, "AXRole")
                    guard !["AXTextArea", "AXTextField", "AXWebArea", "AXMenuBar", "AXMenu"].contains(role) else { continue }
                    let title = text(node, "AXTitle")
                    if ["chat", "чат", "meeting chat", "чат конференции"].contains(title.lowercased()) { continue }
                    let labels = [title, text(node, "AXDescription"), text(node, "AXValue")]
                    if role == "AXTable", labels.contains(where: {
                        let label = $0.lowercased()
                        return label.hasPrefix("chat list") || label.hasPrefix("список сообщений") || label.hasPrefix("список чата")
                    }) { continue }
                    result.layouts[layout].inspect(role: role, labels: labels)
                    if let name = tileName(role: text(node, "AXRoleDescription"), labels: labels) {
                        result.layouts[layout].inspectTile(name, labels: labels)
                        if let windowFrame = result.layouts[layout].frame, let rect = frame(node) {
                            result.tiles.append(Tile(name: name, frame: rect, windowFrame: windowFrame, pid: running.processIdentifier))
                        }
                    }
                    if let name = statusName(role: role, description: labels[1], value: labels[2]) ??
                        statusName(role: role, description: title, value: labels[2]) {
                        result.names.insert(name)
                    }
                    for label in labels {
                        if let name = speakerName(label) { result.names.insert(name) }
                    }
                    queue.append(contentsOf: children(node).map { ($0, layout) })
                }
                let pending = Set(queue.dropFirst(index).map { $0.1 })
                for layout in result.layouts.indices where result.layouts[layout].pid == running.processIdentifier {
                    result.layouts[layout].complete = !pending.contains(layout)
                }
            }
        }
        if !result.names.isEmpty { result.status = result.names.count == 1 ? "name" : "ambiguous" }
        return result
    }
}

// Spokenly can bring its main window forward to offer a second transcription.
// Observe only the short interval around our own Stop command.
@MainActor struct SpokenlyStopWindow {
    private let app: NSRunningApplication
    private let root: AXUIElement
    private let previousApp: NSRunningApplication?
    private let previouslyVisible: [AXUIElement]
    private let wasHidden: Bool
    private let started = ProcessInfo.processInfo.systemUptime

    init?(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "app.spokenly" else { return nil }
        self.app = app
        root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        previousApp = NSWorkspace.shared.frontmostApplication
        wasHidden = app.isHidden
        guard let windows = MeetingAX.value(root, "AXWindows") as? [AXUIElement] else { return nil }
        previouslyVisible = wasHidden ? [] : windows.filter {
            MeetingAX.value($0, "AXMinimized") as? Bool != true
        }
    }

    func minimizeNewWindow() async {
        for _ in 0..<24 {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            // Do not undo a deliberate app switch or interaction after Stop.
            let inputs: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            guard !Task.isCancelled, !app.isTerminated, elapsed < 4,
                  inputs.allSatisfy({ CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= elapsed })
            else { return }
            if app.isActive, let window = MeetingAX.element(root, "AXFocusedWindow"),
               MeetingAX.text(window, "AXRole") == "AXWindow",
               MeetingAX.value(window, "AXMinimized") as? Bool != true {
                let wasVisible = previouslyVisible.contains { CFEqual($0, window) }
                if !wasVisible {
                    let minimized = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                    if minimized != .success && (wasHidden || previouslyVisible.isEmpty) && previousApp != app {
                        app.hide()
                    }
                }
                // Spokenly sometimes reuses a window that the user already had
                // open. In that case just return focus to their previous app.
                if let previousApp, previousApp != app, !previousApp.isTerminated,
                   app.isActive || NSWorkspace.shared.frontmostApplication == nil {
                    previousApp.activate(options: [])
                }
                if !wasVisible || previousApp != app { return }
            }
            do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return }
        }
    }
}

// Zoom can announce the active speaker through Accessibility even when the
// persistent window tree exposes no label. Only keep matching announcements.
@MainActor final class ZoomAnnouncements {
    private var observers: [pid_t: AXObserver] = [:]
    private(set) var latest: (String, Date)?
    func refresh() {
        let apps = MeetingAX.zoomIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        for pid in Array(observers.keys) where !apps.contains(where: { $0.processIdentifier == pid }) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        for app in apps where observers[app.processIdentifier] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallbackWithInfo = { _, _, _, info, context in
                guard let context, let label = (info as NSDictionary)["AXAnnouncement"] as? String,
                      let name = MeetingAX.speakerName(label) else { return }
                MainActor.assumeIsolated {
                    Unmanaged<ZoomAnnouncements>.fromOpaque(context).takeUnretainedValue().latest = (name, Date())
                }
            }
            let pid = app.processIdentifier
            guard AXObserverCreateWithInfoCallback(pid, callback, &observer) == .success, let observer else { continue }
            AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), "AXAnnouncementRequested" as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = observer
        }
    }
    func stop() {
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll()
        latest = nil
    }
}
