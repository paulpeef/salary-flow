import AppKit
import Foundation

@MainActor final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SalaryFlow/Meetings")
    private let recordings = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Spokenly/MeetingRecordings")
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "meetings.enabled") as? Bool ?? true
    @Published var showInPanel = UserDefaults.standard.object(forKey: "meetings.showInPanel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInPanel, forKey: "meetings.showInPanel") }
    }
    @Published var minimizeSpokenly = UserDefaults.standard.object(forKey: "meetings.minimizeSpokenly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(minimizeSpokenly, forKey: "meetings.minimizeSpokenly") }
    }
    @Published private(set) var controlGranted = AXIsProcessTrusted()
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var processingStatus = ""
    @Published private(set) var zoomStatus = ""
    @Published private(set) var lastFolder: URL?
    @Published var useBanner = UserDefaults.standard.bool(forKey: "meetings.zoomBanner") {
        didSet {
            UserDefaults.standard.set(useBanner, forKey: "meetings.zoomBanner")
            if useBanner && !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        }
    }
    @Published var readTileFrames = UserDefaults.standard.bool(forKey: "meetings.zoomTileFrames") {
        didSet {
            UserDefaults.standard.set(readTileFrames, forKey: "meetings.zoomTileFrames")
            if readTileFrames && !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        }
    }
    private struct Capture: Codable {
        let folder: URL, started: Date
        let existing: Set<String>
        var sourceID: String?
    }
    private let fm = FileManager.default
    private let announcements = ZoomAnnouncements()
    private let notice = MeetingNotice()
    private var capture: Capture?
    @Published private(set) var chatStatus = ""
    private var chatMonitor: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var pending: [URL] = []
    private var processing: URL?
    private var publishedResult: URL?
    private var activeFile: URL { Self.root.appending(path: "active.json") }

    var canChangeEnabled: Bool { !recording && !busy && processing == nil && pending.isEmpty }

    func setEnabled(_ value: Bool) {
        guard canChangeEnabled, enabled != value else { return }
        enabled = value
        UserDefaults.standard.set(value, forKey: "meetings.enabled")
        if value { restore() }
    }

    private init() {
        if enabled { restore() }
    }

    private func restore() {
        guard Bundle.main.bundleIdentifier == "io.github.paulpeef.salaryflow" else { return }
        Log.info("встречи: доступ к управлению у запущенной сборки: \(controlGranted)")
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let sessions = dirs.filter { $0.lastPathComponent.hasPrefix("20") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        lastFolder = sessions.last
        publishedResult = sessions.last { fm.fileExists(atPath: $0.appending(path: "meeting.txt").path) }
        if let data = try? Data(contentsOf: activeFile), let saved = try? JSONDecoder().decode(Capture.self, from: data) {
            capture = saved
            recording = true
            status = "Сеанс восстановлен. Проверь запись в Spokenly."
            startMonitor()
        }
        for dir in sessions where fm.fileExists(atPath: dir.appending(path: "pending").path) && dir != capture?.folder {
            pending.append(dir)
        }
        runQueue()
    }

    private let controlHint = "Разреши управление для установленной SalaryFlow.app в Privacy & Security → Device Control and Data Access (Универсальный доступ)."

    func refreshControl() {
        controlGranted = AXIsProcessTrusted()
        if controlGranted && status == controlHint { status = "" }
    }

    func toggle() {
        guard !busy, enabled || recording else { return }
        controlGranted = MeetingAX.permission()
        guard controlGranted else {
            status = controlHint
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do { if recording { try await stop() } else { try await start() } }
            catch {
                status = error.localizedDescription
                if recording { notice.show("Проверь остановку записи", detail: status) }
            }
        }
    }

    private func spokenPID(launch: Bool) async throws -> pid_t {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "app.spokenly").first {
            return app.processIdentifier
        }
        guard launch, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.spokenly") else {
            throw MeetingIssue("Spokenly не запущен.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return app.processIdentifier
    }

    private func sourceIDs() -> Set<String> {
        let files = (try? fm.contentsOfDirectory(atPath: recordings.path)) ?? []
        let suffix = "-system.wav"
        return Set(files.compactMap {
            guard $0.hasSuffix(suffix) else { return nil }
            let id = String($0.dropLast(suffix.count))
            return UUID(uuidString: id) == nil ? nil : id
        })
    }

    private func start() async throws {
        status = "Запускаю запись Spokenly…"
        let pid = try await spokenPID(launch: true)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let dir = Self.root.appending(path: "\(stamp)-\(UUID().uuidString.prefix(6))")
        let state = Capture(folder: dir, started: now, existing: sourceIDs())
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: dir.appending(path: "zoom.jsonl"))
        try JSONEncoder().encode(state).write(to: activeFile, options: .atomic)
        let command: MeetingAX.CommandResult
        do { command = try await Task.detached { try MeetingAX.record(true, pid: pid) }.value }
        catch {
            try? fm.removeItem(at: activeFile)
            try? fm.removeItem(at: dir)
            throw error
        }
        if command == .opposite {
            try? fm.removeItem(at: activeFile)
            try? fm.removeItem(at: dir)
            throw MeetingIssue("В Spokenly уже идёт запись. Заверши её перед началом нового сеанса.")
        }
        capture = state
        recording = true
        lastFolder = dir
        status = "Жду появления аудиодорожек Spokenly…"
        startMonitor()
    }

    private func bindAudio() throws {
        guard var state = capture else { return }
        let available = sourceIDs().subtracting(state.existing).filter { id in
            let file = recordings.appending(path: id + "-system.wav")
            guard let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate else { return false }
            let delay = created.timeIntervalSince(state.started)
            return delay >= -1 && delay <= 30
        }
        if state.sourceID == nil {
            guard available.count <= 1 else { throw MeetingIssue("Появились две записи Spokenly. Автоматическая привязка неоднозначна.") }
            guard let id = available.first else { return }
            state.sourceID = id
            try JSONEncoder().encode(state).write(to: activeFile, options: .atomic)
            capture = state
        }
        guard let id = state.sourceID else { return }
        for track in ["mic", "system"] {
            let target = state.folder.appending(path: track + ".wav")
            let source = recordings.appending(path: id + "-" + track + ".wav")
            if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: source.path) {
                // Spokenly removes its temporary WAVs on stop. A hard link keeps
                // the same inode, including the final header, without copying a growing file.
                try fm.linkItem(at: source, to: target)
            }
        }
    }

    private func hasAudio(_ dir: URL) -> Bool {
        ["mic.wav", "system.wav"].allSatisfy { fm.fileExists(atPath: dir.appending(path: $0).path) }
    }

    private var savedChat = [MeetingChatMessage]()

    private func readChat(_ directory: URL) async {
        let snapshot = await Task.detached(priority: .utility) { MeetingChat.snapshot() }.value
        guard !Task.isCancelled, capture?.folder == directory else { return }
        guard let snapshot else {
            chatStatus = "Для записи чата открой «Все» (Everyone) в Zoom · сохранено: \(savedChat.count)"
            return
        }
        do {
            let merged = MeetingChat.merged(savedChat, snapshot)
            if merged.count != savedChat.count {
                try JSONEncoder().encode(merged).write(to: directory.appending(path: "chat.json"), options: .atomic)
                savedChat = merged
            }
            chatStatus = "Общий чат открыт · сообщений сохранено: \(savedChat.count)"
        } catch { chatStatus = "Не удалось сохранить чат: " + error.localizedDescription }
    }

    private func startChatMonitor(_ directory: URL) {
        chatMonitor?.cancel()
        chatMonitor = nil
        do { savedChat = try MeetingChat.load(directory) }
        catch { chatStatus = error.localizedDescription; return }
        chatStatus = "Для записи общего чата открой в Zoom вкладку «Все» (Everyone)."
        chatMonitor = Task {
            while !Task.isCancelled && capture?.folder == directory {
                await readChat(directory)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func startMonitor() {
        monitor?.cancel()
        guard let dir = capture?.folder else { return }
        startChatMonitor(dir)
        monitor = Task {
            var n = 0
            while !Task.isCancelled, capture?.folder == dir {
                do {
                    try bindAudio()
                    if hasAudio(dir) { status = "Идёт запись Spokenly" }
                    else if n >= 5 { status = "Spokenly ещё не создал обе дорожки. Проверь индикатор записи." }
                    if n % 5 == 0 { announcements.refresh() }
                    var sampleTime = Date()
                    var result = await Task.detached(priority: .utility) { MeetingAX.readZoom() }.value
                    if result.names.isEmpty, let (name, date) = announcements.latest, abs(date.timeIntervalSinceNow) < 1.3 {
                        result.names = [name]; result.status = "announcement"
                    }
                    if result.names.isEmpty && (useBanner || readTileFrames) && (result.windows > 0 || (readTileFrames && result.status == "no-speaker-label")) {
                        let observed = await MeetingZoomBanner.observe(reading: result, readTiles: readTileFrames)
                        result.names = observed.names
                        result.status = observed.status
                        sampleTime = observed.capturedAt ?? sampleTime
                    }
                    guard !Task.isCancelled, capture?.folder == dir else { return }
                    let sample = ZoomSample(time: sampleTime, names: result.names.sorted(), status: result.status,
                                            windows: result.windows, nodes: result.nodes)
                    var bytes = try JSONEncoder().encode(sample)
                    bytes.append(10)
                    let handle = try FileHandle(forWritingTo: dir.appending(path: "zoom.jsonl"))
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: bytes)
                    if sample.status == "sharing-panel", let name = sample.names.first {
                        zoomStatus = "На плавающей плитке Zoom: " + name
                    } else if sample.status == "featured-tile", let name = sample.names.first {
                        zoomStatus = "На крупной плитке Zoom: " + name
                    } else if !sample.names.isEmpty {
                        zoomStatus = (sample.names.count == 1 ? "Zoom: " : "Zoom выделяет несколько участников: ") + sample.names.joined(separator: ", ")
                    } else {
                        switch result.status {
                        case "multiple-featured": zoomStatus = "Zoom увеличил несколько плиток. Жду выделения одного говорящего."
                        case "screen-permission": zoomStatus = "Разреши Salary Flow запись экрана в системных настройках macOS."
                        case "window-unavailable", "capture-failed": zoomStatus = "Окно встречи Zoom недоступно для чтения."
                        case "tile-window-unmatched": zoomStatus = "Вижу плитки, но не удалось сопоставить их с окном Zoom."
                        case "access-denied": zoomStatus = "Разреши Salary Flow универсальный доступ в macOS."
                        case "zoom-absent": zoomStatus = "Жду Zoom."
                        default:
                            if result.tiles.isEmpty {
                                zoomStatus = "У Zoom нет видимой подписи говорящего."
                            } else {
                                zoomStatus = readTileFrames ? "Вижу плитки (\(result.tiles.count)). Рамка говорящего не найдена." :
                                    "Вижу плитки (\(result.tiles.count)). Можно включить чтение рамки."
                            }
                        }
                    }
                } catch { status = error.localizedDescription }
                n += 1
                try? await Task.sleep(nanoseconds: 650_000_000)
            }
        }
    }

    private func stop() async throws {
        try bindAudio()
        guard let state = capture else { return }
        let linked = hasAudio(state.folder)
        let ids = sourceIDs()
        let owned = state.sourceID.map { ids.contains($0) } ?? false
        let unboundStart = state.sourceID == nil && Date().timeIntervalSince(state.started) <= 30
        let sameRecordingMayStillRun = state.sourceID == nil && ids.subtracting(state.existing).isEmpty &&
            NSRunningApplication.runningApplications(withBundleIdentifier: "app.spokenly").first != nil
        let otherSession = !ids.subtracting(state.existing).subtracting(state.sourceID.map { [$0] } ?? []).isEmpty
        if otherSession && linked {
            // Another meeting was started outside Salary Flow. Finalize ours only
            // after the retained files have stopped growing.
            try await MeetingProcessing.waitForClosedAudio(state.folder)
        } else if !otherSession && (owned || unboundStart || sameRecordingMayStillRun) {
            let pid = try await spokenPID(launch: false)
            let presentation = minimizeSpokenly && linked ? SpokenlyStopWindow(pid: pid) : nil
            let result = try await Task.detached { try MeetingAX.record(false, pid: pid) }.value
            if result == .sent, let presentation {
                Task { await presentation.minimizeNewWindow() }
            }
            if result == .sent && linked {
                notice.show("Завершаю запись", detail: "Расшифровка начнётся автоматически.")
            }
            if result == .sent && owned {
                // Do not report stopped while Spokenly still writes this session.
                try await MeetingProcessing.waitForClosedAudio(state.folder)
            }
        }
        if chatMonitor != nil { await readChat(state.folder) }
        if linked { try Data().write(to: state.folder.appending(path: "pending"), options: .atomic) }
        try fm.removeItem(at: activeFile)
        monitor?.cancel()
        chatMonitor?.cancel()
        chatMonitor = nil
        announcements.stop()
        recording = false
        capture = nil
        zoomStatus = ""
        lastFolder = state.folder
        status = linked ? "Запись сохранена" : "Журнал Zoom сохранён. Обе дорожки Spokenly не найдены."
        if linked { enqueue(state.folder) }
    }

    func openFiles() {
        if let lastFolder { NSWorkspace.shared.open(lastFolder) }
    }

    func copyAgain() {
        guard let dir = publishedResult, let text = try? String(contentsOf: dir.appending(path: "meeting.txt"), encoding: .utf8) else { return }
        let ok = deliver(text, from: dir)
        processingStatus = ok ? "Последняя встреча скопирована." : "Не удалось скопировать. Итог сохранён в meeting.txt."
        notice.show(ok ? "Текст встречи скопирован" : "Текст сохранён в файле",
                    detail: ok ? "Можно вставлять в ChatGPT." : "Открой файлы встречи или повтори копирование из капли.")
    }
    var canCopy: Bool { publishedResult != nil }
    var canRetry: Bool {
        guard let lastFolder else { return false }
        return hasAudio(lastFolder) && capture?.folder != lastFolder && processing != lastFolder && !pending.contains(lastFolder)
    }
    func retry() {
        guard enabled, canRetry, let dir = lastFolder else { return }
        do { try Data().write(to: dir.appending(path: "pending"), options: .atomic); enqueue(dir) }
        catch { processingStatus = error.localizedDescription }
    }
    private func enqueue(_ dir: URL) {
        if !pending.contains(dir) && processing != dir { pending.append(dir) }
        runQueue()
    }
    private func deliver(_ text: String, from directory: URL) -> Bool {
        let verified = MeetingClipboard.write(text)
        Log.info("встречи: \(directory.lastPathComponent), запись текста в буфер \(verified ? "подтверждена" : "не подтверждена")")
        return verified
    }
    private func runQueue() {
        guard enabled, processing == nil, !pending.isEmpty else { return }
        let dir = pending.removeFirst()
        processing = dir
        processingStatus = "Распознаю речь и сопоставляю голоса…"
        Task {
            do {
                let (text, details) = try await Task.detached(priority: .utility) { try await MeetingProcessing.process(dir) }.value
                publishedResult = dir
                let verified = deliver(text, from: dir)
                processingStatus = (verified ? "Текст с таймкодами скопирован. " : "Текст сохранён в meeting.txt. Не удалось скопировать в буфер. ") + details
                notice.show(verified ? "Текст встречи скопирован" : "Текст сохранён в файле",
                            detail: verified ? "Можно вставлять в ChatGPT." : "В капле доступна кнопка повторного копирования.")
            } catch {
                processingStatus = "Обработка прервана. " + error.localizedDescription
                notice.show("Расшифровка прервана", detail: "Открой каплю, чтобы посмотреть причину.")
                try? processingStatus.write(to: dir.appending(path: "error.txt"), atomically: true, encoding: .utf8)
            }
            try? fm.removeItem(at: dir.appending(path: "pending"))
            processing = nil
            runQueue()
        }
    }
}
